package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.picked.PickedBatchSummary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * #1789（父卡 #1784）：设置固定分组、两个单次入口只发起选择、单次状态只在英雄区出现。
 *
 * 两件能测的事（HomeScreen 是 Compose，本仓没有 Robolectric，同 MOB94 的分工）：
 * ① 单次传输状态句的判据本体（[SingleTransferStatus.heroLine]，纯函数）；
 * ② 源文本门禁——固定分组的组序、入口行不带进度/结果、英雄区接线、选择时清理已结束记录。
 * ②是源文本，只能证明写法，证明不了效果；真机表现随版本验收台账验。
 */
class SingleTransferStatusTest {

    private fun batch(
        total: Int,
        delivered: Int = 0,
        alreadyThere: Int = 0,
        failed: Int = 0,
        open: Int = total - delivered - alreadyThere - failed,
    ) = PickedBatchSummary(batchId = 1, total = total, open = open, delivered = delivered, alreadyThere = alreadyThere, failed = failed)

    // ── ① 判据本体 ────────────────────────────────────────────────

    @Test
    fun no_batch_means_no_hero_line() {
        assertNull(SingleTransferStatus.heroLine(null))
    }

    @Test
    fun open_items_show_progress_counting_the_one_in_flight() {
        // #1272 同口径：正在传的那一张算进度（settled + 1）。
        assertEquals(SingleTransferStatus.Line.Progress(done = 3, total = 5), SingleTransferStatus.heroLine(batch(total = 5, delivered = 2)))
        assertEquals(SingleTransferStatus.Line.Progress(done = 1, total = 5), SingleTransferStatus.heroLine(batch(total = 5)))
    }

    @Test
    fun settled_batch_shows_the_result_sentence() {
        assertEquals(
            SingleTransferStatus.Line.Result(delivered = 3, failed = 0),
            SingleTransferStatus.heroLine(batch(total = 3, delivered = 3, open = 0)),
        )
        // 电脑上已有的也算送达（2026-11-04 口径）。
        assertEquals(
            SingleTransferStatus.Line.Result(delivered = 3, failed = 0),
            SingleTransferStatus.heroLine(batch(total = 3, delivered = 1, alreadyThere = 2, open = 0)),
        )
        assertEquals(
            SingleTransferStatus.Line.Result(delivered = 2, failed = 1),
            SingleTransferStatus.heroLine(batch(total = 3, delivered = 2, failed = 1, open = 0)),
        )
        // 全部失败：没有送达半句，只有失败。
        assertEquals(
            SingleTransferStatus.Line.Result(delivered = null, failed = 2),
            SingleTransferStatus.heroLine(batch(total = 2, failed = 2, open = 0)),
        )
    }

    @Test
    fun interrupted_process_does_not_count_as_failure() {
        // #1789 验收 4：进程被杀时没传完的行留在 pending/transferring——它们仍是 open，
        // 英雄区出的是进度句，绝不是把没传完的张数记进 failed。
        val killed = batch(total = 12, delivered = 9, open = 3)
        assertEquals(SingleTransferStatus.Line.Progress(done = 10, total = 12), SingleTransferStatus.heroLine(killed))
        assertEquals(0, killed.failed)
    }

    // ── ② 源文本门禁 ──────────────────────────────────────────────

    private fun homeScreen() = File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()
    private fun mainActivity() = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()

    private fun group(source: String, marker: String): String? =
        Regex("(?s)// ── #1789 固定分组 ${marker}.*?(?=// ── #1789 固定分组|// ── #1789 固定分组结束)").find(source)?.value

    /** #1784：设置按「自动备份 / 单次传输 / 传输条件与通知 / 更多」固定分组，组序固定。 */
    @Test
    fun settings_groups_are_fixed_and_in_order() {
        val source = homeScreen()
        val one = source.indexOf("// ── #1789 固定分组 1/4")
        val two = source.indexOf("// ── #1789 固定分组 2/4")
        val three = source.indexOf("// ── #1789 固定分组 3/4")
        val four = source.indexOf("// ── #1789 固定分组 4/4")
        assertTrue("四个固定分组都要在", one >= 0 && two >= 0 && three >= 0 && four >= 0)
        assertTrue("组序：自动备份 → 单次传输 → 传输条件与通知 → 更多", one < two && two < three && three < four)
    }

    /** #1784：单次传输下固定为「从相册选择」「从文件选择」，两行只发起选择，不显示进度、结果或最近一批。
     *  评审 Cy：逐行核对标签与动作的配对——把两行的 onClick 互换，「组里存在两个标签 + 两个动作」的写法仍会通过。 */
    @Test
    fun the_two_single_transfer_entries_only_initiate_selection() {
        val group = group(homeScreen(), "2/4")
        assertTrue(group != null)
        group.let { g ->
            // 按 CellRow 切开：每行入口的标签与 onClick 必须一一配对。
            val rows = g!!.split("CellRow(").drop(1)
            assertTrue("单次传输组固定两行入口", rows.size == 2)
            assertTrue(
                "「从相册选择」必须配发起相册选择（onPickPhotos）",
                rows.any { it.contains("R.string.pick_from_photos_label") && it.contains("onClick = onPickPhotos") },
            )
            assertTrue(
                "「从文件选择」必须配发起文件选择（onPickFiles）",
                rows.any { it.contains("R.string.pick_from_files_label") && it.contains("onClick = onPickFiles") },
            )
            assertFalse("入口行不显示进度 / 结果 / 最近一批", g.contains("pickedBatch"))
            assertFalse("入口行不带状态句", g.contains("picked_progress"))
        }
    }

    /** #1784：设置页不再有「挑几张传」的进度/结果行——单次状态只在英雄区出现。 */
    @Test
    fun no_pick_progress_line_is_left_in_the_settings_card() {
        val source = homeScreen()
        assertFalse("旧「挑几张传」行值函数必须退场", source.contains("pickedBatchLine"))
        assertFalse("设置卡里不再消费最近一批", Regex("(?s)// ── #1789 固定分组 1/4.*?// ── #1789 固定分组结束")
            .find(source)!!.value.contains("pickedBatch"))
    }

    /** #1784：英雄区读取手选状态（进度 / 结果），自动与单次状态统一由英雄区展示。 */
    @Test
    fun hero_shows_the_single_transfer_status_line() {
        val source = homeScreen()
        assertTrue("英雄区消费单次传输投影", source.contains("SingleTransferStatus.heroLine(pickedBatch)"))
    }

    /** #1784：已结束记录随下一次选择清理（评审 B1：各自回调内断言顺序，不靠全文包含；
     *  评审 AP：清理在**登记成功之后**——登记失败时不得动原状态，所以顺序是 enqueue → clearSettled）。 */
    @Test
    fun picking_again_clears_the_settled_records_first() {
        val main = mainActivity()
        val photoPick = main.substringAfter("pickPhotosLauncher", "").substringBefore("decisionPickLauncher")
        assertTrue("相册入口登记后清理已结束记录", photoPick.contains("clearSettled()"))
        val clearInPhoto = photoPick.indexOf("store.clearSettled()")
        val enqueueInPhoto = photoPick.indexOf("PickedUploads.enqueue(context, uris)")
        assertTrue("相册入口必须先登记新一批（成功后）、再清理已结算行", clearInPhoto > enqueueInPhoto && enqueueInPhoto >= 0)
        // 文件入口的回调块截到轮询 LaunchedEffect 为止，不把后面无关回调里的 clearSettled 也算进来。
        val filePick = main.substringAfter("filePickLauncher", "").substringBefore("androidx.compose.runtime.LaunchedEffect")
        assertTrue(
            "文件入口解析复用 SingleTransferFilePicker（评审：SAF 多选/单选边界只写一处）",
            filePick.contains("SingleTransferFilePicker.urisFromResult"),
        )
        assertTrue("文件入口登记后清理已结束记录", filePick.contains("clearSettled()"))
        val clearInFile = filePick.indexOf("store.clearSettled()")
        val enqueueInFile = filePick.indexOf("PickedUploads.enqueue(context, uris)")
        assertTrue("文件入口必须先登记新一批（成功后）、再清理已结算行", clearInFile > enqueueInFile && enqueueInFile >= 0)
        // 入口存在：HomeScreen 的「从文件选择」行确实从 SingleTransferFilePicker 拿 intent。
        assertTrue("文件入口存在", main.contains("filePickLauncher.launch(com.hawkeyexb.ppass.ui.SingleTransferFilePicker.intent())"))
    }

    /** #1784：条件行只在原组内显隐、尊重系统减少动态效果——状态变化直接呈现，不加过渡动画。 */
    @Test
    fun settings_and_hero_render_state_directly_without_transitions() {
        val source = homeScreen()
        for (api in listOf("AnimatedVisibility", "animateContentSize", "animateFloatAsState", "animateColorAsState", "animateDpAsState", "Crossfade", "AnimatedContent")) {
            assertFalse("英雄区与设置组直接呈现状态，不使用 $api（尊重系统减少动态效果）", source.contains(api))
        }
    }
}
