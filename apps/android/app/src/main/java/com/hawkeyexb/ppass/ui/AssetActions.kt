package com.hawkeyexb.ppass.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import com.hawkeyexb.ppass.backup.SaveResult
import com.hawkeyexb.ppass.proto.AssetMeta
import java.io.File

fun shareDir(context: Context): File =
    File(context.cacheDir, "share").apply { mkdirs() }

fun sniffMimeFromHeader(file: File, isVideo: Boolean): String =
    com.hawkeyexb.ppass.backup.sniffMimeFromHeader(file, isVideo)

fun mimeExtension(mime: String): String =
    com.hawkeyexb.ppass.backup.mimeExtension(mime)

suspend fun saveToGallery(context: Context, file: File, asset: AssetMeta): SaveResult =
    com.hawkeyexb.ppass.backup.saveToGallery(context, file, asset)

const val DESKTOP_DOWNLOAD_URL = "https://p-pass.hawkeye-xb.com"

fun shareTextIntent(
    text: String,
    chooserTitle: String?,
    makeIntent: (String) -> Intent = { Intent(it) },
    makeChooser: (Intent, CharSequence?) -> Intent = { target, title -> Intent.createChooser(target, title) },
): Intent {
    val send = makeIntent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, text)
    }
    return makeChooser(send, chooserTitle)
}

suspend fun saveUriToGallery(context: Context, uri: Uri, asset: AssetMeta): SaveResult =
    com.hawkeyexb.ppass.backup.saveUriToGallery(context, uri, asset)

fun shareIntent(context: Context, file: File, asset: AssetMeta, chooserTitle: String?): Intent {
    val isVideo = asset.mediaType.startsWith("video")
    val mime = sniffMimeFromHeader(file, isVideo)
    val uri = FileProvider.getUriForFile(
        context, "${context.packageName}.fileprovider", file,
    )
    val send = Intent(Intent.ACTION_SEND).apply {
        type = mime
        putExtra(Intent.EXTRA_STREAM, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    return Intent.createChooser(send, chooserTitle)
}

fun shareUriIntent(context: Context, uri: Uri, asset: AssetMeta, chooserTitle: String?): Intent {
    val isVideo = asset.mediaType.startsWith("video")
    val mime = com.hawkeyexb.ppass.backup.sniffMimeFromUri(context, uri, isVideo)
    val send = Intent(Intent.ACTION_SEND).apply {
        type = mime
        putExtra(Intent.EXTRA_STREAM, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    return Intent.createChooser(send, chooserTitle)
}
