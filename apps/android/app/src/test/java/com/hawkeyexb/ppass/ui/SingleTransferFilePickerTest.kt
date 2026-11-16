package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SingleTransferFilePickerTest {
    private val source = System.getenv("PPASS_PICKER_SOURCE")?.let(::File) ?: run {
        var dir: File? = File(System.getProperty("user.dir"))
        val rel = "app/src/main/java/com/hawkeyexb/ppass/ui/SingleTransferFilePicker.kt"
        var found: File? = null
        while (dir != null && found == null) {
            val direct = File(dir, rel)
            if (direct.isFile) {
                found = direct
                break
            }
            val nested = File(dir, "apps/android/$rel")
            if (nested.isFile) {
                found = nested
                break
            }
            dir = dir.parentFile
        }
        found ?: File(File(System.getProperty("user.dir")), rel)
    }

    @Test
    fun `file picker opens multiple photos and videos with persistable read access`() {
        assertTrue("缺少系统文件选择器适配：${source.path}", source.isFile)
        val text = source.readText()
        assertTrue(text.contains("Intent.ACTION_OPEN_DOCUMENT"))
        assertTrue(text.contains("Intent.CATEGORY_OPENABLE"))
        assertTrue(
            "EXTRA_ALLOW_MULTIPLE 必须显式为 true，不能只出现常量名",
            text.contains("putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)"),
        )
        assertTrue(text.contains("Intent.EXTRA_MIME_TYPES"))
        assertTrue(text.contains("\"image/*\""))
        assertTrue(text.contains("\"video/*\""))
        assertTrue(text.contains("Intent.FLAG_GRANT_READ_URI_PERMISSION"))
        assertTrue(text.contains("Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION"))
    }

    @Test
    fun `file picker has no app level count cap`() {
        assertTrue(source.isFile)
        val text = source.readText()
        assertFalse(text.contains("MAX_PICK"))
        assertFalse(Regex("\\btake\\s*\\(").containsMatchIn(text))
    }
}
