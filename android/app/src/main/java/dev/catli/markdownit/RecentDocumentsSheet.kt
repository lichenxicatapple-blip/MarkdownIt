package dev.catli.markdownit

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.net.Uri
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.core.view.updateLayoutParams
import androidx.core.widget.NestedScrollView
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.bottomsheet.BottomSheetDragHandleView

internal class RecentDocumentsSheet(
    context: Context,
    documents: List<ReadingState.Recent>,
    parentName: (Uri) -> String?,
    private val open: (ReadingState.Recent, (Boolean) -> Unit) -> Unit,
) : BottomSheetDialog(context, R.style.Theme_MarkdownIt_RecentDocuments) {
    private val rows = mutableListOf<View>()
    private val close = ImageButton(this.context).apply {
        id = R.id.close_recent_documents
        setImageResource(R.drawable.ic_close)
        imageTintList = ColorStateList.valueOf(context.getColor(R.color.reader_text))
        contentDescription = context.getString(R.string.close_recent_documents)
        setBackgroundResource(themedDrawable(android.R.attr.selectableItemBackgroundBorderless))
        setOnClickListener { dismiss() }
    }

    init {
        val content = LinearLayout(this.context).apply {
            id = R.id.recent_documents_sheet
            orientation = LinearLayout.VERTICAL
        }
        content.addView(BottomSheetDragHandleView(this.context).apply {
            setPadding(0, 0, 0, 0)
        }, LinearLayout.LayoutParams(dp(48), dp(24)).apply { gravity = Gravity.CENTER_HORIZONTAL })
        content.addView(header(), LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        if (documents.isEmpty()) {
            content.addView(label(16f, R.color.reader_secondary).apply {
                setText(R.string.no_recent_documents)
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(dp(24), dp(38), dp(24), 0)
            }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        } else {
            val list = LinearLayout(this.context).apply { orientation = LinearLayout.VERTICAL }
            documents.forEachIndexed { index, document ->
                list.addView(row(document, parentName(document.uri)))
                if (index < documents.lastIndex) {
                    list.addView(View(this.context).apply {
                        setBackgroundColor(context.getColor(R.color.reader_pressed))
                    }, LinearLayout.LayoutParams(MATCH_PARENT, 1).apply {
                        marginStart = dp(24)
                        marginEnd = dp(24)
                    })
                }
            }
            content.addView(NestedScrollView(this.context).apply {
                addView(list, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
            }, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
        }
        setContentView(content, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        requireViewById<View>(com.google.android.material.R.id.design_bottom_sheet).updateLayoutParams {
            height = MATCH_PARENT
        }
        behavior.isFitToContents = false
        behavior.skipCollapsed = true
        behavior.maxWidth = dp(640)
        behavior.state = BottomSheetBehavior.STATE_HALF_EXPANDED
    }

    private fun header() = FrameLayout(context).apply {
        minimumHeight = dp(52)
        addView(label(17f, R.color.reader_text).apply {
            setText(R.string.recent_documents)
            gravity = Gravity.CENTER
            setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL))
            setPaddingRelative(dp(64), dp(10), dp(64), dp(10))
            isAccessibilityHeading = true
        }, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.CENTER))
        addView(close, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.CENTER_VERTICAL or Gravity.START).apply {
            marginStart = dp(12)
        })
    }

    private fun row(document: ReadingState.Recent, parent: String?) = LinearLayout(context).apply {
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(64)
        setPaddingRelative(dp(24), dp(10), dp(24), dp(10))
        setBackgroundResource(themedDrawable(android.R.attr.selectableItemBackground))
        isFocusable = true
        isScreenReaderFocusable = true
        val labels = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(label(16f, R.color.reader_text).apply {
                text = document.name
                maxLines = 2
                ellipsize = TextUtils.TruncateAt.END
            })
            if (parent != null) addView(label(13f, R.color.reader_secondary).apply {
                text = parent
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.MIDDLE
            }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = dp(3) })
        }
        addView(labels, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        val progress = ProgressBar(context, null, android.R.attr.progressBarStyleSmall).apply {
            contentDescription = context.getString(R.string.reading)
            visibility = View.GONE
        }
        addView(progress, LinearLayout.LayoutParams(dp(20), dp(20)).apply { marginStart = dp(12) })
        rows.add(this)
        setOnClickListener {
            setOpening(true, progress)
            open(document) { opened ->
                if (opened) dismiss()
                else setOpening(false, progress)
            }
        }
    }

    private fun setOpening(opening: Boolean, progress: View) {
        rows.forEach { it.isEnabled = !opening }
        close.isEnabled = !opening
        behavior.isDraggable = !opening
        setCancelable(!opening)
        progress.visibility = if (opening) View.VISIBLE else View.GONE
    }

    private fun label(size: Float, color: Int) = TextView(context).apply {
        textSize = size
        setTextColor(context.getColor(color))
    }

    private fun themedDrawable(attribute: Int): Int = TypedValue().also {
        context.theme.resolveAttribute(attribute, it, true)
    }.resourceId

    private fun dp(value: Int): Int = (value * context.resources.displayMetrics.density + .5f).toInt()
}
