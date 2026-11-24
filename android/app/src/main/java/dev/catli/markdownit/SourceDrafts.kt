package dev.catli.markdownit

import android.content.Context
import android.net.Uri
import android.util.AtomicFile
import java.io.File
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

internal data class SourceChange(val start: Int, val removed: String, val inserted: String) {
    fun json() = JSONObject().put("start", start).put("removed", removed).put("inserted", inserted)
}

internal data class SourceSnapshot(
    val text: String,
    val source: Boolean,
    val selectionStart: Int,
    val selectionEnd: Int,
    val anchor: JSONObject?,
    val undo: List<SourceChange>,
    val redo: List<SourceChange>,
)

internal class SourceDrafts(context: Context, private val files: DocumentFiles) {
    class Session(val file: MarkdownFile, val writable: Boolean, val restored: SourceSnapshot?, internal var revision: String) {
        private val nextSave = AtomicLong()
        internal var written = 0L
        internal var confirmedText = file.text
        fun reserveSave(): Long = nextSave.incrementAndGet()
    }

    private val directory = File(context.noBackupFilesDir, "source-drafts")

    suspend fun start(file: MarkdownFile, writable: Boolean): Session = withContext(Dispatchers.IO) {
        mutex.withLock {
            val record = runCatching { JSONObject(draft(file.uri).readFully().decodeToString()) }.getOrNull()
            val stored = record?.let { runCatching { decode(it) }.getOrNull() }
            val restored = if (stored != null && stored.text != file.text && !record.optBoolean("dirty", true)) {
                stored.copy(text = file.text, anchor = null, undo = emptyList(), redo = emptyList())
            } else stored
            val revision = if (restored != null && restored.text != file.text) {
                record?.optString("revision", file.revision) ?: file.revision
            } else file.revision
            Session(file, writable, restored, revision)
        }
    }

    /** Journal the working text before writing through the document provider. */
    suspend fun save(session: Session, snapshot: SourceSnapshot, sequence: Long) = withContext(Dispatchers.IO + NonCancellable) {
        mutex.withLock {
            if (session.written > sequence) return@withLock
            checkpoint(session, snapshot)
            session.written = sequence
            if (snapshot.text != session.confirmedText) {
                if (!session.writable) throw SecurityException("Document is read-only")
                session.revision = files.write(session.file, session.revision, snapshot.text)
                session.confirmedText = snapshot.text
                checkpoint(session, snapshot)
            }
        }
    }

    suspend fun discard(session: Session) = withContext(Dispatchers.IO + NonCancellable) {
        mutex.withLock { draft(session.file.uri).delete() }
    }

    private fun checkpoint(session: Session, snapshot: SourceSnapshot) {
        val value = JSONObject().put("revision", session.revision).put("text", snapshot.text)
            .put("dirty", snapshot.text != session.confirmedText)
            .put("source", snapshot.source).put("selectionStart", snapshot.selectionStart)
            .put("selectionEnd", snapshot.selectionEnd).put("anchor", snapshot.anchor)
            .put("undo", JSONArray(snapshot.undo.map(SourceChange::json)))
            .put("redo", JSONArray(snapshot.redo.map(SourceChange::json)))
        val file = draft(session.file.uri)
        val stream = file.startWrite()
        try {
            stream.write(value.toString().encodeToByteArray())
            file.finishWrite(stream)
        } catch (error: Exception) {
            file.failWrite(stream)
            throw error
        }
    }

    private fun draft(uri: Uri) = AtomicFile(File(directory, "${digest(uri.toString().encodeToByteArray())}.json"))

    private fun decode(value: JSONObject) = SourceSnapshot(
        value.getString("text"), value.optBoolean("source"), value.optInt("selectionStart"), value.optInt("selectionEnd"),
        value.optJSONObject("anchor"), changes(value.optJSONArray("undo")), changes(value.optJSONArray("redo")),
    )

    private fun changes(array: JSONArray?): List<SourceChange> {
        if (array == null) return emptyList()
        return (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            SourceChange(item.getInt("start"), item.getString("removed"), item.getString("inserted"))
        }
    }

    companion object { private val mutex = Mutex() }
}
