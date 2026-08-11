// RET-01: 文件头魔数嗅探 MIME 的纯函数单测——本地 JVM 跑不了 Android
// framework，魔数识别必须不依赖 BitmapFactory（JVM 可测是设计约束）。
package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AssetActionsTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun fileWith(vararg bytes: Int): File {
        val f = tmp.newFile()
        f.writeBytes(ByteArray(bytes.size) { bytes[it].toByte() })
        return f
    }

    @Test
    fun jpegMagic() {
        val f = fileWith(0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46)
        assertEquals("image/jpeg", sniffMimeFromHeader(f, isVideo = false))
    }

    @Test
    fun pngMagic() {
        val f = fileWith(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00)
        assertEquals("image/png", sniffMimeFromHeader(f, isVideo = false))
    }

    @Test
    fun webpMagic() {
        val f = fileWith(
            0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00,
            0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38,
        )
        assertEquals("image/webp", sniffMimeFromHeader(f, isVideo = false))
    }

    @Test
    fun heicMagic() {
        val f = fileWith(
            0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
            0x68, 0x65, 0x69, 0x63, 0x00, 0x00, 0x00, 0x00,
        )
        assertEquals("image/heic", sniffMimeFromHeader(f, isVideo = false))
    }

    @Test
    fun mp4Magic() {
        val f = fileWith(
            0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
            0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x00, 0x01,
        )
        assertEquals("video/mp4", sniffMimeFromHeader(f, isVideo = true))
    }

    @Test
    fun unknownFallsBackToCoarseType() {
        val f = fileWith(0xDE, 0xAD, 0xBE, 0xEF)
        assertEquals("image/jpeg", sniffMimeFromHeader(f, isVideo = false))
        assertEquals("video/mp4", sniffMimeFromHeader(f, isVideo = true))
    }

    @Test
    fun emptyFileFallsBackToCoarseType() {
        val f = tmp.newFile()
        assertEquals("image/jpeg", sniffMimeFromHeader(f, isVideo = false))
    }

    @Test
    fun extensionMapping() {
        assertEquals("jpg", mimeExtension("image/jpeg"))
        assertEquals("png", mimeExtension("image/png"))
        assertEquals("webp", mimeExtension("image/webp"))
        assertEquals("heic", mimeExtension("image/heic"))
        assertEquals("mp4", mimeExtension("video/mp4"))
        assertEquals("mov", mimeExtension("video/quicktime"))
        assertEquals("bin", mimeExtension("application/octet-stream"))
    }
}
