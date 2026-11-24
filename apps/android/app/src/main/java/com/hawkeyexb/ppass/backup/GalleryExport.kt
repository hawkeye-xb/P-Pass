package com.hawkeyexb.ppass.backup

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import com.hawkeyexb.ppass.proto.AssetMeta
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class SaveResult(val uri: Uri, val alreadyExisted: Boolean)

fun sniffMimeFromHeader(file: File, isVideo: Boolean): String {
    val head = ByteArray(12)
    val n = runCatching {
        file.inputStream().use { it.read(head) }
    }.getOrDefault(0)
    if (n >= 3 && head[0] == 0xFF.toByte() && head[1] == 0xD8.toByte() &&
        head[2] == 0xFF.toByte()
    ) return "image/jpeg"
    if (n >= 8 && head[0] == 0x89.toByte() && head[1] == 0x50.toByte() &&
        head[2] == 0x4E.toByte() && head[3] == 0x47.toByte()
    ) return "image/png"
    if (n >= 12 && head[0] == 0x52.toByte() && head[1] == 0x49.toByte() &&
        head[2] == 0x46.toByte() && head[3] == 0x46.toByte() &&
        head[8] == 0x57.toByte() && head[9] == 0x45.toByte() &&
        head[10] == 0x42.toByte() && head[11] == 0x50.toByte()
    ) return "image/webp"
    if (n >= 12 && head[4] == 0x66.toByte() && head[5] == 0x74.toByte() &&
        head[6] == 0x79.toByte() && head[7] == 0x70.toByte()
    ) {
        val brand = String(head, 8, 4)
        if (brand in listOf("heic", "heix", "hevc", "mif1", "msf1")) return "image/heic"
        return "video/mp4"
    }
    return if (isVideo) "video/mp4" else "image/jpeg"
}

fun mimeExtension(mime: String): String = when (mime) {
    "image/jpeg" -> "jpg"
    "image/png" -> "png"
    "image/webp" -> "webp"
    "image/heic", "image/heif" -> "heic"
    "video/mp4" -> "mp4"
    "video/webm" -> "webm"
    "video/quicktime" -> "mov"
    else -> "bin"
}

suspend fun saveToGallery(context: Context, file: File, asset: AssetMeta): SaveResult {
    val isVideo = asset.mediaType.startsWith("video")
    val mime = sniffMimeFromHeader(file, isVideo)
    val displayName = "P-Pass-${asset.hash.take(12)}.${mimeExtension(mime)}"
    return withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        if (Build.VERSION.SDK_INT >= 29) {
            val collection = if (isVideo) {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            } else {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
            resolver.query(
                collection,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
                arrayOf(displayName),
                null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    return@withContext SaveResult(
                        ContentUris.withAppendedId(collection, c.getLong(0)),
                        alreadyExisted = true,
                    )
                }
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    Environment.DIRECTORY_PICTURES + "/P-Pass",
                )
                if (asset.takenAt > 0) {
                    put(MediaStore.Images.Media.DATE_TAKEN, asset.takenAt * 1000)
                }
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(collection, values)
                ?: error("MediaStore insert returned null")
            try {
                resolver.openOutputStream(uri)?.use { out ->
                    file.inputStream().use { it.copyTo(out) }
                } ?: error("openOutputStream returned null")
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                SaveResult(uri, alreadyExisted = false)
            } catch (t: Throwable) {
                runCatching { resolver.delete(uri, null, null) }
                throw t
            }
        } else {
            val granted = ContextCompat.checkSelfPermission(
                context, Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
            check(granted) { "no WRITE_EXTERNAL_STORAGE permission" }
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                "P-Pass",
            )
            if (!dir.exists() && !dir.mkdirs()) error("cannot create $dir")
            val target = File(dir, displayName)
            if (target.isFile) {
                return@withContext SaveResult(Uri.fromFile(target), alreadyExisted = true)
            }
            file.inputStream().use { i ->
                target.outputStream().use { o -> i.copyTo(o) }
            }
            MediaScannerConnection.scanFile(
                context,
                arrayOf(target.absolutePath),
                arrayOf(mime),
                null,
            )
            SaveResult(Uri.fromFile(target), alreadyExisted = false)
        }
    }
}
