// UI-19 步骤 2（渲染）：暂停有理由，就把理由说出来——挂在既有暂停态的
// 状态行上，不新增横幅。
//
// 事实源：docs/design/2026-09-22-home-notice-priority.md §2.5 规则 P、
// §2.4 脚注 6（PAIR 压制）与脚注 12（ACCESS 压制）。
//
// HomeScreen 是 Compose、本仓无 Robolectric，所以判据提纯成纯函数
// [visiblePauseReasonRes]（与 heroNumberIsSafe / heroActionOf 同一条路），
// 真行为由本文件直接测；「生产链路真的读了数据源、而且真的渲染在那一行」
// 由末尾的源文本门禁守——把任何一段接线摘掉，那几条当场红。
//
// 数据源侧的排序规则（evidenceWeight / supersedes）归步骤 1（PR #379），
// 本文件只读它的结论，不重测它的九个格。
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.flow.ForegroundStartOutcome
import com.hawkeyexb.ppass.backup.flow.TransferProtection
import com.hawkeyexb.ppass.backup.flow.TransferProtectionStore
import com.hawkeyexb.ppass.backup.flow.transferProtectionNoticeRes
import com.hawkeyexb.ppass.backup.flow.transferProtectionOf
import com.hawkeyexb.ppass.backup.tripletOf
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UI19PauseReasonRenderTest {

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return dir
    }

    /** 去掉块注释与行注释——断言的是代码，不是注释里的引用。 */
    private fun codeOf(relative: String): String =
        File(repoRoot(), relative).readText()
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .lines()
            .filterNot { it.trimStart().startsWith("//") }
            .joinToString("\n")

    private fun homeScreen(): String =
        codeOf("apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt")

    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-ui19-render-$case").toFile()

    /** 数据源的真实读法：跟生产链路同一条（store → notice res）。 */
    private fun reasonFromSource(vararg records: Pair<ForegroundStartOutcome, Long>): Int? {
        val store = TransferProtectionStore(tempDir("src"))
        records.forEach { (outcome, at) -> store.record(outcome, at) }
        return transferProtectionNoticeRes(store.load())
    }

    // ── 本体：数据源说配额耗尽 → 状态行出现那句人话 ─────────────────────

    @Test
    fun the_paused_status_line_says_why_when_the_source_reports_the_budget_is_gone() {
        // 系统亲口说的那一条（onTimeout / isSystemBudgetExhausted 才写得出）。
        val reason = reasonFromSource(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED to 1_758_534_675_688L)
        assertEquals(R.string.state_background_budget_paused, reason)

        assertEquals(
            "规则 P：暂停态 + 权限完整 + 未失联 ⇒ 状态行必须换成那句人话",
            R.string.state_background_budget_paused,
            visiblePauseReasonRes(
                state = BackupUiState.Paused,
                mediaAccess = MediaAccess.FULL,
                pairingLost = false,
                reasonRes = reason,
            ),
        )
    }

    @Test
    fun that_sentence_is_the_one_353_shipped_and_this_card_does_not_reword_it() {
        // 文案不在本卡范围内（#353 交付，禁用词用例已钉死）——这里只钉
        // 「渲染的是那一条」，顺带锁死它没被改词。
        val zh = File(repoRoot(), "apps/android/app/src/main/res/values-zh/strings.xml").readText()
        assertTrue(
            "values-zh 里那句人话被改了措辞——本卡不准动文案",
            zh.contains(
                """<string name="state_background_budget_paused">今天在后台备份的时间用完了。""" +
                    """备份已暂停——把 P-Pass 留在屏幕上就能继续，或者明天自动接着传。</string>""",
            ),
        )
    }

    @Test
    fun a_refusal_the_system_would_not_explain_gets_its_own_honest_line() {
        // 说不出原因的拒绝**不许**借用「今天时间用完了」——两句话是两件事。
        val reason = reasonFromSource(ForegroundStartOutcome.START_REFUSED to 1_000_000L)
        assertEquals(R.string.state_background_protection_unknown, reason)
        assertEquals(
            R.string.state_background_protection_unknown,
            visiblePauseReasonRes(BackupUiState.Paused, MediaAccess.FULL, false, reason),
        )
    }

    // ── 三态里的「未知」：不渲染理由，且不得渲染成正常态 ────────────────

    @Test
    fun the_unknown_verdict_renders_no_reason_at_all() {
        val store = TransferProtectionStore(tempDir("unknown"))

        // 空盘 = 从没尝试过。
        assertEquals(TransferProtection.UNKNOWN, transferProtectionOf(store.load()))
        assertNull("空盘不许编出理由", transferProtectionNoticeRes(store.load()))

        // 只提交过一次启动请求（#379：无观测分量）。
        store.record(ForegroundStartOutcome.START_REQUESTED, 1_000_000L)
        assertEquals(TransferProtection.UNKNOWN, transferProtectionOf(store.load()))
        assertNull("「提交了请求」不是理由", transferProtectionNoticeRes(store.load()))

        assertNull(
            "R-UNKNOWN：不知道就沉默——不渲染任何理由",
            visiblePauseReasonRes(
                state = BackupUiState.Paused,
                mediaAccess = MediaAccess.FULL,
                pairingLost = false,
                reasonRes = transferProtectionNoticeRes(store.load()),
            ),
        )
    }

    @Test
    fun the_unknown_verdict_must_not_fall_back_to_an_everything_is_fine_line() {
        // 「不渲染理由」只是一半，另一半是**不得退回正常态文案**。
        // 状态行退回 idleStatusText，它在暂停态下走 Ready/Pending：
        val pausedNoDebt = statusLineOf(BackupUiState.Paused, pendingK = 0L)
        val pausedWithDebt = statusLineOf(BackupUiState.Paused, pendingK = 3L)
        assertFalse("暂停态的状态行不许是 AllSafe（「照片都存好了」）", pausedNoDebt is StatusLine.AllSafe)
        assertEquals(StatusLine.Ready, pausedNoDebt)
        assertEquals(StatusLine.Pending(3L), pausedWithDebt)

        // 并且即使账本恰好「全部已确认」，规则 G5（#384）也否掉那句话——
        // 这条明写出来，不靠运气继承。
        val pausedTriplet = tripletOf(
            n = 10L, confirmedCount = 10L, lastSuccessAt = 1L,
            pausedByUser = true,
        )
        assertFalse(
            "G5/规则 S：被按停时不许说「照片都存好了」",
            allSafeTextAllowed(
                mediaAccess = MediaAccess.FULL,
                triplet = pausedTriplet,
                pairingLost = false,
                missingSourceCount = 0,
                cancelledRoundCount = 0,
            ),
        )
    }

    // ── ACCESS × PAUSE-WHY = ACCESS 压制（脚注 12），不是并存 ─────────────

    @Test
    fun an_incomplete_media_permission_suppresses_the_reason_instead_of_sharing_the_screen() {
        val reason = reasonFromSource(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED to 1_000_000L)
        assertEquals(R.string.state_background_budget_paused, reason)

        for (blocked in listOf(MediaAccess.PARTIAL, MediaAccess.NONE)) {
            assertNull(
                "ACCESS 压制：权限不完整（$blocked）时英雄卡内部整块被引导卡顶替，" +
                    "规则 P 的挂载点不存在——理由不许假装能显示",
                visiblePauseReasonRes(BackupUiState.Paused, blocked, false, reason),
            )
        }
    }

    @Test
    fun the_reason_is_rendered_inside_the_full_access_branch_only() {
        // 结构证据：理由的渲染点在 `mediaAccess != MediaAccess.FULL` 那个
        // if 的 else 分支里（英雄卡内部），所以 ACCESS 压制是**构造保证**的，
        // 不靠运行时再判一次。
        val source = homeScreen()
        val accessBranch = source.indexOf("if (mediaAccess != MediaAccess.FULL) {")
        val fullAccessMarker = source.indexOf("val heroRender = heroRenderOf(mediaAccess, t)")
        // 注意找的是**渲染点**，不是文件上方那个纯函数的定义。
        val renderPoint = source.indexOf("val pauseReason = visiblePauseReasonRes(")
        assertTrue("英雄卡权限分支还在原处", accessBranch > 0)
        assertTrue("FULL 分支的标记还在原处", fullAccessMarker > accessBranch)
        assertTrue(
            "理由必须渲染在 FULL 分支之内（在 heroRenderOf 之后、英雄卡结束之前）",
            renderPoint > fullAccessMarker,
        )
    }

    // ── PAIR × PAUSE-WHY = PAIR 压制（脚注 6） ───────────────────────────

    @Test
    fun a_lost_pairing_suppresses_the_reason_because_the_mount_point_is_gone() {
        val reason = reasonFromSource(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED to 1_000_000L)
        assertNull(
            "配对失效时 heroActionOf 返回 null，「继续」按钮不在场 ⇒ 没有挂载点；" +
                "且「今天后台时间用完了」在配对已断时是误导",
            visiblePauseReasonRes(BackupUiState.Paused, MediaAccess.FULL, true, reason),
        )
    }

    @Test
    fun a_state_that_is_not_paused_never_shows_a_pause_reason() {
        val reason = reasonFromSource(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED to 1_000_000L)
        // 盘上的结论不新鲜（步骤 1 登记的前提）——所以它只有在账本独立地
        // 说「确实停着」时才允许出场，绝不用它去推断「有没有在传」。
        for (state in listOf(
            BackupUiState.Idle,
            BackupUiState.AllSafe(10, 0),
            BackupUiState.Sending(1, 2),
            BackupUiState.WaitingForConstraints,
            BackupUiState.NoAlbums,
            BackupUiState.CancelledCurrentRound,
        )) {
            assertNull(
                "$state 不是暂停态，状态行不许出现暂停理由",
                visiblePauseReasonRes(state, MediaAccess.FULL, false, reason),
            )
        }
        assertEquals(
            "暂停态本身必须出",
            R.string.state_background_budget_paused,
            visiblePauseReasonRes(BackupUiState.Paused, MediaAccess.FULL, false, reason),
        )
    }

    @Test
    fun the_gate_is_the_same_one_the_resume_button_uses() {
        // 挂载点判据不许自己另写一份：与「继续」按钮同一个 heroActionOf，
        // 否则又会出现 MOB-89 那种「两个判据各走各的」的组合。
        val reason = reasonFromSource(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED to 1_000_000L)
        for (pairingLost in listOf(false, true)) {
            for (state in listOf(BackupUiState.Paused, BackupUiState.Idle, BackupUiState.Sending(0, 1))) {
                val mountPointPresent = heroActionOf(state, pairingLost) == HeroAction.Resume
                assertEquals(
                    "state=$state pairingLost=$pairingLost：理由的出场必须与「继续」在场同真同假",
                    mountPointPresent,
                    visiblePauseReasonRes(state, MediaAccess.FULL, pairingLost, reason) != null,
                )
            }
        }
        assertTrue(
            "判据必须调用 heroActionOf，不许复制一份 `state is Paused`",
            homeScreen().contains("heroActionOf(state, pairingLost) != HeroAction.Resume"),
        )
    }

    // ── 不新增横幅：理由挂在既有暂停态状态行上 ───────────────────────────

    @Test
    fun the_reason_replaces_the_existing_status_line_text_and_adds_no_banner() {
        val source = homeScreen()

        // ① 它就在既有状态行那一个 Text 里，与 idleStatusText 二选一。
        assertTrue(
            "理由必须与 idleStatusText 共用同一个 Text——那才是「替换文案」",
            source.contains("if (pauseReason != null) stringResource(pauseReason) else idleStatusText("),
        )

        // ② 判据只出现一次（没有第二处渲染点）。
        assertEquals(
            "visiblePauseReasonRes 在 HomeScreen 里只许有一个渲染点",
            1,
            Regex("visiblePauseReasonRes\\(").findAll(source).count() - 1, // 减掉函数自己的定义
        )

        // ③ 渲染点到状态行之间不许夹任何卡片/容器（= 没有新横幅）。
        val region = source.substringAfter("val pauseReason = visiblePauseReasonRes(")
            .substringBefore("fontSize = 13.5.sp, color = PPColor.Ink60,")
        assertFalse("不许新增 Surface", region.contains("Surface("))
        assertFalse("不许新增 NoticeCard", region.contains("NoticeCard("))

        // ④ NoticeHost 那边一个字都不许加——PAUSE-WHY 不进横幅槽位。
        val notices = codeOf("apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/HomeNotices.kt")
        assertFalse(
            "暂停理由不许变成 NoticeHost 的横幅",
            notices.contains("state_background_budget_paused") ||
                notices.contains("state_background_protection_unknown") ||
                notices.contains("PauseReason") ||
                notices.contains("pauseReason"),
        )
    }

    // ── 反证锚点：把任何一段接线摘掉，下面几条必红 ────────────────────────

    @Test
    fun the_holder_really_reads_the_protection_store_every_tick() {
        val holder = codeOf("apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupUiStateHolder.kt")
        assertTrue(
            "holder 必须真的读 #379 的数据源——改回不读，本条红",
            holder.contains("TransferProtectionStore(context.filesDir).load()") &&
                holder.contains("transferProtectionNoticeRes("),
        )
        assertTrue(
            "结论必须暴露成 UI 可读的状态",
            holder.contains("val pauseReason: State<Int?>"),
        )
        assertTrue(
            "必须在每次账本刷新的同一 tick 里更新（refreshFlowState）",
            holder.substringAfter("private fun refreshFlowState(").contains("_pauseReason.value ="),
        )
    }

    @Test
    fun the_call_site_really_hands_the_reason_to_the_home_screen() {
        // 带默认值的新参数最容易「测试全绿、生产恒空」——把调用点钉死。
        val main = codeOf("apps/android/app/src/main/java/com/hawkeyexb/ppass/MainActivity.kt")
        assertTrue(
            "MainActivity 必须把 holder 的结论传进 HomeScreen——删掉这一行，本条红",
            main.contains("pauseReasonRes = holder.pauseReason.value"),
        )
        assertTrue(
            "HomeScreen 必须接这个参数",
            homeScreen().contains("pauseReasonRes: Int? = null"),
        )
        assertTrue(
            "渲染点必须读参数，不许在 composable 里自己读盘",
            homeScreen().contains("reasonRes = pauseReasonRes"),
        )
        assertFalse(
            "HomeScreen 不许自己去碰数据源（Compose 里读盘 + 不可测）",
            homeScreen().contains("TransferProtectionStore(") ||
                homeScreen().contains("FlowTransferForeground."),
        )
    }
}
