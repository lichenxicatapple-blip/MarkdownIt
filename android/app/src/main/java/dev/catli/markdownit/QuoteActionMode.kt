package dev.catli.markdownit

import android.graphics.Rect
import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.view.View

internal class QuoteActionMode(
    private val title: String,
    private val original: ActionMode.Callback? = null,
    private val quote: (ActionMode) -> Unit,
) : ActionMode.Callback2() {
    override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
        if (original?.onCreateActionMode(mode, menu) == false) return false
        addQuote(menu)
        return true
    }

    override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean {
        val changed = original?.onPrepareActionMode(mode, menu) ?: false
        return addQuote(menu) || changed
    }

    override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
        if (item.itemId != R.id.quote_selection) return original?.onActionItemClicked(mode, item) ?: false
        quote(mode)
        return true
    }

    override fun onDestroyActionMode(mode: ActionMode) { original?.onDestroyActionMode(mode) }

    override fun onGetContentRect(mode: ActionMode, view: View, outRect: Rect) {
        if (original is ActionMode.Callback2) original.onGetContentRect(mode, view, outRect)
        else super.onGetContentRect(mode, view, outRect)
    }

    private fun addQuote(menu: Menu): Boolean {
        if (menu.findItem(R.id.quote_selection) != null) return false
        menu.add(Menu.NONE, R.id.quote_selection, Menu.NONE, title).setShowAsAction(MenuItem.SHOW_AS_ACTION_NEVER)
        return true
    }
}
