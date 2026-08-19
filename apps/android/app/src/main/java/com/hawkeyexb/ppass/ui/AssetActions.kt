// RET-01: 单张照片取回 = 使用动作——查看页两个动作：
//  「保存到相册」（写 MediaStore，覆盖删后要用/要家人的照片）与
//  「用其他应用打开」（临时文件 + FileProvider + 系统面板，覆盖拿去修图）。
//  MOB-04 红线：临时文件即用即清（每次使用前清旧残留 + 进程重启由系统
//  清 cacheDir），绝不建长期原图缓存；「保存到相册」是用户显式动作，
//  落的是 MediaStore 不是我们的缓存。
package com.hawkeyexb.ppass.ui

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.hawkeyexb.ppass.proto.AssetMeta
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** 下载原图的临时分享目录（cacheDir/share/）——cacheDir 语义 = 系统
 *  可随时清，MOB-04 红线「进程重启清理」由系统保证；使用前再清旧残留。 */
fun shareDir(context: Context): File =
    File(context.cacheDir, "share").apply { mkdirs() }

/** 下载原图到临时文件，返回文件（调用方负责在面板关闭/失败后删除）。 */
suspend fun downloadToShare(
    loader: TimelineLoader,
    hash: String,
    shareDir: File,
): File {
    shareDir.listFiles()?.forEach { it.delete() } // MOB-04: 即用即清旧残留
    val tmp = File(shareDir, "asset-$hash.take(16)")
    loader.download(hash, tmp) { _, _ -> }
    return tmp
}

/**
 * 文件头魔数嗅探 MIME（纯函数，JVM 可测——本地单测跑不了 Android
 * framework，不用 BitmapFactory）。asset.mediaType 只有 photo/video 粗类，
 * 保存到相册需要真实 MIME；嗅探失败时按粗类兜底。
 */
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
    // ISO BMFF 家族（ftyp box 偏移 4..8）：heic/heix/mif1 = 图片，其余 = 视频。
    if (n >= 12 && head[4] == 0x66.toByte() && head[5] == 0x74.toByte() &&
        head[6] == 0x79.toByte() && head[7] == 0x70.toByte()
    ) {
        val brand = String(head, 8, 4)
        if (brand in listOf("heic", "heix", "hevc", "mif1", "msf1")) return "image/heic"
        return "video/mp4"
    }
    return if (isVideo) "video/mp4" else "image/jpeg"
}

/** MIME → 文件扩展名（保存到相册的 DISPLAY_NAME 用）。 */
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

/**
 * 保存原图到系统相册（写 MediaStore）。
 * API 29+：RELATIVE_PATH + IS_PENDING（免权限，Scoped Storage 语义）。
 * API 26-28：DATA 路径 + WRITE_EXTERNAL_STORAGE 权限，写后 MediaScanner
 * 广播。返回保存后的 Uri；失败抛异常（UI 层转人话）。
 */
/** MOB-24: 保存结果——[alreadyExisted] 为真表示这张之前就存过，本次没有
 *  再写一份。UI 据此说人话（"已经在相册里了"而不是"已保存到相册"）。 */
data class SaveResult(val uri: Uri, val alreadyExisted: Boolean)

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
            // MOB-24: 先查存没存过。文件名带内容 hash 前 12 位，**同名即同图**，
            // 所以查 DISPLAY_NAME 就够。不去重的后果是真机实测出来的：
            //   P-Pass-c53d45e823e7.jpg
            //   P-Pass-c53d45e823e7 (1).jpg   ← 同一张，系统自动加了后缀
            // 用户点了两次（第一次没给足反馈，他以为没生效），相册里就多了
            // 一份一模一样的照片。
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
            // API 26-28: DATA 路径 + 写权限（Scoped Storage 之前的世界）。
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
            // MOB-24: 同 API29+ 分支——文件名带内容 hash，存在即同图，别再写一份。
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

/**
 * 「分享」Intent：FileProvider URI + ACTION_SEND + EXTRA_STREAM + 系统分享面板。
 * 与 [openWithAppIntent] 的语义区别：
 *  - ACTION_SEND = 把文件作为**内容/附件**发给目标 app（接收方新建消息/上传附件，
 *    面板=微信/QQ/邮件/云盘/Nearby）；
 *  - ACTION_VIEW = 让目标 app 以**打开**模式处理文件（修图/播放/查看，
 *    面板=打开方式选择器）。
 * 底层共用：FileProvider URI + FLAG_GRANT_READ_URI_PERMISSION + 临时文件即用即清。
 * 调用方用 startActivity 前先 try-catch ActivityNotFoundException；面板关闭后删除 [file]。
 */
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

/**
 * 「用其他应用打开」的 Intent：FileProvider URI + ACTION_VIEW。
 * 调用方用 startActivity 前先 try-catch ActivityNotFoundException →
 * 人话「没有能打开它的应用」；面板关闭后删除 [file]。
 */
fun openWithAppIntent(context: Context, file: File, asset: AssetMeta): Intent {
    val isVideo = asset.mediaType.startsWith("video")
    val mime = sniffMimeFromHeader(file, isVideo)
    val uri = FileProvider.getUriForFile(
        context, "${context.packageName}.fileprovider", file,
    )
    return Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(uri, mime)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
}
