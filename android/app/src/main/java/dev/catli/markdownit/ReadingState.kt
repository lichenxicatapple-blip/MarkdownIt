package dev.catli.markdownit

import android.content.SharedPreferences
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

internal class ReadingState(private val preferences: SharedPreferences) {
    data class Recent(val uri: Uri, val name: String)

    val active: Uri? get() = preferences.getString("active", null)?.let(Uri::parse)

    fun opened(document: MarkdownFile, durable: Boolean) {
        val editor = preferences.edit()
        if (durable) {
            val previous = recent()
            val documents = (listOf(Recent(document.uri, document.name)) + previous.filter { it.uri != document.uri })
                .take(10)
            val retained = documents.mapTo(mutableSetOf(), Recent::uri)
            previous.filter { it.uri !in retained }.forEach { editor.remove(key("position", it.uri)) }
            val json = JSONArray()
            documents.forEach { json.put(JSONObject().put("uri", it.uri.toString()).put("name", it.name)) }
            editor.putString("recent", json.toString())
            editor.putString("active", document.uri.toString())
        } else {
            editor.remove("active")
        }
        editor.apply()
    }

    fun closed() { preferences.edit().remove("active").apply() }

    fun recent(): List<Recent> = runCatching {
        val json = JSONArray(preferences.getString("recent", "[]"))
        (0 until json.length()).map { index ->
            val entry = json.getJSONObject(index)
            Recent(Uri.parse(entry.getString("uri")), entry.getString("name"))
        }
    }.getOrDefault(emptyList())

    fun folder(uri: Uri): Uri? = preferences.getString(key("folder", uri), null)?.let(Uri::parse)

    fun setFolder(uri: Uri, folder: Uri) {
        preferences.edit().putString(key("folder", uri), folder.toString()).apply()
    }

    fun position(uri: Uri): JSONObject? = preferences.getString(key("position", uri), null)?.let { saved ->
        runCatching { JSONObject(saved) }.getOrNull()?.takeIf(::validPosition)
    }

    fun savePosition(uri: Uri, position: JSONObject) {
        if (validPosition(position)) preferences.edit().putString(key("position", uri), position.toString()).apply()
    }

    private fun key(prefix: String, uri: Uri): String {
        val hash = MessageDigest.getInstance("SHA-256").digest(uri.toString().encodeToByteArray())
        return "$prefix-${hash.joinToString("") { "%02x".format(it) }}"
    }

    companion object {
        fun validPosition(position: JSONObject): Boolean {
            val anchor = position.optJSONObject("anchor") ?: return false
            if (position.optString("mode") != "preview") return false
            val line = (anchor.opt("line") as? Number)?.toDouble() ?: return false
            val offset = (anchor.opt("y") as? Number)?.toDouble() ?: return false
            return line.isFinite() && line >= 0 && offset.isFinite()
        }
    }
}
