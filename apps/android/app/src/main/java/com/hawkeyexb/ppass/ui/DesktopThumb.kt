// 电脑发来的缩略图：只认 JPEG，宽高都不超过 1024（电脑生成的最大档，见
// crates/media-codec/src/thumb.rs THUMB_SIZES）。先看魔数，再用
// inJustDecodeBounds 只读文件头里的格式和宽高，合格了才真正解码；不合格的
// 不解码、写一行日志，界面显示占位。手机本机相册走系统 loadThumbnail，不经过这里。
package com.hawkeyexb.ppass.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.hawkeyexb.ppass.log.PLog

internal const val DESKTOP_THUMB_MAX_EDGE = 1024

internal sealed interface ThumbVerdict {
    data object Ok : ThumbVerdict
    data object NotJpeg : ThumbVerdict
    data object Unreadable : ThumbVerdict
    data class TooLarge(val width: Int, val height: Int) : ThumbVerdict
}

/** JPEG 文件以 SOI（FF D8）开头，紧跟一个标记段（FF xx）。 */
internal fun hasJpegMagic(bytes: ByteArray): Boolean =
    bytes.size >= 3 &&
        bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte() && bytes[2] == 0xFF.toByte()

/** 纯判定：魔数 + 文件头里读出的格式与宽高（JVM 可测）。 */
internal fun judgeDesktopThumb(magicOk: Boolean, mimeType: String?, width: Int, height: Int): ThumbVerdict = when {
    !magicOk || (mimeType != null && mimeType != "image/jpeg") -> ThumbVerdict.NotJpeg
    width <= 0 || height <= 0 -> ThumbVerdict.Unreadable
    width > DESKTOP_THUMB_MAX_EDGE || height > DESKTOP_THUMB_MAX_EDGE -> ThumbVerdict.TooLarge(width, height)
    else -> ThumbVerdict.Ok
}

/** 预检合格才解码；不合格返回 null 并记日志（不静默）。 */
internal fun decodeDesktopThumb(bytes: ByteArray, hash: String, px: Int): Bitmap? {
    val magicOk = hasJpegMagic(bytes)
    val verdict = if (!magicOk) {
        ThumbVerdict.NotJpeg // 魔数不对，连文件头都不交给解码器
    } else {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        judgeDesktopThumb(true, bounds.outMimeType, bounds.outWidth, bounds.outHeight)
    }
    if (verdict != ThumbVerdict.Ok) {
        PLog.w("PPassThumb", "thumb ${hash.take(16)} size=$px rejected: $verdict (${bytes.size} bytes)")
        return null
    }
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
}
