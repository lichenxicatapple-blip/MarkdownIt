package dev.catli.markdownit

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.Charset
import java.security.MessageDigest

internal data class MarkdownFile(
    val uri: Uri, val name: String, val text: String, val format: MarkdownFormat, val revision: String,
)

internal data class MarkdownFormat(val charset: Charset, val newline: String, val bom: ByteArray) {
    fun encode(text: String): ByteArray {
        val encoded = charset.newEncoder().encode(CharBuffer.wrap(text.replace("\n", newline)))
        val data = ByteArray(encoded.remaining())
        encoded.get(data)
        return bom + data
    }
}

internal fun digest(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

/** Android document IDs are opaque except for the system local-storage provider. */
internal class DocumentFiles(private val context: Context) {
    private val resolver = context.contentResolver

    sealed interface Resource {
        data class File(val uri: Uri) : Resource
        data class NeedsFolder(val directory: String?, val downloadsRoot: Boolean) : Resource
        data object Missing : Resource
    }

    private data class Location(val volume: String, val components: List<String>) {
        fun pathsWithin(folder: Location): List<String>? {
            if (volume != folder.volume || components.take(folder.components.size) != folder.components) return null
            return components.drop(folder.components.size)
        }
    }

    fun readMarkdown(uri: Uri): MarkdownFile {
        require(uri.scheme == ContentResolver.SCHEME_CONTENT)
        val name = requireNotNull(displayName(uri))
        require(isMarkdown(name) || resolver.getType(uri) in markdownTypes)
        val bytes = requireNotNull(resolver.openInputStream(uri)).use { it.readBytes() }
        val (text, format) = decode(bytes)
        return MarkdownFile(uri, name, text, format, digest(bytes))
    }

    fun write(document: MarkdownFile, revision: String, text: String): String {
        val data = document.format.encode(text)
        val current = readMarkdown(document.uri)
        if (current.text == text) return current.revision
        if (current.revision != revision) throw DocumentChanged()
        requireNotNull(resolver.openOutputStream(document.uri, "rwt")).use { it.write(data) }
        return digest(data)
    }

    class DocumentChanged : Exception()

    fun persist(uri: Uri, writable: Boolean = false): Boolean {
        val read = Intent.FLAG_GRANT_READ_URI_PERMISSION
        if (writable && retain(uri, read or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)) return true
        return retain(uri, read)
    }

    private fun retain(uri: Uri, flags: Int): Boolean = try {
        resolver.takePersistableUriPermission(uri, flags)
        true
    } catch (_: SecurityException) {
        false
    }

    fun isDurable(uri: Uri): Boolean = readGrants().any { grant ->
        grant == uri || (isTree(grant) && location(uri)?.pathsWithin(location(grant, tree = true) ?: return@any false) != null)
    } || (isTree(uri) && readGrants().any { grant ->
        isTree(grant) && grant.authority == uri.authority && treeID(grant) == treeID(uri)
    })

    fun resolve(document: MarkdownFile, relative: String, verifiedFolder: Uri?): Resource {
        val path = relativePath(relative) ?: return Resource.Missing
        val origin = location(document.uri)
        if (origin == null) {
            val components = normalize(emptyList(), path) ?: return Resource.Missing
            val folder = verifiedFolder?.takeIf { it in readGrants() }
                ?: return Resource.NeedsFolder(directory = null, downloadsRoot = false)
            return find(folder, components)?.let(Resource::File) ?: Resource.Missing
        }
        val components = normalize(origin.components.dropLast(1), path) ?: return Resource.Missing
        val target = origin.copy(components = components)
        val grant = readGrants().asSequence().filter(::isTree).mapNotNull { folder ->
            val root = location(folder, tree = true) ?: return@mapNotNull null
            val remaining = target.pathsWithin(root) ?: return@mapNotNull null
            folder to remaining
        }.minByOrNull { it.second.size }
        if (grant != null) return find(grant.first, grant.second)?.let(Resource::File) ?: Resource.Missing

        val directory = components.dropLast(1)
        return Resource.NeedsFolder(directory.joinToString("/"), directory == listOf("Download"))
    }

    /** Check that the chosen tree actually authorizes the next unresolved reference. */
    fun acceptFolder(document: MarkdownFile, directory: Uri, relative: String): Boolean {
        if (!isTree(directory)) return false
        val path = relativePath(relative) ?: return false
        val origin = location(document.uri)
        val matches = if (origin != null) {
            val root = location(directory, tree = true) ?: return false
            val target = normalize(origin.components.dropLast(1), path) ?: return false
            val remaining = origin.copy(components = target).pathsWithin(root) ?: return false
            remaining.isNotEmpty()
        } else {
            val candidate = find(directory, listOf(document.name)) ?: return false
            runCatching { readMarkdown(candidate).text == document.text }.getOrDefault(false)
        }
        return matches && persist(directory)
    }

    fun hasOpaqueLocation(document: MarkdownFile): Boolean = location(document.uri) == null

    fun parentName(uri: Uri): String? {
        location(uri)?.let { return it.components.dropLast(1).lastOrNull() }
        if (uri.authority != "com.android.providers.media.documents") return null

        return runCatching {
            val media = MediaStore.getMediaUri(context, uri) ?: return null
            resolver.query(media, arrayOf(MediaStore.MediaColumns.RELATIVE_PATH), null, null, null)?.use {
                if (!it.moveToFirst()) return null
                it.getString(0)?.trimEnd('/')?.substringAfterLast('/')?.takeIf(String::isNotEmpty)
            }
        }.getOrNull()
    }

    fun mimeType(uri: Uri, name: String): String? {
        val extension = name.substringAfterLast('.', "").lowercase()
        return resolver.getType(uri)?.takeUnless { it == "application/octet-stream" }
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
    }

    private fun displayName(uri: Uri): String? = resolver.query(
        uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null,
    )?.use { if (it.moveToFirst()) it.getString(0) else null }

    private fun readGrants(): List<Uri> = resolver.persistedUriPermissions.filter { it.isReadPermission }.map { it.uri }

    private fun find(tree: Uri, components: List<String>): Uri? {
        if (components.isEmpty()) return null
        var parent = treeID(tree)
        val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        for (name in components) {
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent)
            parent = resolver.query(children, columns, null, null, null)?.use { entries ->
                var found: String? = null
                while (entries.moveToNext()) {
                    if (entries.getString(1) == name) {
                        found = entries.getString(0)
                        break
                    }
                }
                found
            } ?: return null
        }
        return DocumentsContract.buildDocumentUriUsingTree(tree, parent)
    }

    private fun location(uri: Uri, tree: Boolean = false): Location? {
        if (uri.authority != "com.android.externalstorage.documents") return null
        val id = runCatching { if (tree) treeID(uri) else DocumentsContract.getDocumentId(uri) }.getOrNull() ?: return null
        val volume = id.substringBefore(':', "")
        if (volume.isEmpty()) return null
        return Location(volume, id.substringAfter(':').split('/').filter(String::isNotEmpty))
    }

    private fun isTree(uri: Uri): Boolean = DocumentsContract.isTreeUri(uri) && uri.pathSegments.size == 2
    private fun treeID(uri: Uri): String = DocumentsContract.getTreeDocumentId(uri)

    companion object {
        val markdownTypes = setOf("text/markdown", "text/x-markdown")
        private val extensions = setOf("md", "markdown", "mdown", "mkd", "mkdn")

        fun isMarkdown(name: String): Boolean = name.substringAfterLast('.', "").lowercase() in extensions

        private fun relativePath(value: String): List<String>? {
            val uri = Uri.parse(value)
            val path = uri.path ?: return null
            if (uri.scheme != null || uri.authority != null || path.startsWith('/') || '\\' in path || '\u0000' in path) return null
            return path.takeIf(String::isNotEmpty)?.split('/')
        }

        private fun normalize(parent: List<String>, path: List<String>): List<String>? {
            val result = parent.toMutableList()
            for (part in path) {
                when (part) {
                    "", "." -> Unit
                    ".." -> if (result.isEmpty()) return null else result.removeAt(result.lastIndex)
                    else -> result.add(part)
                }
            }
            return result.takeIf(List<String>::isNotEmpty)
        }

        private fun decode(bytes: ByteArray): Pair<String, MarkdownFormat> {
            val utf8Bom = byteArrayOf(0xef.toByte(), 0xbb.toByte(), 0xbf.toByte())
            val beBom = byteArrayOf(0xfe.toByte(), 0xff.toByte())
            val leBom = byteArrayOf(0xff.toByte(), 0xfe.toByte())
            fun startsWith(prefix: ByteArray) = bytes.size >= prefix.size && prefix.indices.all { bytes[it] == prefix[it] }
            val (bom, preferred) = when {
                startsWith(utf8Bom) -> utf8Bom to Charsets.UTF_8
                startsWith(beBom) -> beBom to Charsets.UTF_16BE
                startsWith(leBom) -> leBom to Charsets.UTF_16LE
                else -> ByteArray(0) to Charsets.UTF_8
            }
            fun read(charset: Charset) = charset.newDecoder().decode(ByteBuffer.wrap(bytes, bom.size, bytes.size - bom.size)).toString()
            val (text, charset) = runCatching { read(preferred) to preferred }.getOrElse {
                if (bom.isNotEmpty()) throw it
                val fallback = Charset.forName("GB18030")
                read(fallback) to fallback
            }
            val newline = Regex("\r\n|\r|\n").find(text)?.value ?: "\n"
            return text.replace("\r\n", "\n").replace('\r', '\n') to MarkdownFormat(charset, newline, bom)
        }
    }
}
