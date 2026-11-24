package dev.catli.markdownit.ai

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowManager
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.TextView
import androidx.core.view.updateLayoutParams
import androidx.core.widget.doAfterTextChanged
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.bottomsheet.BottomSheetDragHandleView
import dev.catli.markdownit.R
import kotlin.math.roundToInt

internal class ConversationSheet(
    context: Context,
    content: View,
    onDraft: (String, Int) -> Unit,
    private val onSend: (String, Int) -> Unit,
    private val onStop: () -> Unit,
    onSettings: () -> Unit,
    onClear: () -> Unit,
) : BottomSheetDialog(context, R.style.Theme_MarkdownIt_Conversation) {
    private var applying = false
    private var epoch = 0
    private var generating = false
    private var hasHistory = false
    private val input = EditText(this.context).apply {
        id = R.id.ai_input
        contentDescription = context.getString(R.string.ai_input)
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        imeOptions = EditorInfo.IME_FLAG_NO_ENTER_ACTION or EditorInfo.IME_FLAG_NO_EXTRACT_UI
        maxLines = 5
        minHeight = dp(48)
        setTextColor(context.getColor(R.color.reader_text))
        setPadding(dp(14), dp(11), dp(14), dp(11))
        background = GradientDrawable().apply {
            setColor(context.getColor(R.color.reader_surface))
            cornerRadius = dp(22).toFloat()
        }
        doAfterTextChanged { if (!applying) onDraft(it.toString(), epoch) }
        setOnKeyListener { _, keyCode, event ->
            val enter = keyCode == KeyEvent.KEYCODE_ENTER && event.flags and KeyEvent.FLAG_SOFT_KEYBOARD == 0 &&
                !event.isShiftPressed && BaseInputConnection.getComposingSpanStart(text) < 0
            if (enter && event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0 && !generating && text.isNotBlank()) {
                submit()
            }
            enter
        }
    }
    private val send = action(R.drawable.ic_send, R.string.ai_send) {
        if (generating) onStop() else submit()
    }.apply {
        id = R.id.ai_send
        imageTintList = ColorStateList.valueOf(context.getColor(R.color.reader_on_accent))
        background = GradientDrawable().apply {
            setColor(context.getColor(R.color.reader_accent))
            cornerRadius = dp(22).toFloat()
        }
        isEnabled = false
        alpha = .45f
    }

    init {
        val surface = LinearLayout(this.context).apply {
            orientation = LinearLayout.VERTICAL
            isFocusableInTouchMode = true
        }
        surface.addView(BottomSheetDragHandleView(this.context).apply { setPadding(0, 0, 0, 0) },
            LinearLayout.LayoutParams(dp(48), dp(24)).apply { gravity = Gravity.CENTER_HORIZONTAL })
        val header = FrameLayout(this.context).apply {
            addView(TextView(this.context).apply {
                setText(R.string.ai_title)
                textSize = 17f
                gravity = Gravity.CENTER
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                setTextColor(context.getColor(R.color.reader_text))
                isAccessibilityHeading = true
            }, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
            val options = action(R.drawable.ic_more, R.string.ai_options) { view ->
                PopupMenu(this.context, view).apply {
                    menu.add(0, R.string.ai_settings, 0, R.string.ai_settings)
                    menu.add(0, R.string.ai_clear, 1, R.string.ai_clear).isEnabled = hasHistory
                    setOnMenuItemClickListener {
                        if (it.itemId == R.string.ai_settings) onSettings() else onClear()
                        true
                    }
                    show()
                }
            }
            addView(options, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.START or Gravity.CENTER_VERTICAL).apply {
                marginStart = dp(8)
            })
            addView(action(R.drawable.ic_down, R.string.ai_close) { dismiss() }.apply { id = R.id.ai_close },
                FrameLayout.LayoutParams(dp(48), dp(48), Gravity.END or Gravity.CENTER_VERTICAL).apply {
                    marginEnd = dp(8)
                })
        }
        surface.addView(header, LinearLayout.LayoutParams(MATCH_PARENT, dp(48)))
        surface.addView(content, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
        val composer = LinearLayout(this.context).apply {
            gravity = Gravity.BOTTOM
            setPadding(dp(12), dp(6), dp(12), dp(8))
            addView(input, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
            addView(send, LinearLayout.LayoutParams(dp(48), dp(48)).apply { marginStart = dp(8) })
        }
        surface.addView(composer, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        setContentView(surface, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        requireViewById<View>(com.google.android.material.R.id.design_bottom_sheet).updateLayoutParams { height = MATCH_PARENT }
        @Suppress("DEPRECATION")
        window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        val height = context.getSystemService(WindowManager::class.java).currentWindowMetrics.bounds.height()
        behavior.maxHeight = context.resources.getFraction(R.fraction.ai_sheet_height, height, height).roundToInt()
        behavior.skipCollapsed = true
        behavior.maxWidth = dp(640)
        behavior.state = BottomSheetBehavior.STATE_EXPANDED
        surface.requestFocus()
    }

    fun setDraft(text: String, revision: Int) {
        applying = true
        epoch = revision
        try {
            if (input.text.toString() != text) {
                input.setText(text)
                input.setSelection(input.length())
            }
        } finally { applying = false }
    }

    fun updateControls(messageCount: Boolean, running: Boolean, canSend: Boolean) {
        hasHistory = messageCount
        generating = running
        send.setImageResource(if (running) R.drawable.ic_stop else R.drawable.ic_send)
        send.contentDescription = context.getString(if (running) R.string.ai_stop else R.string.ai_send)
        send.isEnabled = running || canSend
        send.alpha = if (send.isEnabled) 1f else .45f
    }

    fun hideKeyboard() {
        context.getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(input.windowToken, 0)
        input.clearFocus()
    }

    fun submit() { if (!generating && send.isEnabled) onSend(input.text.toString(), epoch) }

    private fun action(icon: Int, label: Int, invoke: (View) -> Unit) = ImageButton(this.context).apply {
        setImageResource(icon)
        contentDescription = context.getString(label)
        imageTintList = ColorStateList.valueOf(context.getColor(R.color.reader_text))
        val value = TypedValue()
        context.theme.resolveAttribute(android.R.attr.selectableItemBackgroundBorderless, value, true)
        setBackgroundResource(value.resourceId)
        setOnClickListener(invoke)
    }

    private fun dp(value: Int) = (value * context.resources.displayMetrics.density + .5f).toInt()
}
