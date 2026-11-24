package dev.catli.markdownit.ai

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.net.URL
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class ModelConnection(val baseURL: String, val model: String, val apiKey: String) {
    val service: URI = serviceURL(baseURL)
    fun endpoint(resource: String): URL = URI.create("${service}/$resource").toURL()

    companion object {
        fun serviceURL(value: String): URI {
            val parsed = URI.create(value.trim())
            require(parsed.scheme.equals("https", ignoreCase = true) && parsed.host != null)
            require(parsed.userInfo == null && parsed.rawQuery == null && parsed.rawFragment == null)
            var path = parsed.rawPath.trimEnd('/')
            val suffix = listOf("/responses", "/models", "/chat/completions").firstOrNull(path::endsWith)
            if (suffix != null) path = path.removeSuffix(suffix)
            val port = if (parsed.port == -1 || parsed.port == 443) "" else ":${parsed.port}"
            return URI.create("https://${parsed.host.lowercase()}$port$path")
        }
    }
}

/** Only the Keystore can decrypt the complete, device-local connection record. */
internal class ModelConnectionStore(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "ai-connection"))

    fun load(): ModelConnection? {
        if (!file.baseFile.exists()) return null
        val bytes = file.readFully()
        require(bytes.size > IV_SIZE)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, requireNotNull(keyStore().getKey(ALIAS, null)),
            GCMParameterSpec(128, bytes.copyOf(IV_SIZE)))
        val json = JSONObject(cipher.doFinal(bytes, IV_SIZE, bytes.size - IV_SIZE).decodeToString())
        return ModelConnection(json.getString("baseURL"), json.getString("model"), json.getString("apiKey"))
    }

    fun save(connection: ModelConnection) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        val key = keyStore().getKey(ALIAS, null) as? SecretKey ?: newKey()
        cipher.init(Cipher.ENCRYPT_MODE, key)
        require(cipher.iv.size == IV_SIZE)
        val json = JSONObject().put("baseURL", connection.service.toString())
            .put("model", connection.model).put("apiKey", connection.apiKey)
        val stream = file.startWrite()
        try {
            stream.write(cipher.iv)
            stream.write(cipher.doFinal(json.toString().encodeToByteArray()))
            file.finishWrite(stream)
        } catch (error: Exception) {
            file.failWrite(stream)
            throw error
        }
    }

    fun reset() {
        file.delete()
        keyStore().deleteEntry(ALIAS)
    }

    private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun newKey(): SecretKey = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
        init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUnlockedDeviceRequired(true)
            .build())
    }.generateKey()

    private companion object {
        const val ALIAS = "markdownit.model-connection"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_SIZE = 12
    }
}
