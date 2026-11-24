package dev.catli.markdownit.ai

import android.os.SystemClock
import android.util.Log
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.net.HttpURLConnection

internal class ModelFailure(val kind: String, val detail: String? = null, val status: Int? = null) : Exception(detail)

internal class ResponsesClient {
    suspend fun models(connection: ModelConnection): List<String> =
        request(connection, "models", null) { response ->
            val models = JSONObject(response.inputStream.bufferedReader().use { it.readText() }).getJSONArray("data")
            models.objects().mapNotNull { it.optString("id").takeIf(String::isNotEmpty) }.distinct().sorted()
        }

    suspend fun stream(connection: ModelConnection, messages: JSONArray, onText: suspend (String) -> Unit) {
        val body = JSONObject().put("model", connection.model).put("input", messages)
            .put("stream", true).put("store", false)
        request(connection, "responses", body) { response ->
            val started = SystemClock.elapsedRealtime()
            var sawText = false
            suspend fun emit(text: String) {
                if (text.isEmpty()) return
                if (!sawText) Log.i(TAG, "first text after ${SystemClock.elapsedRealtime() - started} ms")
                sawText = true
                onText(text)
            }
            val mime = response.contentType.orEmpty().substringBefore(';').trim().lowercase()
            response.inputStream.bufferedReader().use { reader ->
                if (mime == "application/json") {
                    val result = JSONObject(reader.readText())
                    emit(outputText(result))
                    checkCompletion(connection, result)
                } else {
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val frame = reader.event() ?: throw ModelFailure(if (sawText) "interrupted" else "invalidResponse")
                        if (frame == "[DONE]") throw ModelFailure(if (sawText) "interrupted" else "invalidResponse")
                        val event = JSONObject(frame)
                        when (event.optString("type")) {
                            "response.output_text.delta" -> emit(event.optString("delta"))
                            "response.completed" -> {
                                val result = event.optJSONObject("response")
                                if (!sawText && result != null) emit(outputText(result))
                                if (result != null) checkCompletion(connection, result)
                                break
                            }
                            "response.failed", "response.incomplete", "error" -> {
                                throw failure(connection, event.optJSONObject("response") ?: event)
                            }
                        }
                    }
                }
            }
            if (!sawText) throw ModelFailure("invalidResponse")
        }
    }

    private suspend fun <T> request(
        connection: ModelConnection, resource: String, body: JSONObject?, parse: suspend (HttpURLConnection) -> T,
    ): T = coroutineScope {
        val http = connection.endpoint(resource).openConnection() as HttpURLConnection
        val cancel = launch(Dispatchers.IO, start = CoroutineStart.UNDISPATCHED) {
            try { awaitCancellation() } finally { http.disconnect() }
        }
        try {
            withContext(Dispatchers.IO) {
                val started = SystemClock.elapsedRealtime()
                http.instanceFollowRedirects = false
                http.connectTimeout = 25_000
                http.readTimeout = 90_000
                http.useCaches = false
                http.setRequestProperty("Authorization", "Bearer ${connection.apiKey}")
                http.setRequestProperty("User-Agent", "MarkdownIt/Android")
                http.setRequestProperty("Accept", if (body != null) "text/event-stream, application/json" else "application/json")
                if (body != null) {
                    http.requestMethod = "POST"
                    http.doOutput = true
                    http.setRequestProperty("Content-Type", "application/json")
                    val bytes = body.toString().encodeToByteArray()
                    http.setFixedLengthStreamingMode(bytes.size)
                    http.outputStream.use { it.write(bytes) }
                }
                val status = http.responseCode
                Log.i(TAG, "${connection.service.host} $resource HTTP $status after ${SystemClock.elapsedRealtime() - started} ms")
                if (status !in 200..299) {
                    val text = http.errorStream?.bufferedReader()?.use { reader ->
                        CharArray(8192).let { buffer ->
                            val count = reader.read(buffer)
                            if (count < 0) "" else String(buffer, 0, count)
                        }
                    }
                    throw failure(connection, text?.let { runCatching { JSONObject(it) }.getOrNull() }, status)
                }
                parse(http)
            }
        } finally {
            cancel.cancel()
        }
    }

    private fun checkCompletion(connection: ModelConnection, result: JSONObject) {
        if (result.optString("status") != "completed") throw failure(connection, result)
    }

    private fun outputText(result: JSONObject): String = result.optJSONArray("output").objects()
        .filter { it.optString("type") == "message" || it.optJSONArray("content") != null }
        .flatMap { it.optJSONArray("content").objects() }
        .filter { it.optString("type") in setOf("output_text", "refusal") }
        .joinToString("") { it.optString(if (it.optString("type") == "refusal") "refusal" else "text") }

    private fun failure(connection: ModelConnection, result: JSONObject?, status: Int? = null): ModelFailure {
        val error = result?.optJSONObject("error") ?: result
        val code = error?.optString("code").orEmpty()
        val detail = error?.optString("message").orEmpty().ifBlank { error?.optString("msg").orEmpty() }
            .ifBlank { result?.optJSONObject("incomplete_details")?.optString("reason").orEmpty() }
            .takeIf(String::isNotBlank)?.replace(connection.apiKey, "••••••")?.take(600)
        val kind = when {
            status == 429 -> "rateLimit"
            status == 413 -> "requestTooLarge"
            code in setOf("context_length_exceeded", "input_too_long") -> "contextLimit"
            result?.optString("status") == "incomplete" -> "incomplete"
            else -> "service"
        }
        return ModelFailure(kind, detail, status)
    }

    private fun BufferedReader.event(): String? {
        val data = mutableListOf<String>()
        while (true) {
            val line = readLine() ?: break
            if (line.isEmpty() && data.isNotEmpty()) break
            if (line.startsWith("data:")) data.add(line.substring(5).removePrefix(" "))
        }
        return data.takeIf(List<String>::isNotEmpty)?.joinToString("\n")
    }

    private companion object { const val TAG = "MarkdownItModel" }
}

internal fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList()
else (0 until length()).mapNotNull(::optJSONObject)
