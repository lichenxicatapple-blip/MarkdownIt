package dev.catli.markdownit

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.view.ActionMode
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import java.io.ByteArrayInputStream
import java.io.InputStream
import org.json.JSONObject

internal class ReaderWeb(
    context: Context,
    private val files: DocumentFiles,
    private val onMessage: (JSONObject, JavaScriptReplyProxy) -> Unit,
    private val onRendererGone: () -> Unit,
    supportsQuote: Boolean = false,
) {
    data class Projection(val document: MarkdownFile, val folder: Uri?, val token: String)
    enum class Surface(val page: String) { Reader("index.html"), Conversation("conversation.html") }

    val view: WebView = if (supportsQuote) QuoteWebView(context) else WebView(context)
    @Volatile private var projection: Projection? = null
    private val assets = WebViewAssetLoader.Builder()
        .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(context))
        .build()

    @SuppressLint("SetJavaScriptEnabled")
    fun start(surface: Surface = Surface.Reader): Boolean {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) return false
        view.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            blockNetworkLoads = true
        }
        view.setBackgroundColor(if (surface == Surface.Conversation) Color.TRANSPARENT
            else view.context.getColor(R.color.reader_surface))
        WebViewCompat.addWebMessageListener(view, "MarkdownItAndroid", setOf(ORIGIN)) { _, message, _, main, reply ->
            if (main) message.data?.let { value ->
                runCatching { JSONObject(value) }.getOrNull()?.let { onMessage(it, reply) }
            }
        }
        view.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse =
                serve(request.url)

            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = true

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                onRendererGone()
                return true
            }
        }
        view.loadUrl("$ORIGIN/assets/web/${surface.page}")
        return true
    }

    fun open(value: Projection, position: JSONObject?) {
        projection = value
        invoke("open", "${JSONObject.quote(value.token)},${position ?: JSONObject.NULL}")
    }

    fun setProjection(value: Projection) { projection = value }

    fun conversation(method: String, arguments: String = "") {
        view.evaluateJavascript("window.MarkdownIt.$method($arguments)", null)
    }

    fun setFolder(folder: Uri?) {
        projection = projection?.copy(folder = folder)
        invoke("reloadResources")
    }

    fun invoke(method: String, arguments: String = "") {
        view.evaluateJavascript("window.AndroidMarkdownIt.$method($arguments)", null)
    }

    fun capturePosition(completion: (JSONObject?) -> Unit) {
        view.evaluateJavascript("window.MarkdownIt?.captureRecovery()") { value ->
            completion(runCatching { JSONObject(value) }.getOrNull()?.takeIf(ReadingState::validPosition))
        }
    }

    private fun serve(uri: Uri): WebResourceResponse {
        if (uri.scheme != "https" || uri.host != HOST || uri.port != -1) return missing(403)
        if (uri.path == "/reader-locales.js") {
            val language = view.context.getString(R.string.web_language)
            val script = "window.MarkdownItLanguages = [${JSONObject.quote(language)}];"
            return privateResponse("application/javascript", "UTF-8", script.byteInputStream())
        }
        assets.shouldInterceptRequest(uri)?.let { return it }
        val active = projection ?: return missing()
        return runCatching {
            when (uri.path) {
                "/document/${active.token}" -> {
                    val value = JSONObject().put("text", active.document.text).put("name", active.document.name)
                    privateResponse("application/json", "UTF-8", value.toString().byteInputStream())
                }
                "/resource/${active.token}" -> image(active, uri.getQueryParameter("path"))
                else -> missing()
            }
        }.getOrElse { missing() }
    }

    private fun image(active: Projection, path: String?): WebResourceResponse {
        if (path == null) return missing()
        val result = files.resolve(active.document, path, active.folder) as? DocumentFiles.Resource.File ?: return missing()
        val mime = files.mimeType(result.uri, path)?.takeIf { it.startsWith("image/") } ?: return missing()
        val data = view.context.contentResolver.openInputStream(result.uri) ?: return missing()
        return privateResponse(mime, null, data)
    }

    private fun privateResponse(mime: String, charset: String?, data: InputStream) = WebResourceResponse(
        mime, charset, 200, "OK", mapOf("Cache-Control" to "no-store"), data,
    )

    private fun missing(status: Int = 404) = WebResourceResponse(
        "text/plain", "UTF-8", status, if (status == 403) "Forbidden" else "Not Found",
        emptyMap(), ByteArrayInputStream(ByteArray(0)),
    )

    private class QuoteWebView(context: Context) : WebView(context) {
        override fun startActionMode(callback: ActionMode.Callback, type: Int): ActionMode? {
            if (type != ActionMode.TYPE_FLOATING) return super.startActionMode(callback, type)
            return super.startActionMode(QuoteActionMode(context.getString(R.string.ai_reference), callback) { mode ->
                evaluateJavascript("window.MarkdownIt?.askSelection()") { mode.finish() }
            }, type)
        }
    }

    companion object {
        private const val HOST = "appassets.androidplatform.net"
        private const val ORIGIN = "https://$HOST"
    }
}
