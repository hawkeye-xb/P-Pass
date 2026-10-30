// 电脑发来的缩略图：只认 JPEG，宽高都不超过 1024。判定是纯函数（BitmapFactory 在 JVM
// 单测里跑不了），文件头的读取由 decodeDesktopThumb 交给系统，真机日志补证。
package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DesktopThumbTest {

    private fun bytes(vararg b: Int) = ByteArray(b.size) { b[it].toByte() }

    @Test
    fun thumbnailRejectsNonJpegMagic() {
        assertFalse("PNG", hasJpegMagic(bytes(0x89, 0x50, 0x4E, 0x47)))
        assertFalse("HEIC ftyp", hasJpegMagic(bytes(0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70)))
        assertFalse("GIF", hasJpegMagic(bytes(0x47, 0x49, 0x46, 0x38)))
        assertFalse("too short", hasJpegMagic(bytes(0xFF, 0xD8)))
        assertFalse("empty", hasJpegMagic(ByteArray(0)))
        assertTrue("JPEG SOI + marker", hasJpegMagic(bytes(0xFF, 0xD8, 0xFF, 0xE0)))
        assertEquals(ThumbVerdict.NotJpeg, judgeDesktopThumb(false, null, 256, 256))
    }

    @Test
    fun thumbnailRejectsNonJpegMimeEvenWithJpegMagic() {
        assertEquals(ThumbVerdict.NotJpeg, judgeDesktopThumb(true, "image/png", 256, 256))
        assertEquals(ThumbVerdict.NotJpeg, judgeDesktopThumb(true, "image/heif", 256, 256))
    }

    @Test
    fun thumbnailRejectsEdgeOver1024() {
        assertEquals(ThumbVerdict.TooLarge(1025, 768), judgeDesktopThumb(true, "image/jpeg", 1025, 768))
        assertEquals(ThumbVerdict.TooLarge(768, 1025), judgeDesktopThumb(true, "image/jpeg", 768, 1025))
        assertEquals(ThumbVerdict.TooLarge(40000, 40000), judgeDesktopThumb(true, "image/jpeg", 40000, 40000))
    }

    @Test
    fun thumbnailAcceptsJpegUpTo1024() {
        assertEquals(ThumbVerdict.Ok, judgeDesktopThumb(true, "image/jpeg", 1024, 1024))
        assertEquals(ThumbVerdict.Ok, judgeDesktopThumb(true, "image/jpeg", 1024, 683))
        assertEquals(ThumbVerdict.Ok, judgeDesktopThumb(true, "image/jpeg", 256, 171))
    }

    @Test
    fun thumbnailRejectsUnreadableHeader() {
        // BitmapFactory 读不出文件头时 outWidth/outHeight = -1。
        assertEquals(ThumbVerdict.Unreadable, judgeDesktopThumb(true, null, -1, -1))
    }

    @Test
    fun desktopThumbLoaderGoesThroughPrecheck() {
        // 反证：把 TimelineLoader.thumb 改回直接 BitmapFactory.decodeByteArray，本测试红。
        val loader = File("src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt").readText()
        assertFalse("PhotosScreen 不应再直接解码", loader.contains("BitmapFactory"))
        assertTrue(loader.contains("decodeDesktopThumb(bytes, hash, size.px)"))
        val decoder = File("src/main/java/com/hawkeyexb/ppass/ui/DesktopThumb.kt").readText()
        val bounds = decoder.indexOf("inJustDecodeBounds = true")
        val full = decoder.lastIndexOf("BitmapFactory.decodeByteArray(bytes, 0, bytes.size)")
        assertTrue("先读文件头再解码", bounds in 0 until full)
    }
}
