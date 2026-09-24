// #413 W5：UI 只读 EngineView 渲染。全部用手搓的 EngineView 走纯函数，不经引擎（W1 正在改引擎 API）。
// 反证写在每个测试上方。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.RoundCounter
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.ui.BackupUiState
import com.hawkeyexb.ppass.ui.HeroAction
import com.hawkeyexb.ppass.ui.StatusLine
import com.hawkeyexb.ppass.ui.desktopLowSpaceHintVisible
import com.hawkeyexb.ppass.ui.heroActionOf
import com.hawkeyexb.ppass.ui.isBackupRunning
import com.hawkeyexb.ppass.ui.statusLineOf
import com.hawkeyexb.ppass.ui.visibleWaitReasonRes
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class W5EngineViewUiTest {
    private val item = CurrentItem(orderId = 7, fileName = "IMG_7.jpg", bytesSent = 50, totalBytes = 200)

    private fun p(view: EngineView?, confirmed: Long = 3, n: Long? = 10, failed: Long = 0, fgs: FgsBlockReason? = null) =
        FlowProjection(view = view, confirmed = confirmed, inScopeTotal = n, failed = failed, fgsBlock = fgs)

    private fun v(state: GlobalState, pending: Int = 4, done: Int = 0, current: CurrentItem? = null, wait: WaitReason? = null, health: DesktopHealth? = null) =
        EngineView(state = state, waitReason = wait, pending = pending, doneThisRound = done, current = current, desktopHealth = health)

    // ---------------------------------------------------------------- 全局状态 → 首页状态

    // 四个全局状态各有出口；检查 / 准备阶段（RUNNING、还没有当前这一张）不许显示成空闲。
    // 反证：backupUiStateOf 的 RUNNING 分支在 current == null 时落到 idleUiStateOf → 得到 Idle，红。
    @Test
    fun `each global state has its own home state and preparing is not idle`() {
        assertEquals(BackupUiState.Paused, backupUiStateOf(p(v(GlobalState.PAUSED))))
        assertEquals(BackupUiState.Preparing, backupUiStateOf(p(v(GlobalState.RUNNING))))
        assertEquals(BackupUiState.Sending(done = 3, total = 6, currentFile = "IMG_7.jpg"), backupUiStateOf(p(v(GlobalState.RUNNING, done = 2, current = item))))
        assertEquals(BackupUiState.Waiting(WaitReason.DESKTOP_UNREACHABLE), backupUiStateOf(p(v(GlobalState.WAITING, wait = WaitReason.DESKTOP_UNREACHABLE))))
        assertEquals(BackupUiState.Idle, backupUiStateOf(p(v(GlobalState.IDLE))))

        assertTrue(statusLineOf(BackupUiState.Preparing, pendingK = 4) is StatusLine.Working)
        assertTrue(isBackupRunning(BackupUiState.Preparing))
        assertEquals(StatusLine.Paused, statusLineOf(BackupUiState.Paused, pendingK = 4))
        assertEquals(StatusLine.Waiting, statusLineOf(BackupUiState.Waiting(WaitReason.WIFI), pendingK = 4))
    }

    // 等待压过失败：等待中是「会自己好」，红卡是「要你处理」——同时成立时先说在等什么。
    // NOT_PAIRED 不说「等待」：出路是配对失效红卡。
    @Test
    fun `waiting outranks trouble and not-paired is not rendered as a wait`() {
        assertEquals(BackupUiState.Waiting(WaitReason.BATTERY), backupUiStateOf(p(v(GlobalState.WAITING, wait = WaitReason.BATTERY), failed = 2)))
        assertEquals(BackupUiState.Trouble("flow.failed=2"), backupUiStateOf(p(v(GlobalState.WAITING, wait = WaitReason.NOT_PAIRED), failed = 2)))
        assertNull(waitReasonTextRes(p(v(GlobalState.WAITING, wait = WaitReason.NOT_PAIRED))))
    }

    // ---------------------------------------------------------------- 按钮

    // 「暂停」只在备份中（含准备阶段），「继续」只在已暂停；空闲、等待中都没有英雄区按钮。
    // 反证：heroActionOf 对 Waiting 给 Resume（旧的「等待也能点继续」）→ 红。
    @Test
    fun `pause only while running and resume only while paused`() {
        assertEquals(HeroAction.Pause, heroActionOf(BackupUiState.Preparing, pairingLost = false))
        assertEquals(HeroAction.Pause, heroActionOf(BackupUiState.Sending(1, 2, "a.jpg"), pairingLost = false))
        assertEquals(HeroAction.Resume, heroActionOf(BackupUiState.Paused, pairingLost = false))
        assertNull(heroActionOf(BackupUiState.Waiting(WaitReason.WIFI), pairingLost = false))
        assertNull(heroActionOf(BackupUiState.Idle, pairingLost = false))
        assertNull(heroActionOf(BackupUiState.Paused, pairingLost = true))

        assertEquals(FlowCommand.Pause, flowCommandOf(p(v(GlobalState.RUNNING))))
        assertEquals(FlowCommand.Continue, flowCommandOf(p(v(GlobalState.PAUSED))))
        assertEquals(FlowCommand.Wake, flowCommandOf(p(v(GlobalState.WAITING, wait = WaitReason.WIFI))))
    }

    // 「取消剩余 N 张」只在已暂停 / 等待中；N = 待办。备份中要先暂停，空闲时没有「剩余」。
    // 反证：cancelRemainingRowCount 不看全局状态 → RUNNING / IDLE 也给出 4，红。
    @Test
    fun `the cancel row only appears while paused or waiting`() {
        assertEquals(4L, cancelRemainingRowCount(p(v(GlobalState.PAUSED)), pairingLost = false))
        assertEquals(4L, cancelRemainingRowCount(p(v(GlobalState.WAITING, wait = WaitReason.DESKTOP_UNREACHABLE)), pairingLost = false))
        assertNull(cancelRemainingRowCount(p(v(GlobalState.RUNNING, current = item)), pairingLost = false))
        assertNull(cancelRemainingRowCount(p(v(GlobalState.IDLE)), pairingLost = false))
        assertNull("没有剩余就不给", cancelRemainingRowCount(p(v(GlobalState.PAUSED, pending = 0)), pairingLost = false))
        assertNull("配对失效时出路是重新扫码", cancelRemainingRowCount(p(v(GlobalState.PAUSED)), pairingLost = true))
        assertNull("视图还没拿到", cancelRemainingRowCount(p(null), pairingLost = false))
    }

    // ---------------------------------------------------------------- 待备份与进度

    // 待备份 K = EngineView.pending（唯一来源）；视图还没拿到时 K 退回 n − m，不凭空说 0、不说「都存好了」。
    // 反证：flowTripletOf 的 remaining 改成 view?.pending ?: 0 → 视图为空时 K = 0，红。
    @Test
    fun `pending is the engine view and an unknown view never claims zero`() {
        assertEquals(4L, flowTripletOf(p(v(GlobalState.IDLE)), setOf(1L))!!.k)
        assertEquals(7L, flowTripletOf(p(null), setOf(1L))!!.k)
        assertFalse(flowAllDone(p(null)))
        assertTrue(backupUiStateOf(p(null)) is BackupUiState.Idle)
    }

    // 进度 = 本轮已完成 /（本轮已完成 + 待备份）；当前这一张的字节进度照旧（首页进度条与 FGS 通知同一个函数）。
    @Test
    fun `round progress counts this round and the bar keeps the per-photo bytes`() {
        val sending = p(v(GlobalState.RUNNING, pending = 3, done = 5, current = item))
        assertEquals(BackupUiState.Sending(done = 6, total = 8, currentFile = "IMG_7.jpg"), backupUiStateOf(sending))
        assertEquals(250, transferPermilleOf(sending.current))
        assertNull("不在备份中就没有当前这一张", p(v(GlobalState.PAUSED, current = item)).current)
    }

    // ---------------------------------------------------------------- 等待原因的话

    // 契约 §3 的九个等待原因：NOT_PAIRED 不在状态行说，其余八个各有一句、互不相同、都不是通用的「等待条件满足」。
    // 反证：DESKTOP_STORAGE_FULL 那一行改成 backup_waiting_constraints → 红。
    @Test
    fun `every contract wait reason has its own sentence`() {
        assertEquals(
            listOf(
                "NOT_PAIRED", "DISABLED", "WIFI", "BATTERY", "FGS_BLOCKED",
                "DESKTOP_UNREACHABLE", "DESKTOP_STORAGE_FULL", "DESKTOP_LIBRARY_UNAVAILABLE", "DESKTOP_STORAGE_ERROR",
            ),
            WaitReason.entries.map { it.name },
        )
        assertNull(waitReasonTextRes(WaitReason.NOT_PAIRED, null))
        val sentences = WaitReason.entries.filter { it != WaitReason.NOT_PAIRED }.associateWith { waitReasonTextRes(it, null) }
        sentences.forEach { (reason, res) ->
            assertNotNull(reason.name, res)
            assertNotEquals("$reason 不能只说「正在等待备份条件满足」", R.string.backup_waiting_constraints, res)
        }
        assertEquals("八个原因八句话", 8, sentences.values.toSet().size)
        // FGS 受阻再按具体原因细分。
        assertEquals(R.string.state_background_budget_paused, waitReasonTextRes(WaitReason.FGS_BLOCKED, FgsBlockReason.BUDGET_EXHAUSTED))
        assertEquals(R.string.state_background_protection_unknown, waitReasonTextRes(WaitReason.FGS_BLOCKED, FgsBlockReason.START_REFUSED))
    }

    // 额度受阻是「等待中」，不是「已暂停」——那两句话里不许再说暂停（#413 §4：已暂停只指用户暂停）。
    // 反证：把「备份已暂停」加回 state_background_budget_paused → 红。
    @Test
    fun `the background budget sentences no longer call the wait a pause`() {
        val res = File("src/main/res")
        val zh = File(res, "values-zh/strings.xml").readText()
        val en = File(res, "values/strings.xml").readText()
        fun line(xml: String, key: String) = xml.lines().single { it.contains("name=\"$key\"") }.substringAfter(">")
        listOf("state_background_budget_paused", "state_background_protection_unknown").forEach { key ->
            assertFalse(key, line(zh, key).contains("暂停"))
            assertFalse(key, line(en, key).contains("paused", ignoreCase = true))
        }
    }

    // ---------------------------------------------------------------- 桌面低空间预警

    // freeBytes < 5 GiB 预警；不报健康（旧桌面）、空间足够都不说；权限不全 / 配对已断不说。
    @Test
    fun `desktop low space warns below five gigabytes`() {
        val gib = 1024L * 1024 * 1024
        assertTrue(desktopLowSpaceWarning(p(v(GlobalState.IDLE, health = DesktopHealth(freeBytes = 4 * gib)))))
        assertFalse(desktopLowSpaceWarning(p(v(GlobalState.IDLE, health = DesktopHealth(freeBytes = 6 * gib)))))
        assertFalse(desktopLowSpaceWarning(p(v(GlobalState.IDLE, health = DesktopHealth(freeBytes = null)))))
        assertFalse(desktopLowSpaceWarning(p(v(GlobalState.IDLE))))
        assertFalse(desktopLowSpaceWarning(p(null)))
        assertTrue(desktopLowSpaceHintVisible(true, MediaAccess.FULL, pairingLost = false))
        assertFalse(desktopLowSpaceHintVisible(true, MediaAccess.FULL, pairingLost = true))
        assertFalse(desktopLowSpaceHintVisible(true, MediaAccess.PARTIAL, pairingLost = false))
    }

    // 等待态状态行的出场闸门对每个原因都成立（接替 #418 只对 FGS 受阻的那一条）。
    @Test
    fun `the wait sentence replaces the status line only while waiting`() {
        val waiting = BackupUiState.Waiting(WaitReason.DESKTOP_UNREACHABLE)
        val res = R.string.state_waiting_desktop_unreachable
        assertEquals(res, visibleWaitReasonRes(waiting, MediaAccess.FULL, pairingLost = false, reasonRes = res))
        assertNull(visibleWaitReasonRes(waiting, MediaAccess.FULL, pairingLost = true, reasonRes = res))
        assertNull(visibleWaitReasonRes(BackupUiState.Idle, MediaAccess.FULL, pairingLost = false, reasonRes = res))
    }

    // ---------------------------------------------------------------- W1 视图补齐（W1 填好待办 / 检查阶段后与之一起删）

    // 检查阶段（CHECKING）算备份中；暂停压过一切；当前这一张只在备份中带出；待办与本轮已完成由 UI 侧填。
    // 反证：supplementEngineView 不看 phase → CHECKING 时仍是 IDLE，红。
    @Test
    fun `the engine view is supplemented with pending and the checking phase`() {
        val idle = EngineView(GlobalState.IDLE)
        supplementEngineView(idle, LoopPhase.CHECKING, pending = 3, doneThisRound = 1).let {
            assertEquals(GlobalState.RUNNING, it.state)
            assertEquals(3, it.pending)
            assertEquals(1, it.doneThisRound)
            assertNull(it.current)
        }
        val waiting = EngineView(GlobalState.WAITING, waitReason = WaitReason.WIFI)
        assertEquals(waiting.copy(pending = 3), supplementEngineView(waiting, LoopPhase.IDLE, pending = 3, doneThisRound = 0))
        assertNull(supplementEngineView(waiting, LoopPhase.CHECKING, 3, 0).waitReason)
        val paused = EngineView(GlobalState.PAUSED, current = item)
        supplementEngineView(paused, LoopPhase.RUNNING, 3, 0).let {
            assertEquals(GlobalState.PAUSED, it.state)
            assertNull(it.current)
        }
        val running = EngineView(GlobalState.RUNNING, current = item, desktopHealth = DesktopHealth(freeBytes = 1))
        assertEquals(running.copy(pending = 2), supplementEngineView(running, LoopPhase.RUNNING, 2, 0))
    }

    // 「本轮已完成」的近似：备份中待办每减 1 记 1；新拍的照片抬高待办不抵扣；暂停 / 等待中保留本轮；回到空闲清零。
    @Test
    fun `the round counter counts completions within a round`() {
        val c = RoundCounter()
        assertEquals(0, c.next(GlobalState.RUNNING, 5))
        assertEquals(1, c.next(GlobalState.RUNNING, 4))
        assertEquals(1, c.next(GlobalState.RUNNING, 6)) // 新拍了两张
        assertEquals(3, c.next(GlobalState.RUNNING, 4))
        assertEquals(3, c.next(GlobalState.PAUSED, 4))
        assertEquals(4, c.next(GlobalState.RUNNING, 3))
        assertEquals(0, c.next(GlobalState.IDLE, 3))
        assertEquals(0, c.next(GlobalState.RUNNING, 3))
    }
}
