package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SingleTransferFilePickerTest {
    // 源码守卫沿用 VideoScreenTest / ViewerChromeTest 的做法：JVM 单测跑不了
    // Compose 渲染，但选择器 intent 的形状与结果解析是这张卡的判据，扫描源码钉不变量，
    // 每条断言写明反证——换回错误形状，它立刻红。

    /** 从 [start] 锚点到 [end] 锚点之间的一段；锚点缺失直接红，避免扫描落空后假绿。 */
    private fun slice(text: String, start: String, end: String): String {
        val from = text.indexOf(start)
        assertTrue("源码里找不到锚点：$start", from >= 0)
        val to = text.indexOf(end, from + start.length)
        assertTrue("源码里找不到结束锚点：$end", to > from)
        return text.substring(from, to)
    }

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

    @Test
    fun `saf result parsing takes every clip item and falls back to the single uri`() {
        assertTrue(source.isFile)
        val parse = slice(source.readText(), "fun urisFromResult(", "\n    }")
        // SAF 多选结果装在 clipData（每项一个 URI），单选落在 data——两条路都要有。
        assertTrue("多选必须逐项读 clipData", parse.contains("clip.itemCount") && parse.contains("getItemAt"))
        // 反证：上界少读一项（itemCount - 1）或闭区间越界都必须红——遍历钉成 0 until clip.itemCount。
        assertTrue(
            "clipData 必须从 0 逐项遍历到 itemCount，少读最后一项要红",
            Regex("for \\(index in 0 until clip\\.itemCount\\)").containsMatchIn(parse),
        )
        assertTrue("clip 为空时必须回退到单选 data", parse.contains("ifEmpty"))
        // 反证：取消/空结果返回空表 → 上层不登记任务。
        assertTrue("空结果必须返回空表", source.readText().contains("return emptyList()"))
    }
}
