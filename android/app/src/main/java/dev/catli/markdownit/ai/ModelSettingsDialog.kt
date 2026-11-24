package dev.catli.markdownit.ai

import android.app.AlertDialog
import android.content.Context
import android.text.InputType
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.widget.doAfterTextChanged
import dev.catli.markdownit.R
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal class ModelSettingsDialog(
    private val context: Context,
    private val scope: CoroutineScope,
    private val store: ModelConnectionStore,
    private val client: ResponsesClient,
) {
    fun show(connection: ModelConnection?, changed: (ModelConnection?) -> Unit) {
        val fields = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(8), dp(24), dp(8))
        }
        fun field(id: Int, label: Int, value: String?, type: Int): EditText {
            fields.addView(TextView(context).apply {
                setText(label)
                setPadding(0, dp(12), 0, 0)
                labelFor = id
            })
            return EditText(context).apply {
                this.id = id
                inputType = type
                isSingleLine = true
                importantForAutofill = TextView.IMPORTANT_FOR_AUTOFILL_NO
                setText(value)
                fields.addView(this)
            }
        }
        val base = field(R.id.ai_settings_base, R.string.ai_base_url, connection?.baseURL,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI)
        val key = field(R.id.ai_settings_key, R.string.ai_api_key, connection?.apiKey,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        val model = field(R.id.ai_settings_model, R.string.ai_model, connection?.model,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS)
        fun value() = ModelConnection(base.text.toString(), model.text.toString().trim(), key.text.toString().trim())
        fun error(text: Int) { AlertDialog.Builder(context).setMessage(text).setPositiveButton(android.R.string.ok, null).show() }
        fun validateConnection(): Boolean {
            if (runCatching { ModelConnection.serviceURL(base.text.toString()) }.isFailure) {
                error(R.string.ai_valid_url); return false
            }
            if (key.text.toString().isBlank()) { error(R.string.ai_missing_key); return false }
            return true
        }
        val scroll = ScrollView(context).apply { addView(fields) }
        val dialog = AlertDialog.Builder(context).setTitle(R.string.ai_settings).setView(scroll)
            .setNegativeButton(android.R.string.cancel, null).setPositiveButton(android.R.string.ok, null)
            .create()
        fields.addView(Button(context).apply {
            setText(R.string.ai_models)
            isAllCaps = false
            setOnClickListener { if (validateConnection()) chooseModel(value()) { model.setText(it) } }
        })
        fields.addView(TextView(context).apply {
            setText(R.string.ai_storage)
            setTextColor(context.getColor(R.color.reader_secondary))
            setPadding(0, dp(8), 0, dp(8))
        })
        fields.addView(Button(context).apply {
            setText(R.string.ai_reset)
            isAllCaps = false
            setTextColor(context.getColor(android.R.color.holo_red_dark))
            setOnClickListener {
                AlertDialog.Builder(context).setMessage(R.string.ai_reset_confirm)
                    .setNegativeButton(android.R.string.cancel, null)
                    .setPositiveButton(R.string.ai_reset) { _, _ ->
                        scope.launch {
                            try {
                                withContext(Dispatchers.IO) { store.reset() }
                                base.text.clear()
                                key.text.clear()
                                model.text.clear()
                                changed(null)
                            } catch (error: CancellationException) {
                                throw error
                            } catch (_: Exception) { error(R.string.ai_connection_error) }
                        }
                    }.show()
            }
        })
        dialog.show()
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            if (!validateConnection()) return@setOnClickListener
            val next = value()
            if (next.model.isEmpty()) { error(R.string.ai_missing_model); return@setOnClickListener }
            val save = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
            save.isEnabled = false
            scope.launch {
                try {
                    withContext(Dispatchers.IO) { store.save(next) }
                    dialog.dismiss()
                    changed(next)
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    error(R.string.ai_connection_error)
                    save.isEnabled = true
                }
            }
        }
    }

    private fun chooseModel(connection: ModelConnection, pick: (String) -> Unit) {
        val filter = EditText(context).apply { setHint(R.string.ai_search_models); isSingleLine = true }
        val status = TextView(context).apply { setText(R.string.ai_loading_models); setPadding(dp(16), dp(8), dp(16), dp(8)) }
        val adapter = ArrayAdapter<String>(context, android.R.layout.simple_list_item_1)
        val list = ListView(context).apply { this.adapter = adapter }
        val panel = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(filter)
            addView(status)
            addView(list, LinearLayout.LayoutParams(-1, dp(300)))
        }
        val dialog = AlertDialog.Builder(context).setTitle(R.string.ai_models).setView(panel)
            .setNegativeButton(R.string.ai_custom_model, null).create()
        list.setOnItemClickListener { _, _, index, _ ->
            adapter.getItem(index)?.let(pick)
            dialog.dismiss()
        }
        var available = emptyList<String>()
        fun search() {
            val query = normalize(filter.text.toString())
            adapter.clear()
            adapter.addAll(available.filter { normalize(it).contains(query) })
        }
        filter.doAfterTextChanged { search() }
        var load: Job? = null
        dialog.setOnDismissListener { load?.cancel() }
        dialog.show()
        load = scope.launch {
            try {
                available = client.models(connection)
                status.visibility = TextView.GONE
                search()
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) { status.setText(R.string.ai_model_list_failed) }
        }
    }

    private fun normalize(text: String) = text.lowercase().filterNot { it.isWhitespace() || it == '-' }
    private fun dp(value: Int) = (value * context.resources.displayMetrics.density + .5f).toInt()
}
