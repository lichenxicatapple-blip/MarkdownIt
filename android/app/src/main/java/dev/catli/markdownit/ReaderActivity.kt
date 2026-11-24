package dev.catli.markdownit

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.animation.ValueAnimator
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.net.Uri
import android.os.Bundle
import android.os.Process
import android.content.pm.PackageManager
import android.transition.AutoTransition
import android.transition.TransitionManager
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowInsets
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputConnectionWrapper
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.widget.doAfterTextChanged
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebViewFeature
import dev.catli.markdownit.ai.AndroidAssistant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.UUID
import kotlin.math.max

class ReaderActivity : ComponentActivity() {
    private lateinit var files: DocumentFiles
    private lateinit var saved: ReadingState
    private lateinit var drafts: SourceDrafts
    private lateinit var assistant: AndroidAssistant
    private lateinit var root: FrameLayout
    private var web: ReaderWeb? = null
    private var pageReady = false
    private var opened = false
    private var document: MarkdownFile? = null
    private var token = ""
    private var folder: Uri? = null
    private var position: JSONObject? = null
    private var checkpoint: Job? = null
    private var pendingOpen: Job? = null
    private var rendererRestarted = false
    private var hasOutline = false
    private var outlineOpen = false
    private var imagePaths = emptyList<String>()
    private var checkedImages = false
    private var folderRequest: FolderRequest? = null
    private var folderDialog: AlertDialog? = null
    private var folderCheck: Job? = null
    private var loading: ProgressBar? = null
    private var findBar: LinearLayout? = null
    private var findInput: EditText? = null
    private var findCount: TextView? = null
    private var findPrevious: ImageButton? = null
    private var findNext: ImageButton? = null
    private var findTask: Job? = null
    private var outlineButton: ImageButton? = null
    private var exitButton: ImageButton? = null
    private var backButton: ImageButton? = null
    private var tools: LinearLayout? = null
    private var toolToggle: ImageButton? = null
    private var modeButton: ImageButton? = null
    private var findButton: ImageButton? = null
    private var undoButton: ImageButton? = null
    private var redoButton: ImageButton? = null
    private var aiButton: ImageButton? = null
    private var toolsExpanded = false
    private var sourceVisible = false
    private var sourceEditor: SourceEditor? = null
    private var editSession: SourceDrafts.Session? = null
    private var autosave: Job? = null
    private var switchingMode = false
    private var closing = false
    private var recentLookup: Job? = null
    private var recentSheet: RecentDocumentsSheet? = null
    private val visits = ArrayDeque<Uri>()

    private data class FolderRequest(val path: String, val need: DocumentFiles.Resource.NeedsFolder, val link: Boolean)
    private enum class Navigation { Open, Follow, Back }

    private val openPicker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let { open(it, retainGrant = true) }
    }
    private val createPicker = registerForActivityResult(ActivityResultContracts.CreateDocument("text/markdown")) { uri ->
        uri?.let { open(it, retainGrant = true, newDocument = true) }
    }
    private val folderPicker = registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { tree ->
        val request = folderRequest
        folderRequest = null
        val current = document
        if (tree != null && request != null && current != null) receiveFolder(current, tree, request)
    }

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        enableEdgeToEdge()
        files = DocumentFiles(applicationContext)
        saved = ReadingState(getSharedPreferences("reading", MODE_PRIVATE))
        drafts = SourceDrafts(this, files)
        assistant = AndroidAssistant(this, files, ::currentProjection, ::openLink)
        root = FrameLayout(this).apply { setBackgroundColor(getColor(R.color.reader_surface)) }
        root.setOnApplyWindowInsetsListener { view, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            val keyboard = insets.getInsets(WindowInsets.Type.ime())
            view.setPadding(bars.left, bars.top, bars.right, max(bars.bottom, keyboard.bottom))
            insets
        }
        setContentView(root)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                when {
                    findBar != null -> dismissFind()
                    outlineOpen -> web?.invoke("outline", "false")
                    toolsExpanded -> toggleTools()
                    visits.isNotEmpty() -> goBack()
                    document != null -> closeDocument()
                    else -> finish()
                }
            }
        })
        state?.getStringArrayList("visits")?.mapTo(visits, Uri::parse)
        val incoming = intent.takeIf { state == null && it.action == Intent.ACTION_VIEW }?.data
        val initial = incoming ?: saved.active
        if (initial == null) showHome() else {
            showLoading()
            open(initial, retainGrant = incoming != null, restoring = incoming == null)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == Intent.ACTION_VIEW) intent.data?.let { open(it, retainGrant = true) }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        savePosition()
        assistant.checkpoint()
        outState.putStringArrayList("visits", ArrayList(visits.map(Uri::toString)))
        super.onSaveInstanceState(outState)
    }

    override fun onPause() {
        savePosition()
        assistant.checkpoint()
        queueSourceSave(immediate = true)
        super.onPause()
    }

    override fun onDestroy() {
        recentSheet?.dismiss()
        assistant.destroy()
        destroyWeb()
        super.onDestroy()
    }

    private fun open(uri: Uri, navigation: Navigation = Navigation.Open, retainGrant: Boolean = false,
                     restoring: Boolean = false, newDocument: Boolean = false,
                     onCompleted: ((Boolean) -> Unit)? = null) {
        pendingOpen?.cancel()
        pendingOpen = lifecycleScope.launch {
            val flushed = saveSource()
            if (flushed.isFailure) {
                onCompleted?.invoke(false)
                showSaveError(closingDocument = false, conflict = flushed.exceptionOrNull() is DocumentFiles.DocumentChanged) {
                    open(uri, navigation, retainGrant, restoring, newDocument, onCompleted)
                }
                return@launch
            }
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val file = files.readMarkdown(uri)
                    if (retainGrant) files.persist(uri, writable = true)
                    file to files.isDurable(uri)
                }
            }
            val (file, durable) = result.getOrElse { error ->
                if (document == null) {
                    if (restoring) saved.closed()
                    showHome()
                }
                onCompleted?.invoke(false)
                alert(if (error is IllegalArgumentException && !restoring) R.string.not_markdown else R.string.document_unavailable)
                return@launch
            }
            val writable = checkUriPermission(file.uri, Process.myPid(), Process.myUid(), Intent.FLAG_GRANT_WRITE_URI_PERMISSION) ==
                PackageManager.PERMISSION_GRANTED
            val session = drafts.start(file, writable)
            savePosition()
            when (navigation) {
                Navigation.Open -> if (!restoring) visits.clear()
                Navigation.Follow -> document?.uri?.let(visits::addLast)
                Navigation.Back -> visits.removeLastOrNull()
            }
            assistant.closeDocument()
            document = file
            saved.opened(file, durable)
            position = saved.position(file.uri)
            folder = saved.folder(file.uri)
            removeSourceEditor()
            editSession = session
            sourceVisible = newDocument || (restoring && session.restored?.source == true)
            if (sourceVisible || session.restored != null) installSourceEditor(session)
            checkedImages = false
            rendererRestarted = false
            displayDocument()
            if (sourceVisible) {
                sourceEditor?.restore(session.restored?.anchor, placeCursor = false)
                if (newDocument && writable) focusEditor()
                queueSourceSave(immediate = true)
            }
            onCompleted?.invoke(true)
        }
    }

    private fun displayDocument() {
        cancelFind(restoreControls = false)
        folderCheck?.cancel()
        folderDialog?.dismiss()
        folderRequest = null
        toolsExpanded = false
        token = UUID.randomUUID().toString()
        opened = false
        outlineOpen = false
        hasOutline = false
        imagePaths = emptyList()
        if (web == null) mountWeb()
        else if (pageReady && !sourceVisible) projectDocument()
        updateControls()
    }

    private fun mountWeb() {
        lateinit var reader: ReaderWeb
        reader = ReaderWeb(this, files, onMessage = { message, reply ->
            if (web === reader) receiveWebMessage(message, reply)
        }, onRendererGone = {
            if (web === reader) rendererGone()
        }, supportsQuote = true)
        web = reader
        pageReady = false
        root.removeAllViews()
        root.addView(reader.view, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        sourceEditor?.let { root.addView(it, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)) }
        outlineButton = addFloatingButton(R.drawable.ic_outline, R.string.contents, Gravity.TOP or Gravity.START) {
            reader.invoke("toggleOutline")
        }
        backButton = addFloatingButton(R.drawable.ic_back, R.string.back_to_document, Gravity.TOP or Gravity.START) { goBack() }
        exitButton = addFloatingButton(R.drawable.ic_close, R.string.close_document, Gravity.TOP or Gravity.END) { closeDocument() }
        mountTools()
        loading = ProgressBar(this).apply {
            contentDescription = getString(R.string.reading)
            root.addView(this, FrameLayout.LayoutParams(dp(32), dp(32), Gravity.CENTER))
        }
        if (!reader.start()) { closeDocument(); alert(R.string.webview_unavailable) }
    }

    private fun currentProjection(): ReaderWeb.Projection? {
        val document = document ?: return null
        val current = sourceEditor?.let { document.copy(text = it.text.toString()) } ?: document
        return ReaderWeb.Projection(current, folder, token)
    }

    private fun projectDocument() {
        if (!sourceVisible) currentProjection()?.let { web?.open(it, position) }
    }

    private fun rendererGone() {
        savePosition()
        destroyWeb()
        if (document != null && !rendererRestarted) {
            rendererRestarted = true
            displayDocument()
        } else {
            closeDocument()
            alert(R.string.render_failed)
        }
    }

    private fun destroyWeb() {
        val old = web ?: return
        root.removeView(old.view)
        web = null
        pageReady = false
        old.view.destroy()
    }

    private fun receiveWebMessage(message: JSONObject, reply: JavaScriptReplyProxy) {
        val type = message.optString("type")
        if (type == "ready") {
            if (!pageReady) { pageReady = true; projectDocument() }
            return
        }
        if (type == "unsupported") { closeDocument(); alert(R.string.webview_unavailable); return }
        if (message.optString("token") != token || document == null) return
        when (type) {
            "opened" -> {
                opened = true
                hasOutline = message.optBoolean("hasOutline")
                updateControls()
                checkImages()
            }
            "renderFailed" -> {
                loading?.visibility = View.GONE
                AlertDialog.Builder(this).setMessage(R.string.render_failed)
                    .setPositiveButton(R.string.retry) { _, _ -> displayDocument() }
                    .setNegativeButton(R.string.close_document) { _, _ -> closeDocument() }.show()
            }
            "outline" -> {
                outlineOpen = message.optBoolean("open")
                outlineButton?.isSelected = outlineOpen
            }
            "position" -> message.optJSONObject("snapshot")?.takeIf { !sourceVisible && ReadingState.validPosition(it) }?.let {
                position = it
                if (checkpoint?.isActive != true) checkpoint = lifecycleScope.launch {
                    delay(250)
                    savePosition()
                }
            }
            "localResources" -> {
                val values = message.optJSONArray("paths") ?: return
                imagePaths = (0 until values.length()).map { values.optString(it) }.distinct()
            }
            "find" -> showMatchCount(message.optInt("active"), message.optInt("count"))
            "link" -> openLink(message.optString("href"))
            "selectionReference" -> message.optJSONObject("attachment")?.let(assistant::enter)
            "imageMenu" -> message.optJSONObject("reference")?.optString("source")?.let(::openLink)
            "copyCode" -> {
                val clipboard = getSystemService(ClipboardManager::class.java)
                clipboard.setPrimaryClip(ClipData.newPlainText(null, message.optString("text")))
                if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
                    reply.postMessage(JSONObject().put("id", message.optString("id")).put("copied", true).toString())
                }
            }
        }
    }

    private fun goBack() { visits.lastOrNull()?.let { open(it, navigation = Navigation.Back) } }

    private fun closeDocument() {
        if (closing) return
        if (sourceEditor == null) { finishClosing(); return }
        closing = true
        sourceEditor?.isEnabled = false
        lifecycleScope.launch {
            val result = saveSource()
            closing = false
            if (result.isSuccess) finishClosing() else {
                sourceEditor?.isEnabled = true
                showSaveError(closingDocument = true, conflict = result.exceptionOrNull() is DocumentFiles.DocumentChanged)
            }
        }
    }

    private fun finishClosing() {
        pendingOpen?.cancel()
        folderCheck?.cancel()
        folderDialog?.dismiss()
        folderRequest = null
        cancelFind(restoreControls = false)
        savePosition()
        assistant.closeDocument()
        saved.closed()
        visits.clear()
        document = null
        removeSourceEditor()
        editSession = null
        sourceVisible = false
        opened = false
        token = ""
        destroyWeb()
        showHome()
    }

    private fun savePosition() {
        checkpoint?.cancel()
        checkpoint = null
        val current = document ?: return
        position?.let { saved.savePosition(current.uri, it) }
    }

    private fun installSourceEditor(session: SourceDrafts.Session): SourceEditor = SourceEditor(this, session).also { editor ->
        sourceEditor = editor
        editor.visibility = if (sourceVisible) View.VISIBLE else View.GONE
        editor.onChange = {
            checkedImages = false
            updateControls()
            queueSourceSave()
        }
        editor.customSelectionActionModeCallback = QuoteActionMode(getString(R.string.ai_reference)) { mode ->
            val start = minOf(editor.selectionStart, editor.selectionEnd)
            val end = maxOf(editor.selectionStart, editor.selectionEnd)
            if (start >= 0 && end > start) {
                val selected = editor.text.subSequence(start, end).toString()
                val ticks = Regex("`+").findAll(selected).maxOfOrNull { it.value.length } ?: 0
                val fence = "`".repeat(maxOf(3, ticks + 1))
                mode.finish()
                assistant.enter(JSONObject().put("text", selected).put("markdown", "$fence\n$selected\n$fence")
                    .put("mode", "source"))
            }
        }
        val index = if (web != null) 1 else 0
        root.addView(editor, index, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
    }

    private fun removeSourceEditor() {
        autosave?.cancel()
        sourceEditor?.let(root::removeView)
        sourceEditor = null
    }

    private fun focusEditor() {
        val editor = sourceEditor ?: return
        editor.requestFocus()
        editor.post { getSystemService(InputMethodManager::class.java).showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT) }
    }

    private fun queueSourceSave(immediate: Boolean = false) {
        if (sourceEditor == null || closing) return
        autosave?.cancel()
        autosave = lifecycleScope.launch(start = CoroutineStart.UNDISPATCHED) {
            if (!immediate) delay(450)
            saveSource()
        }
    }

    private suspend fun saveSource(): Result<Unit> {
        val editor = sourceEditor ?: return Result.success(Unit)
        val session = editSession ?: return Result.success(Unit)
        val snapshot = editor.snapshot(sourceVisible)
        val sequence = session.reserveSave()
        return runCatching { drafts.save(session, snapshot, sequence) }
    }

    private fun showSaveError(closingDocument: Boolean, conflict: Boolean = false, retry: () -> Unit = ::closeDocument) {
        if (isFinishing) return
        AlertDialog.Builder(this).setTitle(R.string.save_failed)
            .setMessage(if (conflict) R.string.document_changed else R.string.draft_kept)
            .setPositiveButton(R.string.retry) { _, _ -> retry() }
            .setNegativeButton(android.R.string.cancel, null)
            .apply {
                if (closingDocument) setNeutralButton(R.string.discard_changes) { _, _ ->
                    val session = editSession ?: return@setNeutralButton
                    autosave?.cancel()
                    lifecycleScope.launch {
                        drafts.discard(session)
                        finishClosing()
                    }
                }
            }.show()
    }

    private fun toggleMode() {
        if (switchingMode || closing) return
        val session = editSession ?: return
        toolsExpanded = false
        if (sourceVisible) {
            val editor = sourceEditor ?: return
            getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(editor.windowToken, 0)
            editor.clearFocus()
            editor.anchor()?.let { anchor ->
                position = (position ?: JSONObject()).put("mode", "preview").put("anchor", anchor)
            }
            sourceVisible = false
            savePosition()
            displayDocument()
            queueSourceSave(immediate = true)
        } else {
            val activeToken = token
            switchingMode = true
            web?.capturePosition { snapshot ->
                switchingMode = false
                if (token != activeToken || closing) return@capturePosition
                if (snapshot != null) position = snapshot
                savePosition()
                val editor = sourceEditor ?: installSourceEditor(session)
                sourceVisible = true
                outlineOpen = false
                web?.invoke("outline", "false")
                updateControls()
                editor.restore(position?.optJSONObject("anchor"), placeCursor = true)
                queueSourceSave(immediate = true)
                if (!session.writable) alert(R.string.document_read_only)
            } ?: run { switchingMode = false }
        }
    }

    private fun checkImages() {
        if (checkedImages || folderRequest != null) return
        val doc = document ?: return
        val candidates = imagePaths
        val granted = folder
        folderCheck?.cancel()
        folderCheck = lifecycleScope.launch {
            val request = withContext(Dispatchers.IO) {
                candidates.firstNotNullOfOrNull { path ->
                    val need = runCatching { files.resolve(doc, path, granted) }.getOrNull() as? DocumentFiles.Resource.NeedsFolder
                    need?.let { FolderRequest(path, it, link = false) }
                }
            }
            if (doc === document) {
                checkedImages = true
                request?.let(::askForFolder)
            }
        }
    }

    private fun openLink(href: String) {
        if (href.isEmpty()) return
        val uri = Uri.parse(href)
        if (uri.scheme in setOf("https", "http", "mailto")) { openExternally(uri, null); return }
        if (uri.scheme != null || uri.authority != null) return
        val doc = document ?: return
        val granted = folder
        lifecycleScope.launch {
            val resource = withContext(Dispatchers.IO) {
                runCatching { files.resolve(doc, href, granted) }.getOrDefault(DocumentFiles.Resource.Missing)
            }
            if (doc !== document) return@launch
            when (resource) {
                is DocumentFiles.Resource.File -> {
                    if (DocumentFiles.isMarkdown(uri.path.orEmpty())) {
                        open(resource.uri, navigation = Navigation.Follow)
                    } else {
                        val mime = withContext(Dispatchers.IO) { runCatching { files.mimeType(resource.uri, href) }.getOrNull() }
                        if (doc === document) openExternally(resource.uri, mime)
                    }
                }
                is DocumentFiles.Resource.NeedsFolder -> askForFolder(FolderRequest(href, resource, link = true))
                DocumentFiles.Resource.Missing -> alert(R.string.link_unavailable)
            }
        }
    }

    private fun openExternally(uri: Uri, mime: String?) {
        val intent = Intent(Intent.ACTION_VIEW).apply {
            if (mime == null) data = uri else setDataAndType(uri, mime)
            if (uri.scheme == "content") addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        runCatching { startActivity(intent) }.onFailure { alert(R.string.link_unavailable) }
    }

    private fun askForFolder(request: FolderRequest, wrongFolder: Boolean = false) {
        if (folderRequest != null || folderDialog?.isShowing == true || isFinishing) return
        val explanation = buildList {
            if (wrongFolder) add(getString(R.string.folder_wrong))
            add(getString(if (request.need.directory == null) R.string.document_folder_message else R.string.folder_message))
            request.need.directory?.takeIf(String::isNotEmpty)?.let(::add)
            if (request.need.downloadsRoot) add(getString(R.string.downloads_hint))
        }.joinToString("\n\n")
        folderDialog = AlertDialog.Builder(this).setTitle(if (request.link) R.string.link_folder_title else R.string.folder_title)
            .setMessage(explanation)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.choose_folder) { _, _ ->
                folderRequest = request
                runCatching { folderPicker.launch(null) }.onFailure { folderRequest = null; alert(R.string.folder_wrong) }
            }.show()
    }

    private fun receiveFolder(doc: MarkdownFile, tree: Uri, request: FolderRequest) {
        folderCheck?.cancel()
        folderCheck = lifecycleScope.launch {
            val accepted = withContext(Dispatchers.IO) {
                runCatching { files.acceptFolder(doc, tree, request.path) }.getOrDefault(false)
            }
            if (doc !== document) return@launch
            if (!accepted) { askForFolder(request, wrongFolder = true); return@launch }
            if (files.hasOpaqueLocation(doc)) {
                saved.setFolder(doc.uri, tree)
                folder = tree
            }
            web?.setFolder(folder)
            if (request.link) openLink(request.path) else {
                checkedImages = false
                checkImages()
            }
        }
    }

    private fun showHome() {
        root.removeAllViews()
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        val markSize = resources.getDimensionPixelSize(R.dimen.home_mark_size)
        val mark = ImageView(this).apply { setImageResource(R.drawable.brand_home) }
        column.addView(mark, LinearLayout.LayoutParams(markSize, markSize))
        column.addView(HomeSlogan(this), LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply {
            topMargin = dp(10)
        })
        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            // Give the platform button shadows room below the controls.
            clipToPadding = false
            setPadding(0, 0, 0, dp(8))
        }
        fun documentButton(id: Int, title: Int, backgroundColor: Int, textColor: Int, action: () -> Unit) =
            Button(this).apply {
                this.id = id
                setText(title)
                isAllCaps = false
                setTextColor(getColor(textColor))
                setPadding(dp(8), dp(10), dp(8), dp(10))
                background = ripple(backgroundColor, dp(28).toFloat())
                setOnClickListener { action() }
            }
        val open = documentButton(R.id.open_document, R.string.open_document, R.color.reader_accent, R.color.reader_on_accent) {
            openPicker.launch(arrayOf("*/*"))
        }
        val create = documentButton(R.id.create_document, R.string.create_document, R.color.reader_control, R.color.reader_text) {
            createPicker.launch(getString(R.string.untitled_filename))
        }
        actions.addView(open, LinearLayout.LayoutParams(0, MATCH_PARENT, 1f))
        actions.addView(create, LinearLayout.LayoutParams(0, MATCH_PARENT, 1f).apply { marginStart = dp(12) })
        val available = (resources.displayMetrics.widthPixels - dp(48)).coerceAtLeast(dp(160))
        column.addView(actions, LinearLayout.LayoutParams(minOf(dp(320), available), WRAP_CONTENT).apply { topMargin = dp(34) })
        column.addView(Button(this).apply {
            id = R.id.recent_documents
            setText(R.string.show_recent_documents)
            isAllCaps = false
            setTextColor(getColor(R.color.reader_secondary))
            background = null
            setOnClickListener { showRecents() }
        })
        root.addView(ScrollView(this).apply {
            isFillViewport = true
            addView(FrameLayout(this@ReaderActivity).apply {
                addView(column, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.CENTER))
            })
        }, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
    }

    private fun showRecents() {
        if (recentSheet != null || recentLookup?.isActive == true) return
        val recent = saved.recent()
        recentLookup = lifecycleScope.launch {
            val parents = withContext(Dispatchers.IO) { recent.associate { it.uri to files.parentName(it.uri) } }
            if (document != null || isFinishing || !lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) return@launch
            val sheet = RecentDocumentsSheet(this@ReaderActivity, recent, parents::get) { document, completed ->
                open(document.uri, onCompleted = completed)
            }
            recentSheet = sheet
            sheet.setOnDismissListener { if (recentSheet === sheet) recentSheet = null }
            sheet.show()
        }
    }

    private fun showLoading() {
        root.removeAllViews()
        root.addView(ProgressBar(this).apply { contentDescription = getString(R.string.reading) },
            FrameLayout.LayoutParams(dp(32), dp(32), Gravity.CENTER))
    }

    private fun showFind() {
        if ((!opened && !sourceVisible) || findBar != null) return
        val reader = web ?: return
        if (outlineOpen) reader.invoke("outline", "false")
        toolsExpanded = false
        fun find(query: String) {
            if (sourceVisible) sourceEditor?.search(query)?.let { (active, count) -> showMatchCount(active, count) }
            else reader.invoke("setFind", JSONObject.quote(query))
        }
        fun match(delta: Int) {
            if (sourceVisible) sourceEditor?.match(delta)?.let { (active, count) -> showMatchCount(active, count) }
            else reader.invoke("showMatch", delta.toString())
        }
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = ripple(R.color.reader_control, dp(26).toFloat())
            elevation = dp(3).toFloat()
            setPadding(dp(10), 0, dp(2), 0)
        }
        val input = FindField(this).apply {
            id = R.id.find_field
            setHint(R.string.find)
            setSingleLine()
            textSize = 16f
            background = null
            imeOptions = EditorInfo.IME_ACTION_SEARCH
            setOnEditorActionListener { _, action, _ ->
                if (action == EditorInfo.IME_ACTION_SEARCH) { match(1); true } else false
            }
            val queueFind = {
                findTask?.cancel()
                findTask = lifecycleScope.launch {
                    delay(100)
                    if (findInput === this@apply && BaseInputConnection.getComposingSpanStart(text) < 0) {
                        find(text.toString())
                    }
                }
                Unit
            }
            doAfterTextChanged { queueFind() }
            onCommitted = queueFind
        }
        val count = TextView(this).apply {
            id = R.id.find_count
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            textSize = 12f
            setTextColor(getColor(R.color.reader_secondary))
        }
        val previous = iconButton(R.drawable.ic_up, R.string.previous_match) { match(-1) }
        val next = iconButton(R.drawable.ic_down, R.string.next_match) { match(1) }
        bar.addView(input, LinearLayout.LayoutParams(0, dp(48), 1f))
        bar.addView(count, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
        bar.addView(previous, LinearLayout.LayoutParams(dp(44), dp(48)))
        bar.addView(next, LinearLayout.LayoutParams(dp(44), dp(48)))
        bar.addView(iconButton(R.drawable.ic_close, R.string.close_find) { dismissFind() }, LinearLayout.LayoutParams(dp(44), dp(48)))
        findBar = bar
        findInput = input
        findCount = count
        findPrevious = previous
        findNext = next
        showMatchCount(0, 0)
        root.addView(bar, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.TOP).apply {
            setMargins(dp(10), dp(8), dp(10), 0)
        })
        updateControls()
        input.requestFocus()
        input.post { getSystemService(InputMethodManager::class.java).showSoftInput(input, InputMethodManager.SHOW_IMPLICIT) }
    }

    private fun showMatchCount(active: Int, count: Int) {
        val query = findInput?.text?.toString()?.isNotBlank() == true
        findCount?.text = when {
            count > 0 -> getString(R.string.match_count, active, count)
            query -> getString(R.string.no_matches)
            else -> ""
        }
        findPrevious?.isEnabled = count > 0
        findNext?.isEnabled = count > 0
    }

    private fun dismissFind() = cancelFind(restoreControls = true)

    private fun cancelFind(restoreControls: Boolean) {
        val bar = findBar ?: return
        findInput?.let { getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(it.windowToken, 0) }
        findTask?.cancel()
        if (sourceVisible) sourceEditor?.clearSearch() else web?.invoke("setFind", "\"\"")
        root.removeView(bar)
        findBar = null
        findInput = null
        findCount = null
        findPrevious = null
        findNext = null
        if (restoreControls) updateControls()
    }

    private fun updateControls() {
        val ready = opened || sourceVisible
        val visible = ready && findBar == null
        web?.view?.visibility = if (sourceVisible) View.INVISIBLE else View.VISIBLE
        sourceEditor?.visibility = if (sourceVisible) View.VISIBLE else View.GONE
        loading?.visibility = if (ready) View.GONE else View.VISIBLE
        outlineButton?.visibility = if (visible && hasOutline && !sourceVisible) View.VISIBLE else View.GONE
        backButton?.visibility = if (visible && visits.isNotEmpty()) View.VISIBLE else View.GONE
        outlineButton?.let { button ->
            val params = button.layoutParams as FrameLayout.LayoutParams
            params.marginStart = dp(if (visits.isEmpty()) 12 else 68)
            button.layoutParams = params
        }
        exitButton?.visibility = if (visible) View.VISIBLE else View.GONE
        tools?.visibility = if (visible) View.VISIBLE else View.GONE
        modeButton?.visibility = if (toolsExpanded) View.VISIBLE else View.GONE
        findButton?.visibility = if (toolsExpanded) View.VISIBLE else View.GONE
        aiButton?.visibility = if (toolsExpanded) View.VISIBLE else View.GONE
        val sourceTools = toolsExpanded && sourceVisible
        undoButton?.visibility = if (sourceTools) View.VISIBLE else View.GONE
        redoButton?.visibility = if (sourceTools) View.VISIBLE else View.GONE
        undoButton?.isEnabled = sourceEditor?.canUndo == true
        redoButton?.isEnabled = sourceEditor?.canRedo == true
        undoButton?.alpha = if (undoButton?.isEnabled == true) 1f else .45f
        redoButton?.alpha = if (redoButton?.isEnabled == true) 1f else .45f
        modeButton?.setImageResource(if (sourceVisible) R.drawable.ic_preview else R.drawable.ic_source)
        modeButton?.contentDescription = getString(if (sourceVisible) R.string.preview_mode else R.string.source_mode)
        toolToggle?.let { toggle ->
            val label = getString(if (toolsExpanded) R.string.close_tools else R.string.open_tools)
            if (toggle.contentDescription != label) {
                toggle.contentDescription = label
                val rotation = if (toolsExpanded) 180f else 0f
                if (ValueAnimator.areAnimatorsEnabled()) toggle.animate().rotation(rotation).setDuration(180).start()
                else toggle.rotation = rotation
            }
        }
    }

    private fun mountTools() {
        val row = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        val gap = ((resources.displayMetrics.widthPixels - dp(12) - 6 * dp(48)) / 6).coerceIn(0, dp(8))
        fun add(icon: Int, name: Int, action: () -> Unit) = iconButton(icon, name, action).also { button ->
            button.elevation = dp(2).toFloat()
            row.addView(button, LinearLayout.LayoutParams(dp(48), dp(48)).apply { marginStart = gap })
        }
        undoButton = add(R.drawable.ic_undo, R.string.undo) { sourceEditor?.undo() }
        redoButton = add(R.drawable.ic_redo, R.string.redo) { sourceEditor?.redo() }
        findButton = add(R.drawable.ic_find, R.string.find) { showFind() }
        modeButton = add(R.drawable.ic_source, R.string.source_mode) { toggleMode() }
        aiButton = add(R.drawable.ic_ai, R.string.ai_action) { assistant.enter() }.apply { id = R.id.open_ai }
        toolToggle = add(R.drawable.ic_tools, R.string.open_tools) { toggleTools() }.apply { id = R.id.tools_toggle }
        tools = row
        root.addView(row, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.BOTTOM or Gravity.END).apply {
            marginEnd = dp(12)
            bottomMargin = dp(12)
        })
    }

    private fun toggleTools() {
        if (ValueAnimator.areAnimatorsEnabled()) {
            val transition = AutoTransition().setDuration(180)
            tools?.let(transition::addTarget)
            TransitionManager.beginDelayedTransition(root, transition)
        }
        toolsExpanded = !toolsExpanded
        updateControls()
    }

    private fun addFloatingButton(icon: Int, label: Int, gravity: Int, action: () -> Unit): ImageButton =
        iconButton(icon, label, action).also { button ->
            button.elevation = dp(2).toFloat()
            root.addView(button, FrameLayout.LayoutParams(dp(48), dp(48), gravity).apply {
                setMargins(dp(12), dp(8), dp(12), dp(12))
                marginStart = dp(12)
                marginEnd = dp(12)
            })
        }

    private fun iconButton(icon: Int, label: Int, action: () -> Unit) = ImageButton(this).apply {
        setImageResource(icon)
        imageTintList = ColorStateList.valueOf(getColor(R.color.reader_text))
        contentDescription = getString(label)
        background = ripple(R.color.reader_control, dp(24).toFloat())
        scaleType = ImageView.ScaleType.CENTER
        setOnClickListener { action() }
    }

    private fun ripple(color: Int, radius: Float): RippleDrawable {
        val shape = GradientDrawable().apply { cornerRadius = radius; setColor(getColor(color)) }
        return RippleDrawable(ColorStateList.valueOf(getColor(R.color.reader_pressed)), shape, null)
    }

    private fun alert(message: Int) {
        if (!isFinishing) AlertDialog.Builder(this).setMessage(message).setPositiveButton(android.R.string.ok, null).show()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density + .5f).toInt()

    // Home uses the Android platform theme.
    @SuppressLint("AppCompatCustomView")
    private class HomeSlogan(context: Context) : TextView(context) {
        private val slogan = context.getString(R.string.slogan)
        private val twoLines = slogan.replaceFirst(", ", ",\n")

        init {
            gravity = Gravity.CENTER
            typeface = resources.getFont(R.font.newsreader_regular)
            setTextSize(TypedValue.COMPLEX_UNIT_PX, resources.getDimension(R.dimen.home_slogan_size))
            setTextColor(context.getColor(R.color.reader_text))
            contentDescription = slogan
        }

        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            val availableWidth = MeasureSpec.getSize(widthMeasureSpec) - compoundPaddingLeft - compoundPaddingRight
            val fits = MeasureSpec.getMode(widthMeasureSpec) == MeasureSpec.UNSPECIFIED || paint.measureText(slogan) <= availableWidth
            val display = if (fits) slogan else twoLines
            if (!TextUtils.equals(text, display)) text = display
            super.onMeasure(widthMeasureSpec, heightMeasureSpec)
        }
    }

    // This field is displayed in the Android platform-themed reader.
    @SuppressLint("AppCompatCustomView")
    private class FindField(context: Context) : EditText(context) {
        var onCommitted: (() -> Unit)? = null

        override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? =
            super.onCreateInputConnection(outAttrs)?.let { connection ->
                object : InputConnectionWrapper(connection, false) {
                    override fun finishComposingText(): Boolean = super.finishComposingText().also { onCommitted?.invoke() }
                    override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean =
                        super.commitText(text, newCursorPosition).also { onCommitted?.invoke() }
                }
            }
    }
}
