package dev.catli.markdownit

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Typeface
import android.os.SystemClock
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.text.style.BackgroundColorSpan
import android.view.Gravity
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import androidx.core.view.doOnNextLayout
import org.json.JSONObject
import java.util.regex.Pattern
import kotlin.math.floor

// The reader uses the Android platform theme, separate from the Material sheet.
@SuppressLint("AppCompatCustomView")
internal class SourceEditor(context: Context, session: SourceDrafts.Session) : EditText(context) {
    private val undo = ArrayDeque(session.restored?.undo.orEmpty())
    private val redo = ArrayDeque(session.restored?.redo.orEmpty())
    private var change: SourceChange? = null
    private var replaying = false
    private var lastTyping = 0L
    private var findRanges = emptyList<MatchResult>()
    private var findIndex = -1
    private var findSpan: BackgroundColorSpan? = null
    var onChange: (() -> Unit)? = null
    val canUndo get() = undo.isNotEmpty() && keyListener != null
    val canRedo get() = redo.isNotEmpty() && keyListener != null

    init {
        id = R.id.source_editor
        contentDescription = context.getString(R.string.source_editor)
        gravity = Gravity.TOP or Gravity.START
        setTextColor(context.getColor(R.color.reader_text))
        setBackgroundColor(context.getColor(R.color.reader_surface))
        setPadding(dp(18), dp(70), dp(18), dp(80))
        textSize = 15f
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        imeOptions = EditorInfo.IME_FLAG_NO_ENTER_ACTION or EditorInfo.IME_FLAG_NO_EXTRACT_UI
        typeface = Typeface.MONOSPACE
        setHorizontallyScrolling(false)
        setText(session.restored?.text ?: session.file.text)
        isSaveEnabled = false
        if (!session.writable) {
            keyListener = null
            setTextIsSelectable(true)
        }
        val start = session.restored?.selectionStart?.coerceIn(0, length()) ?: 0
        val end = session.restored?.selectionEnd?.coerceIn(0, length()) ?: start
        setSelection(start, end)
        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(text: CharSequence, start: Int, count: Int, after: Int) {
                if (!replaying) change = SourceChange(start, text.subSequence(start, start + count).toString(), "")
            }
            override fun onTextChanged(text: CharSequence, start: Int, before: Int, count: Int) {
                change = change?.copy(inserted = text.subSequence(start, start + count).toString())
            }
            override fun afterTextChanged(text: Editable) {
                val edit = change ?: return
                change = null
                if (edit.removed == edit.inserted) return
                record(edit)
                onChange?.invoke()
            }
        })
    }

    private fun record(edit: SourceChange) {
        val previous = undo.lastOrNull()
        val now = SystemClock.uptimeMillis()
        val continueTyping = previous != null && previous.removed.isEmpty() && edit.removed.isEmpty() &&
            edit.inserted.length == 1 && !edit.inserted.single().isWhitespace() && '\n' !in previous.inserted &&
            edit.start == previous.start + previous.inserted.length && now - lastTyping < 700
        if (continueTyping && previous != null) {
            undo.removeLast()
            undo.addLast(previous.copy(inserted = previous.inserted + edit.inserted))
        } else {
            undo.addLast(edit)
            if (undo.size > 150) undo.removeFirst()
        }
        lastTyping = now
        redo.clear()
    }

    fun undo() { applyChange(undo, redo, reversing = true) }
    fun redo() { applyChange(redo, undo, reversing = false) }

    private fun applyChange(from: ArrayDeque<SourceChange>, to: ArrayDeque<SourceChange>, reversing: Boolean) {
        if (keyListener == null) return
        val edit = from.lastOrNull() ?: return
        val original = if (reversing) edit.inserted else edit.removed
        val replacement = if (reversing) edit.removed else edit.inserted
        val end = edit.start + original.length
        if (edit.start < 0 || end !in edit.start..length() || text.substring(edit.start, end) != original) {
            undo.clear()
            redo.clear()
            onChange?.invoke()
            return
        }
        replaying = true
        try {
            text.replace(edit.start, end, replacement)
            setSelection(edit.start + replacement.length)
        } finally { replaying = false }
        from.removeLast()
        to.addLast(edit)
        lastTyping = 0
        onChange?.invoke()
    }

    override fun onKeyShortcut(keyCode: Int, event: KeyEvent): Boolean {
        if (event.isCtrlPressed && keyCode == KeyEvent.KEYCODE_Z) {
            if (event.isShiftPressed) redo() else undo()
            return true
        }
        if (event.isCtrlPressed && keyCode == KeyEvent.KEYCODE_Y) { redo(); return true }
        return super.onKeyShortcut(keyCode, event)
    }

    fun snapshot(source: Boolean) = SourceSnapshot(text.toString(), source, selectionStart, selectionEnd,
        anchor(), undo.toList(), redo.toList())

    fun anchor(): JSONObject? {
        val layout = layout ?: return null
        val visible = layout.getLineForVertical(scrollY)
        val offset = layout.getLineStart(visible).coerceIn(0, length())
        var line = 0
        for (index in 0 until offset) if (text[index] == '\n') line++
        return JSONObject().put("line", line).put("y", 20).put("atStart", scrollY == 0)
    }

    fun restore(anchor: JSONObject?, placeCursor: Boolean) {
        if (anchor == null) return
        val target = floor(anchor.optDouble("line", 0.0)).toInt().coerceAtLeast(0)
        var line = 0
        var offset = 0
        while (offset < length() && line < target) if (text[offset++] == '\n') line++
        if (placeCursor) setSelection(offset)
        val scroll = {
            val layout = layout
            if (layout != null) scrollTo(0, layout.getLineTop(layout.getLineForOffset(offset)))
        }
        if (isLayoutRequested || layout == null) doOnNextLayout { scroll() } else scroll()
    }

    fun search(query: String): Pair<Int, Int> {
        clearSearch()
        if (query.isNotBlank()) findRanges = Pattern.quote(query).toRegex(RegexOption.IGNORE_CASE).findAll(text).toList()
        return match(1)
    }

    fun match(delta: Int): Pair<Int, Int> {
        if (findRanges.isEmpty()) return 0 to 0
        findIndex = (findIndex + delta + findRanges.size) % findRanges.size
        val range = findRanges[findIndex].range
        findSpan?.let(text::removeSpan)
        val span = BackgroundColorSpan(0x664E79DC)
        text.setSpan(span, range.first, range.last + 1, Editable.SPAN_EXCLUSIVE_EXCLUSIVE)
        findSpan = span
        layout?.let { scrollTo(0, (it.getLineTop(it.getLineForOffset(range.first)) - height / 3).coerceAtLeast(0)) }
        return findIndex + 1 to findRanges.size
    }

    fun clearSearch() {
        findSpan?.let(text::removeSpan)
        findSpan = null
        findRanges = emptyList()
        findIndex = -1
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density + .5f).toInt()
}
