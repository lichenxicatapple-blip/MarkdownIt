package dev.catli.markdownit.ai

import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import androidx.webkit.JavaScriptReplyProxy
import dev.catli.markdownit.DocumentFiles
import dev.catli.markdownit.R
import dev.catli.markdownit.ReaderWeb
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.SocketTimeoutException
import java.util.UUID

internal class AndroidAssistant(
    private val activity: ComponentActivity,
    private val files: DocumentFiles,
    private val document: () -> ReaderWeb.Projection?,
    private val onLink: (String) -> Unit,
) {
    private val scope = activity.lifecycleScope
    private val store = ModelConnectionStore(activity)
    private val client = ResponsesClient()
    private val conversations = ConversationStore(activity)
    private val settings = ModelSettingsDialog(activity, scope, store, client)
    private val consent = activity.getSharedPreferences("model-consent", Context.MODE_PRIVATE)
    private var connection: ModelConnection? = null
    private var active: Conversation? = null
    private var entryJob: Job? = null
    private var consentDialog: AlertDialog? = null

    fun enter(quote: JSONObject? = null) {
        val current = document() ?: return
        if (entryJob?.isActive == true) return
        entryJob = scope.launch {
            try {
                connection = withContext(Dispatchers.IO) { store.load() }
                if (document()?.document?.uri != current.document.uri) return@launch
                if (connection == null) {
                    AlertDialog.Builder(activity).setMessage(R.string.ai_not_configured)
                        .setNegativeButton(android.R.string.cancel, null)
                        .setPositiveButton(R.string.ai_configure) { _, _ ->
                            settings.show(null) { next ->
                                connection = next
                                if (next != null && document()?.document?.uri == current.document.uri) enter(quote)
                            }
                        }.show()
                } else if (active?.uri == current.document.uri) {
                    active?.show(quote)
                } else {
                    closeDocument()
                    val saved = withContext(Dispatchers.IO) { conversations.load(current.document.uri) }
                    if (document()?.document?.uri != current.document.uri) return@launch
                    Conversation(current.document.uri, saved).also { conversation ->
                        active = conversation
                        conversation.show(quote)
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                Log.w(TAG, "open assistant: ${error.javaClass.simpleName}")
                alert(R.string.ai_connection_error)
            }
        }
    }

    fun closeDocument() {
        consentDialog?.dismiss()
        consentDialog = null
        val conversation = active ?: return
        active = null
        conversation.finish()
    }

    fun checkpoint() { active?.capture() }

    fun destroy() {
        entryJob?.cancel()
        closeDocument()
    }

    private fun alert(message: Int) {
        if (!activity.isFinishing) AlertDialog.Builder(activity).setMessage(message)
            .setPositiveButton(android.R.string.ok, null).show()
    }

    private inner class Conversation(val uri: Uri, private val saved: JSONObject?) {
        private val token = UUID.randomUUID().toString()
        private val web = ReaderWeb(activity, files, ::receive, ::rendererGone)
        private val sheet: ConversationSheet = ConversationSheet(activity, web.view,
            onDraft = { text, epoch -> updateInput("updateAgentInput", text, epoch) },
            onSend = { text, epoch -> updateInput("commitAgentInput", text, epoch) },
            onStop = { web.conversation("sendAgentInput") },
            onSettings = {
                sheetKeyboardDown()
                settings.show(connection) { next ->
                    connection = next
                    if (next == null) sheetDismiss()
                }
            },
            onClear = ::clear,
        )
        private var ready = false
        private var pending: JSONObject? = null
        private var openPending = false
        private var revision = 0
        private var captureTask: Job? = null
        private var request: Job? = null
        private var requestID: String? = null
        private var closed = false

        init {
            sheet.setOnDismissListener {
                sheet.hideKeyboard()
                present(false)
                capture()
            }
        }

        fun show(quote: JSONObject?) {
            pending = quote
            openPending = true
            if (!sheet.isShowing) sheet.show()
            if (ready) applyEntry()
            else if (web.view.url == null && !web.start(ReaderWeb.Surface.Conversation)) rendererGone()
        }

        private fun sheetKeyboardDown() = sheet.hideKeyboard()
        private fun sheetDismiss() = sheet.dismiss()

        private fun rendererGone() {
            if (closed) return
            ready = false
            if (active === this) closeDocument()
            alert(R.string.render_failed)
        }

        private fun receive(message: JSONObject, reply: JavaScriptReplyProxy) {
            val type = message.optString("type")
            if (closed || active !== this || (type != "conversationReady" && message.optString("token") != token)) return
            when (type) {
                "conversationReady" -> {
                    val current = document()?.takeIf { it.document.uri == uri } ?: return
                    val value = JSONObject().put("token", token).put("name", current.document.name)
                        .put("background", background(current)).put("recovery", saved)
                    web.setProjection(current.copy(token = token))
                    web.conversation("openDocument", value.toString())
                    val dark = activity.resources.configuration.uiMode and
                        android.content.res.Configuration.UI_MODE_NIGHT_MASK ==
                        android.content.res.Configuration.UI_MODE_NIGHT_YES
                    web.conversation("theme", JSONObject.quote(if (dark) "dark" else "light"))
                    ready = true
                    applyEntry()
                }
                "agentEntry" -> resolve("resolveAgentEntry", message.optString("id"), connection != null)
                "agentConsent" -> authorize(message.optString("id"))
                "agentRequest" -> send(message)
                "agentCancel" -> if (requestID == message.optString("id")) stop()
                "agentToggle" -> if (!message.optBoolean("open")) sheet.dismiss()
                "agentControls" -> sheet.updateControls(message.optBoolean("hasHistory"),
                    message.optBoolean("generating"), message.optBoolean("sendEnabled"))
                "inputSetText" -> sheet.setDraft(message.optString("text"), message.optInt("epoch"))
                "inputSubmit" -> sheet.submit()
                "inputBlur" -> sheet.hideKeyboard()
                "recoveryChanged" -> if (captureTask?.isActive != true) captureTask = scope.launch {
                    delay(350)
                    capture()
                }
                "link" -> onLink(message.optString("href"))
                "copyCode" -> {
                    val clipboard = activity.getSystemService(ClipboardManager::class.java)
                    clipboard.setPrimaryClip(ClipData.newPlainText(null, message.optString("text")))
                    reply.postMessage(JSONObject().put("id", message.optString("id")).put("copied", true).toString())
                }
            }
        }

        private fun applyEntry() {
            if (!openPending || !ready) return
            openPending = false
            updateDocument()
            present(true)
            val quote = pending
            pending = null
            if (quote == null) web.conversation("openAgent")
            else web.conversation("attach", quote.toString())
        }

        private fun updateDocument() {
            val current = document()?.takeIf { it.document.uri == uri } ?: return
            web.setProjection(current.copy(token = token))
            web.conversation("documentBackground", background(current).toString())
        }

        private fun background(value: ReaderWeb.Projection) = JSONObject().put("text", value.document.text)
            .put("markdown", value.document.text).put("documentName", value.document.name)
            .put("images", org.json.JSONArray()).put("mode", "preview").put("scope", "document")

        private fun present(open: Boolean) {
            if (!ready) return
            web.conversation("presentation", JSONObject().put("revision", ++revision)
                .put("open", open).put("modal", true).toString())
        }

        private fun updateInput(method: String, text: String, epoch: Int) {
            if (!ready) return
            if (method == "commitAgentInput") updateDocument()
            web.conversation(method, JSONObject().put("text", text).put("epoch", epoch).toString())
        }

        private fun authorize(id: String) {
            val configured = connection
            if (configured == null) { resolve("resolveAgentConsent", id, false); return }
            val service = configured.service.toString()
            if (consent.getBoolean(service, false)) { resolve("resolveAgentConsent", id, true); return }
            if (consentDialog != null) { resolve("resolveAgentConsent", id, false); return }
            sheet.hideKeyboard()
            var allowed = false
            consentDialog = AlertDialog.Builder(activity).setTitle(R.string.ai_share_title)
                .setMessage(activity.getString(R.string.ai_share_message, service))
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.ai_allow) { _, _ ->
                    if (active === this && connection?.service == configured.service) {
                        consent.edit().putBoolean(service, true).apply()
                        allowed = true
                    }
                }.create().apply {
                    setOnDismissListener {
                        consentDialog = null
                        if (active === this@Conversation) resolve("resolveAgentConsent", id, allowed)
                    }
                    show()
                }
        }

        private fun resolve(method: String, id: String, allowed: Boolean) {
            web.conversation(method, JSONObject().put("id", id).put("token", token).put("allowed", allowed).toString())
        }

        private fun send(message: JSONObject) {
            val id = message.optString("id")
            val snapshot = message.optJSONObject("snapshot")
            val configured = connection
            if (id.isEmpty() || request?.isActive == true) return
            if (configured == null || snapshot == null || !consent.getBoolean(configured.service.toString(), false)) {
                event(id, "failure", JSONObject().put("failure", JSONObject().put("kind", "permission")))
                return
            }
            requestID = id
            request = scope.launch {
                try {
                    val language = if (activity.getString(R.string.web_language) == "zh-Hans") "Simplified Chinese" else "English"
                    val context = withContext(Dispatchers.Default) { ConversationContext.messages(snapshot, language) }
                    client.stream(configured, context) { delta ->
                        withContext(Dispatchers.Main.immediate) {
                            if (active === this@Conversation && requestID == id) {
                                event(id, "text", JSONObject().put("text", delta))
                            }
                        }
                    }
                    if (requestID == id) event(id, "complete")
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    if (requestID != id) return@launch
                    val failure = JSONObject().put("kind", when (error) {
                        is ModelFailure -> error.kind
                        is SocketTimeoutException -> "timeout"
                        is org.json.JSONException -> "response"
                        else -> "network"
                    })
                    if (error is ModelFailure) {
                        val details = listOfNotNull(error.status?.let { activity.getString(R.string.ai_http_error, it) }, error.detail)
                        if (details.isNotEmpty()) failure.put("message", details.joinToString(" · "))
                    }
                    Log.i(TAG, "request failed: ${failure.optString("kind")}")
                    event(id, "failure", JSONObject().put("failure", failure))
                } finally {
                    if (requestID == id) requestID = null
                }
            }
        }

        private fun event(id: String, type: String, value: JSONObject = JSONObject()) {
            value.put("token", token).put("id", id).put("type", type)
            web.conversation("agentEvent", value.toString())
        }

        private fun stop() {
            requestID = null
            request?.cancel()
            request = null
        }

        private fun clear() {
            AlertDialog.Builder(activity).setTitle(R.string.ai_clear_confirm).setMessage(R.string.ai_clear_body)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.ai_clear) { _, _ ->
                    stop()
                    web.conversation("clearAgentHistory", JSONObject().put("token", token).toString())
                }.show()
        }

        fun capture() {
            if (!ready || closed) return
            web.view.evaluateJavascript("window.MarkdownIt.captureRecovery()") { value -> save(value) }
        }

        private fun save(value: String?) {
            val json = value?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return
            val sequence = conversations.reserve()
            scope.launch(Dispatchers.IO) {
                try { conversations.save(uri, json, sequence) }
                catch (_: Exception) { Log.w(TAG, "could not save conversation") }
            }
        }

        fun finish() {
            closed = true
            captureTask?.cancel()
            stop()
            sheet.setOnDismissListener(null)
            sheet.dismiss()
            if (ready) web.view.evaluateJavascript("window.MarkdownIt.captureRecovery()") { value ->
                save(value)
                web.view.destroy()
            } else web.view.destroy()
        }
    }

    private companion object { const val TAG = "MarkdownItModel" }
}
