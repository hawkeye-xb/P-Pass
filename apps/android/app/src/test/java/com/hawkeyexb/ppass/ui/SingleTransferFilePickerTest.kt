package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SingleTransferFilePickerTest {
    // 源码守卫沿用 VideoScreenTest / ViewerChromeTest 的做法：JVM 单测跑不了
    // Compose 渲染，但「用哪个组件、走哪条链路」是这张卡的判据，扫描源码钉不变量，
    // 每条断言写明反证——换回错误组件状态，它立刻红。

    /** 从 [start] 锚点到 [end] 锚点之间的一段；锚点缺失直接红，避免扫描落空后假绿。 */
    private fun slice(text: String, start: String, end: String): String {
        val from = text.indexOf(start)
        assertTrue("源码里找不到锚点：$start", from >= 0)
        val to = text.indexOf(end, from + start.length)
        assertTrue("源码里找不到结束锚点：$end", to > from)
        return text.substring(from, to)
    }

    /** 手写的「一个 Text 挂 clickable」——换回它就该红。 */
    private fun hasHandRolledClickable(block: String): Boolean =
        Regex("\\.clickable\\s*\\(").containsMatchIn(block)

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

    @Test
    fun `pick entry is a Material 3 Button on brand colors, not a hand-rolled clickable`() {
        assertTrue(source.isFile)
        // 切到列首收尾花括号（函数自己的结束），避免锚点停在 launcher lambda 的缩进 } 上。
        val entry = slice(source.readText(), "fun SingleTransferPickEntry(", "\n}")
        // #1798 定案：入口必须是 Material3 Button（触控区、涟漪、role=Button 由组件给出）。
        assertTrue("入口必须落在 Material3 Button 上", entry.contains("Button("))
        // 反证：把 enabled 写死 false（默认入口永远点不动）或 onClick 改空都必须红。
        assertTrue("Button 必须透传 enabled 参数，不得写死", entry.contains("enabled = enabled"))
        assertTrue(
            "点击必须唤起系统文件选择器",
            entry.contains("launcher.launch(SingleTransferFilePicker.intent())"),
        )
        assertTrue(
            "品牌配色走 ButtonDefaults，不在外面再刷一层背景",
            entry.contains("ButtonDefaults.buttonColors(containerColor = PPColor.Ink, contentColor = PPColor.Paper)"),
        )
        assertTrue("入口文案必须来自 stringResource", entry.contains("stringResource(R.string.pick_files_label)"))
        // 反证：把 Button 改回「Text(...).clickable(...)」，上面三条立刻红；这一条挡两种写法并存。
        assertFalse(
            "入口里还留着自绘热区：${entry.lines().filter { it.contains("clickable") }}",
            hasHandRolledClickable(entry),
        )
    }

    @Test
    fun `picked files land in the shared queue and wake the transfer loop`() {
        assertTrue(source.isFile)
        val text = source.readText()
        // #1798：沿用现有 Picked 队列与去重——URI 原样进 PickedUploads.enqueue，不多一条旁路。
        assertTrue("选中的 URI 必须走 PickedUploads.enqueue 登记进既有队列", text.contains("PickedUploads.enqueue("))
        // 结果闸钉成确切形状（比较方向反了、空结果闸被拆掉都要红）。
        val callback = slice(text, "val picked =", "PickedUploads.enqueue(context, picked)")
        assertTrue(
            "结果回调必须以 == RESULT_OK 为闸，取消（!=）不登记",
            callback.contains("result.resultCode == Activity.RESULT_OK"),
        )
        assertTrue(
            "空结果必须直接返回，不进队列",
            callback.contains("if (picked.isEmpty()) return@rememberLauncherForActivityResult"),
        )
        // 反证：只有 count > 0（真的登记进了）才唤醒传输循环；方向写反（count < 0）必须红。
        val wake = slice(text, "val count = withContext(Dispatchers.IO)", "requestFlowWake(context, TriggerReason.PICKED_ADDED)")
        assertTrue("登记成功（count > 0）才唤醒传输循环", wake.contains("if (count > 0) {"))
    }
}
