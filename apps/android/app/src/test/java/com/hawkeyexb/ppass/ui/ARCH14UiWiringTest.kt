// ARCH-14 (#418) 生产链路门禁（源文本）：证明 FlowUiProjection 的纯函数真的接进了 holder → MainActivity →
// HomeScreen / 前台服务通知，取消轮与补传提示的 UI 真的删干净了，失败通知真的没有调用点。
// 纯函数本身的行为判据在 backup/flow/ARCH14UiProjectionTest.kt。
package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ARCH14UiWiringTest {
    private val main = File("src/main/java/com/hawkeyexb/ppass")
    private fun read(path: String) = File(main, path).readText()

    private val home get() = read("ui/HomeScreen.kt")
    private val activity get() = read("MainActivity.kt")
    private val holder get() = read("backup/BackupUiStateHolder.kt")

    // 反证：MainActivity 不把 holder.cancelConfirmCount 交给 HomeScreen → 确认框永远不出现，红。
    @Test
    fun the_cancel_remaining_row_and_dialog_are_wired_end_to_end() {
        val call = activity.substringAfter("HomeScreen(").substringBefore("onDisconnect")
        listOf(
            "cancelRemainingCount = holder.cancelRemainingCount.value",
            "onRequestCancelRemaining = { holder.requestCancelRemaining() }",
            "cancelConfirmCount = holder.cancelConfirmCount.value",
            "onConfirmCancelRemaining = { holder.confirmCancelRemaining() }",
            "onDismissCancelRemaining = { holder.dismissCancelRemaining() }",
            "skippedCount = holder.skippedCount.value",
            "onRestoreSkipped = { holder.restoreSkipped() }",
            "transferProgress = holder.transferProgress.value",
            "waitReasonRes = holder.waitReasonNotice.value",
            "desktopLowSpace = holder.desktopLowSpace.value",
        ).forEach { assertTrue("MainActivity → HomeScreen 缺少 `$it`", call.contains(it)) }

        assertTrue(holder.contains("cancelRemainingRowCount(p, pairingLostState.value.value)"))
        assertTrue(holder.contains("_skippedCount.value = skippedRowCount(p)"))
        assertTrue(holder.contains("fun restoreSkipped() = command { gateway?.restoreSkipped() }"))
        assertTrue(holder.contains("_triplet.value = flowTripletOf(p, lastBucketIds)"))
        assertTrue(holder.contains("_waitReasonNotice.value = waitReasonTextRes(p)"))
        assertTrue(holder.contains("_desktopLowSpace.value = desktopLowSpaceWarning(p)"))
        assertTrue(holder.contains("transferPermilleOf(p.current)"))
        assertTrue("点那一行要先向引擎要快照再弹框", holder.contains("fun requestCancelRemaining()") && holder.contains("g.remainingSnapshot()"))
    }

    // #413 §5：取消边界 = 弹窗显示那一刻。确认时交回引擎的必须是弹框时拿到的**同一个**快照，不许确认时重算。
    // 反证：confirmCancelRemaining 里改成 `gateway?.cancelRemaining(g.remainingSnapshot())` → 红。
    @Test
    fun the_cancel_confirmation_hands_back_the_snapshot_taken_when_the_dialog_opened() {
        val request = holder.substringAfter("fun requestCancelRemaining()").substringBefore("fun restoreSkipped()")
        assertTrue(request.contains("cancelSnapshot = snapshot.takeIf { it.count > 0 }"))
        assertTrue(request.contains("_cancelConfirmCount.value = cancelSnapshot?.count"))
        val confirm = holder.substringAfter("fun confirmCancelRemaining()").substringBefore("private suspend fun repairEpochIfNeeded")
        assertTrue(confirm.contains("val snapshot = cancelSnapshot ?: return"))
        assertTrue(confirm.contains("gateway?.cancelRemaining(snapshot)"))
        assertFalse("确认时不许重算", confirm.contains("remainingSnapshot()"))
    }

    // #413：UI 只经 EngineGateway 碰引擎——holder 里不再直接调旧引擎的暂停 / 继续 / 取消 / 计数入口。
    // 反证：backupNow 改回 `pauseFlow(context)` → 红。
    @Test
    fun the_holder_reaches_the_engine_only_through_the_gateway() {
        val holderClass = holder.substringBefore("// ================================================================ W1 接线点：EngineGateway")
        listOf("pauseFlow(", "continueFlow(", "cancelRemainingFlow(", "countRemainingFlow(", "restoreSkippedFlow(", "flowProjection(")
            .forEach { assertFalse("holder 还在直接调 $it", holderClass.contains(it)) }
        assertTrue(holderClass.contains("FlowCommand.Pause -> gateway?.pause()"))
        assertTrue(holderClass.contains("FlowCommand.Continue -> gateway?.resume()"))
    }

    // 确认框：写明 N；关闭按钮不许也叫「取消」（要确认的动作本身就叫取消，MOB-89 同形的误触）。
    // 反证：dismissButton 用 R.string.cancel → 红。
    @Test
    fun the_confirm_dialog_names_N_and_its_dismiss_button_is_not_called_cancel() {
        val dialog = home.substringAfter("if (cancelConfirmCount != null) {").substringBefore("\n    Column(")
        assertTrue(dialog.contains("R.plurals.cancel_remaining_confirm_title, cancelConfirmCount, cancelConfirmCount"))
        assertTrue(dialog.contains("R.plurals.cancel_remaining_label, cancelConfirmCount, cancelConfirmCount"))
        val dismiss = dialog.substringAfter("dismissButton")
        assertTrue(dismiss.contains("R.string.back"))
        assertFalse(dismiss.contains("R.string.cancel)"))
    }

    // 取消轮的 UI 删掉：英雄区的「取消当前轮」、「当前轮已取消」状态、取消轮的恢复管线。
    // 取消只剩一个入口：设置卡「取消剩余 N 张」；恢复只剩一个入口：设置卡「已跳过的照片 · 点击恢复」。
    // 反证：把英雄区的「取消当前轮」加回来 → 第一条断言红。
    @Test
    fun the_cancellation_round_ui_is_gone_and_there_is_exactly_one_cancel_entry() {
        listOf("backup_cancel_current_round", "backup_round_cancelled", "CancelledCurrentRound", "restoreCancelledRounds", "cancelledRoundNotice")
            .forEach { gone ->
                assertFalse("HomeScreen 还在引用 $gone", home.contains(gone))
                assertFalse("MainActivity 还在引用 $gone", activity.contains(gone))
                assertFalse("holder 还在引用 $gone", holder.contains(gone))
            }
        assertEquals(1, Regex("onClick = if \\(commandPending\\) null else onRequestCancelRemaining").findAll(home).count())
        val skippedRow = home.substringAfter("if (skippedCount != null) {").substringBefore("\n                }\n")
        assertTrue(skippedRow.contains("R.string.cancelled_round_cell_label"))
        assertTrue(skippedRow.contains("R.string.cancelled_round_cell_value, skippedCount.toInt()"))
        assertTrue(skippedRow.contains("onRestoreSkipped"))
    }

    // 「电脑上少了照片、正在重新传回」提示：新模型自动补传、不打扰（#413），接不上 → 删。
    @Test
    fun the_reupload_notice_is_gone() {
        val notices = read("ui/HomeNotices.kt")
        assertFalse(notices.contains("reupload_notice"))
        assertFalse(notices.contains("reuploadCount"))
        assertFalse(holder.contains("reuploadNoticeCount"))
        assertFalse(activity.contains("reuploadNoticeCount"))
    }

    // 英雄区进度条是这一张的字节进度；前台服务通知用同一个函数（#418 决策 3）。
    // 反证：通知里自己再算一遍 permille → 这条红（两处漂移的起点）。
    @Test
    fun the_hero_bar_and_the_transfer_notification_share_one_progress_function() {
        val fgs = read("backup/flow/FlowTransferForegroundService.kt")
        assertTrue(fgs.contains("val permille = transferPermilleOf(current)"))
        assertFalse(fgs.contains("* 1000) / current.totalBytes"))
        assertTrue(home.contains("val progress = transferProgress"))
        assertFalse(home.contains("roundProgress"))
    }

    // #418 决策 4：失败通知的代码保留，但 main 里没有任何调用点（失败要先分类；兜底会自动重发）。
    // 反证：在 FlowEngine.fail() 里加一行 `notifier.postFailure(n)` → 这条红。
    @Test
    fun the_failure_notification_is_kept_but_never_posted() {
        val callers = main.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filterNot { it.name == "FailureNotifier.kt" || it.name == "SystemFailureNotifier.kt" }
            .filter { f -> f.readText().let { it.contains("postFailure(") || it.contains("SystemFailureNotifier(") } }
            .map { it.name }
            .toList()
        assertEquals("失败通知不该有调用点", emptyList<String>(), callers)
        assertTrue(File(main, "backup/SystemFailureNotifier.kt").isFile)
        val fail = read("backup/flow/FlowEngine.kt").substringAfter("private fun fail(").substringBefore("store.transition(")
        assertTrue("调用点必须写明为什么不发", fail.contains("故意不在这里调用") && fail.contains("分类") && fail.contains("兜底"))
    }
}
