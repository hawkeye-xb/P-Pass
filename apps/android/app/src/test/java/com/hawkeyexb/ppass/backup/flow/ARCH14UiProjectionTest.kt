// ARCH-14 (#418) E2：逐张循环的 UI 投影。接替 #417 删掉的 UI09 / UI16HeroScope / MOB51 / MOB67 / MOB100 /
// UI10 / UI19PauseReasonRender——判据改成新模型的事实源（order 表 + 循环运行态 + FlowControl + 引擎现算的剩余张数），
// 端到端走真实 FlowEngine（Rig），不手搓账本。反证写在每个测试上方，输出见 #418 报告。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.ui.BackupUiState
import com.hawkeyexb.ppass.ui.HeroRender
import com.hawkeyexb.ppass.ui.allSafeTextAllowed
import com.hawkeyexb.ppass.ui.heroNumberIsSafe
import com.hawkeyexb.ppass.ui.heroRenderOf
import com.hawkeyexb.ppass.ui.visibleWaitReasonRes
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ARCH14UiProjectionTest {
    private val albums = setOf(7L)

    private fun Rig.inScopeTotal(): Long = media.photos.count { media.inScope(it.bucketId) }.toLong()

    private suspend fun Rig.projection(withRemaining: Boolean = true): FlowProjection =
        FlowProjection.of(
            store, engine.display.value, control, albums, inScopeTotal(),
            remaining = if (withRemaining) engine.countRemaining().toLong() else null,
        )

    private fun TestScope.backedUp(count: Long): Rig = Rig(this).also { rig ->
        (1L..count).forEach { rig.photo(it, generation = it) }
        rig.trigger()
        assertTrue((1L..count).all { rig.state(it) == OrderState.CONFIRMED })
    }

    // ---------------------------------------------------------------- 英雄区 m / n / K

    // 协调方追加的必修项：用户删掉已备份的照片（最常见的用法），英雄区必须是「全部完成」，不是 H-C「正在核对」。
    // 分子只数「CONFIRMED、原图还在、在当前范围内」，与分母（MediaStore 实时计数）同口径。
    // 反证：FlowProjection.of 的 confirmed 改回 scoped[CONFIRMED]（不排除 source_missing）→ m 原始值 10 > n 7，
    // heroRenderOf 走 Unreconciled，红。
    @Test
    fun `deleting backed-up photos from the phone still shows all done, not the unreconciled card`() = runTest {
        val rig = backedUp(10)
        listOf(2L, 5L, 8L).forEach(rig.media::remove)
        rig.trigger(TriggerReason.APP_FOREGROUND) // 慢路径第二遍：Gone → source_missing，行仍是 CONFIRMED
        assertEquals(OrderState.CONFIRMED, rig.state(2))
        assertTrue(rig.store.currentForMedia(2)!!.sourceMissing)

        val p = rig.projection()
        val t = flowTripletOf(p, albums)!!
        assertEquals(7L, t.confirmedRaw)
        assertEquals(7L, t.n)
        assertEquals(0L, t.k)
        assertEquals(HeroRender.Triplet, heroRenderOf(MediaAccess.FULL, t))
        assertTrue(heroNumberIsSafe(MediaAccess.FULL, t, pairingLost = false))
        assertTrue(backupUiStateOf(p) is BackupUiState.AllSafe)
        val missing = flowMissingSourceNotice(p)?.count ?: 0
        assertEquals("已备份的照片被删不是「无法恢复、不会再传」——那条横幅不该出现", 0, missing)
        assertTrue(allSafeTextAllowed(MediaAccess.FULL, t, pairingLost = false, missingSourceCount = missing))
        rig.close()
    }

    // 已确认的照片被挪进没选的相册：慢路径更新 bucket_id，m 随之减一，不会比 n 多。
    // 反证：去掉 DiffPlanner 范围外分支里的 MappingOnly → 行的 bucket_id 停在 7，m = 3 > n = 2，Unreconciled，红。
    @Test
    fun `moving a backed-up photo into an unselected album keeps m equal to n`() = runTest {
        val rig = backedUp(3)
        rig.media.put(rig.media.photos.single { it.mediaId == 3L }.copy(bucketId = 9))
        rig.trigger(TriggerReason.APP_FOREGROUND)

        val t = flowTripletOf(rig.projection(), albums)!!
        assertEquals(2L, t.n)
        assertEquals(2L, t.confirmedRaw)
        assertEquals(HeroRender.Triplet, heroRenderOf(MediaAccess.FULL, t))
        rig.close()
    }

    // 「待备份 K」=「取消剩余 N 张」的 N = 取消时真正写下的张数，三处同一个定义（含 FAILED）。
    // 取消之后 K 归零、那一行收起；用户取消过的照片挡住「照片都存好了」这句话（规则 S3）。
    // 反证 1：BackupTriplet.k 改回 n − m → 取消后 k = 3，红。
    // 反证 2：cancelRemainingRowCount 不看 remaining > 0 → 取消后那一行仍在（0），红。
    @Test
    fun `K, the cancel row N and the photos actually skipped are the same number`() = runTest {
        val rig = Rig(this)
        val photos = (1L..5L).map { rig.photo(it, generation = it) }
        rig.order(photos[0], OrderState.CONFIRMED)
        rig.order(photos[1], OrderState.CONFIRMED)
        rig.order(photos[2], OrderState.FAILED)

        val before = rig.projection()
        val t = flowTripletOf(before, albums)!!
        assertEquals(3L, before.remaining)
        assertEquals(3L, t.k)
        assertEquals(3L, cancelRemainingRowCount(before, pairingLost = false))
        assertNull("配对已失效时出路是重新扫码，不给取消", cancelRemainingRowCount(before, pairingLost = true))

        val written = rig.engine.cancelRemaining()
        rig.settle()
        assertEquals(3, written.getCompleted())

        val after = rig.projection()
        val t2 = flowTripletOf(after, albums)!!
        assertEquals(0L, after.remaining)
        assertEquals(0L, t2.k)
        assertNull(cancelRemainingRowCount(after, pairingLost = false))
        assertEquals(3L, t2.skippedByUser)
        assertTrue(backupUiStateOf(after) is BackupUiState.AllSafe)
        assertFalse(
            "用户说了「剩下的不要了」，那几张确实没存到电脑上——不许说「照片都存好了」",
            allSafeTextAllowed(MediaAccess.FULL, t2, pairingLost = false, missingSourceCount = 0),
        )
        rig.close()
    }

    // 协调方修正：「已跳过的照片 N 张」保留。取消后这一行的 N = 被取消的张数；点恢复后清零，这些照片回到待传并被传走。
    // 反证 1：skippedByUserTotal 读错状态（例如 CANCELLED_BY_SCOPE）→ 取消后那一行仍为 null，红。
    // 反证 2：FlowEngine.restoreSkipped 只删行、不触发慢路径 → 恢复后三张没有 order、也没被传，红。
    // 反证 3：restoreSkippedByUser 空实现（返回 0、不删）→ 计数不清零，红。
    @Test
    fun `the skipped row counts what was cancelled and restore puts those photos back into the backlog`() = runTest {
        val rig = Rig(this)
        val photos = (1L..5L).map { rig.photo(it, generation = it) }
        rig.order(photos[0], OrderState.CONFIRMED)
        rig.order(photos[1], OrderState.CONFIRMED)
        rig.order(photos[2], OrderState.FAILED)
        assertNull("还没有取消过：这一行不渲染", skippedRowCount(rig.projection()))

        val cancelled = rig.engine.cancelRemaining()
        rig.settle()
        assertEquals(3, cancelled.getCompleted())
        val afterCancel = rig.projection()
        assertEquals(3L, skippedRowCount(afterCancel))
        assertEquals("这一行与「取消剩余」那一行各管各的", null, cancelRemainingRowCount(afterCancel, pairingLost = false))

        val restored = rig.engine.restoreSkipped()
        rig.settle()
        assertEquals(3, restored.getCompleted())
        val afterRestore = rig.projection()
        assertNull("恢复后清零，这一行收起", skippedRowCount(afterRestore))
        assertEquals((3L..5L).toList(), rig.delivery.deliveredMediaIds.sorted())
        assertEquals((1L..5L).map { OrderState.CONFIRMED }, (1L..5L).map { rig.state(it) })
        assertEquals(0L, afterRestore.remaining)
        rig.close()
    }

    // 恢复发生在暂停中：只删行、不传（任何触发都先查暂停）；Continue 之后的下一次慢路径把它们传走。
    @Test
    fun `restoring while paused sends nothing until a slow path after continuing`() = runTest {
        val rig = Rig(this)
        (1L..2L).forEach { rig.photo(it, generation = it) }
        rig.engine.cancelRemaining()
        rig.settle()
        rig.engine.pause()
        rig.settle()
        rig.engine.restoreSkipped()
        rig.settle()
        assertEquals(emptyList<Long>(), rig.delivery.deliveredMediaIds)
        assertEquals(2L, rig.projection().remaining)

        rig.engine.continueFlow()
        rig.settle()
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals(listOf(1L, 2L), rig.delivery.deliveredMediaIds.sorted())
        rig.close()
    }

    // K 还没算出来时退回 n − m，不会凭空说 0。
    @Test
    fun `before the remaining count arrives K falls back to n minus m`() = runTest {
        val rig = Rig(this)
        val photos = (1L..4L).map { rig.photo(it, generation = it) }
        rig.order(photos[0], OrderState.CONFIRMED)
        val p = rig.projection(withRemaining = false)
        assertNull(p.remaining)
        assertEquals(3L, flowTripletOf(p, albums)!!.k)
        assertNull(cancelRemainingRowCount(p, pairingLost = false))
        assertFalse(flowAllDone(p))
        rig.close()
    }

    // ---------------------------------------------------------------- 在传：状态行与进度条

    // 在传时：大数字仍是「已确认 / 总数」；状态行的「第 x / y 张」是正在传的这张 = 已确认 + 1；进度条是这张的字节进度。
    // 反证：Sending 的 done 用 p.confirmed（旧的「本轮第 x 张」习惯）→ 断言 done == 3 变 2，红。
    @Test
    fun `while sending the status line counts this photo and the bar shows its bytes`() = runTest {
        val rig = backedUp(2)
        rig.photo(3, generation = 3)
        rig.photo(4, generation = 4)
        rig.delivery.hold = true
        rig.trigger()

        val p = rig.projection()
        val state = backupUiStateOf(p) as BackupUiState.Sending
        assertEquals(3, state.done)
        assertEquals(4, state.total)
        assertEquals("IMG_3.jpg", state.currentFile)
        assertEquals(2L, flowTripletOf(p, albums)!!.m)
        assertEquals(FlowCommand.Pause, flowCommandOf(p))
        assertEquals(0, transferPermilleOf(p.current))

        rig.delivery.release()
        rig.settle()
        val done = rig.projection()
        assertNull(done.current)
        assertNull(transferPermilleOf(done.current))
        assertTrue(backupUiStateOf(done) is BackupUiState.AllSafe)
        rig.close()
    }

    // 首页进度条与前台服务通知共用 transferPermilleOf：边界都要稳。
    // 反证：去掉 coerceIn → bytesSent > total 时给出 1500，红。
    @Test
    fun `the per-photo byte progress is bounded and unknown sizes draw no bar`() {
        fun item(sent: Long, total: Long) = CurrentItem(1, "a.jpg", sent, total)
        assertNull(transferPermilleOf(null))
        assertNull("总字节未知 → 通知里画不确定进度条，首页不画", transferPermilleOf(item(10, 0)))
        assertEquals(0, transferPermilleOf(item(0, 200)))
        assertEquals(250, transferPermilleOf(item(50, 200)))
        assertEquals(1000, transferPermilleOf(item(300, 200)))
        assertEquals(0, transferPermilleOf(item(-5, 200)))
        // 4 GB 视频不溢出。
        assertEquals(500, transferPermilleOf(item(2L shl 30, 4L shl 30)))
    }

    // 已确认数已经等于总数时（桌面缺失、自动补传那一张），「第 x 张」封顶，不说「第 11 / 10 张」。
    @Test
    fun `the photo ordinal never exceeds the total`() {
        val p = FlowProjection(
            confirmed = 10, inScopeTotal = 10, current = CurrentItem(1, "a.jpg", 0, 10),
            waitReason = null, paused = false, failed = 0,
        )
        assertEquals(10, (backupUiStateOf(p) as BackupUiState.Sending).done)
    }

    // ---------------------------------------------------------------- 按钮与状态（MOB-51 接替）

    // 暂停压过一切；在传 = 暂停按钮；FAILED 且没在跑 = Trouble（点 = 立即重试）；否则唤醒。
    // Trouble 带的只是技术标记，主文案由 run_failed 出（规则 6：不许在这里造英文句子）。
    // 反证：backupUiStateOf 里 paused 分支挪到 running 之后 → 暂停中又收到进度时显示 Sending，红。
    @Test
    fun `hero state and hero command are routed on the same projection`() {
        val base = FlowProjection(confirmed = 3, inScopeTotal = 5, current = null, waitReason = null, paused = false, failed = 0)
        val sending = base.copy(current = CurrentItem(9, "x.jpg", 1, 2), running = true)
        assertEquals(BackupUiState.Paused, backupUiStateOf(sending.copy(paused = true)))
        assertEquals(FlowCommand.Continue, flowCommandOf(sending.copy(paused = true)))
        assertTrue(backupUiStateOf(sending) is BackupUiState.Sending)
        assertEquals(FlowCommand.Pause, flowCommandOf(sending))

        val failed = base.copy(failed = 2)
        assertEquals(BackupUiState.Trouble("flow.failed=2"), backupUiStateOf(failed))
        assertEquals(FlowCommand.Retry, flowCommandOf(failed))

        assertEquals(BackupUiState.Idle, backupUiStateOf(base.copy(remaining = 2)))
        assertEquals(FlowCommand.Wake, flowCommandOf(base))
    }

    // ---------------------------------------------------------------- 等待理由（UI19 接替）

    // FGS 被拒：等待态的状态行换成那句人话；只在此刻挡路的确实是 FGS 时说。
    // 回到前台：受阻事实清掉，理由消失，循环照常跑。
    // 反证：fgsBlockWaitNoticeRes 不看 waitReason（只看 fgsBlock != null）→ Wi‑Fi 那一条给出额度文案，红。
    @Test
    fun `a refused foreground service explains the wait only while it is what blocks the loop`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.foreground.grant = false
        rig.trigger()

        val p = rig.projection()
        val state = backupUiStateOf(p)
        assertEquals(BackupUiState.WaitingForConstraints, state)
        val res = fgsBlockWaitNoticeRes(p)
        assertEquals(R.string.state_background_protection_unknown, res)
        assertEquals(res, visibleWaitReasonRes(state, MediaAccess.FULL, pairingLost = false, reasonRes = res))
        assertNull(visibleWaitReasonRes(state, MediaAccess.PARTIAL, pairingLost = false, reasonRes = res))
        assertNull(visibleWaitReasonRes(state, MediaAccess.FULL, pairingLost = true, reasonRes = res))
        assertNull("不在等待态就不说", visibleWaitReasonRes(BackupUiState.Paused, MediaAccess.FULL, false, res))

        val wifi = p.copy(waitReason = WaitReason.WIFI)
        assertNull("此刻挡路的是 Wi‑Fi，不说额度的事", fgsBlockWaitNoticeRes(wifi))
        assertNull("用户暂停时说的是暂停", fgsBlockWaitNoticeRes(p.copy(paused = true)))

        rig.foreground.grant = true
        rig.engine.onAppForeground()
        rig.settle()
        val back = rig.projection()
        assertNull(fgsBlockWaitNoticeRes(back))
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        rig.close()
    }

    // 额度在传输中耗尽（onTimeout）：说的是额度那一句。
    @Test
    fun `a budget timeout mid-transfer explains itself with the budget sentence`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.hold = true
        rig.trigger()
        rig.engine.onForegroundLost(FgsBlockReason.BUDGET_EXHAUSTED)
        rig.settle()
        val p = rig.projection()
        assertEquals(WaitReason.FGS_BLOCKED, p.waitReason)
        assertEquals(R.string.state_background_budget_paused, fgsBlockWaitNoticeRes(p))
        rig.delivery.release()
        rig.close()
    }

    // ---------------------------------------------------------------- 「已从手机删除」（MOB-100 接替）

    // 还没传就被删的照片：横幅数出来；「知道了」之后收进设置卡那一行；之后再删的又会出现在横幅里。
    // 反证：acknowledgeMissingSource 不写确认水位 → 确认后横幅仍是 1，红。
    @Test
    fun `the deleted-before-sent notice counts, clears on acknowledgement and comes back for new ones`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.script.addLast { DeliveryOutcome.SourceMissing }
        rig.trigger()
        assertEquals(OrderState.SKIPPED_SOURCE_MISSING, rig.state(1))
        assertEquals(MissingSourceNotice(1), flowMissingSourceNotice(rig.projection()))

        rig.now += 10
        rig.engine.acknowledgeMissingSource()
        rig.settle()
        val acked = rig.projection()
        assertNull(flowMissingSourceNotice(acked))
        assertEquals(1L, acked.missingSourceAcknowledged)

        rig.now += 10
        rig.photo(2, generation = 2)
        rig.delivery.script.addLast { DeliveryOutcome.SourceMissing }
        rig.trigger()
        val later = rig.projection()
        assertEquals(MissingSourceNotice(1), flowMissingSourceNotice(later))
        assertEquals(1L, later.missingSourceAcknowledged)
        rig.close()
    }
}
