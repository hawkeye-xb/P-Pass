// MOB-89 RED：「取消当前轮」不许在「继续」缺席时占着「继续」的位置。
//
// 2026-09-20 10:31:46 的真机事故：验收人只点了暂停→继续，11 张待传照片却被
// 打成「已跳过」。三条独立取证已把它定死在「取消真的被调用了」这一支：
//
//   桌面 audit_decision（不是 audit_operation——卡面当时查错了表）：
//     2026-09-20 10:31:46 | cancel | causal_operation_id = 8b854bdb-…
//   手机账本同一轮 8b854bdb：{CONFIRMED: 4, CANCELLED_BY_USER_ROUND: 11}
//   代码侧另外两条候选写入点（CompletionAndScope.cancelCurrentRound、
//     DiscoveryLedgerStore.startCancellationRound）生产零调用方，已排除。
//
// 即：不是状态机漏了，是按钮在手指底下换了身份。本测试钉住换身份的那个组合。
package com.hawkeyexb.ppass.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB89CancelAffordanceTest {

    // ── 核心：pairingLost 下「继续」消失，取消也必须跟着消失 ──────────────
    //
    // 这是原缺陷的那个组合。修复前 HomeScreen 用的是
    // `if (state is BackupUiState.Paused)`，与「继续」的判据各走各的：
    // heroActionOf 因 pairingLost 返回 null → 「继续」不渲染 → 取消顺位
    // 左移，落进「继续」原来的坑。
    @Test
    fun pairing_lost_hides_resume_so_cancel_must_hide_too_and_never_take_its_slot() {
        val state = BackupUiState.Paused
        assertEquals(
            "前提：pairingLost 下「继续」确实不渲染",
            null,
            heroActionOf(state, pairingLost = true),
        )
        assertFalse(
            "「继续」缺席时「取消当前轮」必须一起缺席——否则它会占据「继续」的位置，" +
                "用户凭手指记忆点下去点到的是取消（2026-09-20 10:31:46 真机事故）",
            cancelAffordanceVisible(state, pairingLost = true),
        )
    }

    // 反证锚点：把判据换回修复前那条（只看 Paused），上面那条必须失效。
    // 它证明该用例钉的确实是「两个判据绑在一起」，而不是碰巧某个别的条件
    // 也让取消隐藏了。
    @Test
    fun counter_proof_the_old_paused_only_rule_would_still_render_cancel() {
        val state: BackupUiState = BackupUiState.Paused
        val oldRule = state is BackupUiState.Paused // 修复前 HomeScreen 的原判据
        assertTrue(
            "反证：旧判据在 pairingLost 下仍然为真 —— 这正是取消能顶位的原因。" +
                "若这里变成 false，说明上面那条用例已经失去判别力。",
            oldRule,
        )
        assertFalse(cancelAffordanceVisible(state, pairingLost = true))
    }

    // ── 正常暂停态：取消照常可用，修复不许把它整个弄丢 ────────────────────
    @Test
    fun an_ordinary_user_pause_still_offers_cancel() {
        assertEquals(HeroAction.Resume, heroActionOf(BackupUiState.Paused, pairingLost = false))
        assertTrue(cancelAffordanceVisible(BackupUiState.Paused, pairingLost = false))
    }

    // ── 其余状态一律没有取消 ──────────────────────────────────────────────
    @Test
    fun cancel_never_appears_outside_a_user_pause() {
        val notPaused = listOf(
            BackupUiState.Idle,
            BackupUiState.Scanning(3),
            BackupUiState.Hashing(1, 3),
            BackupUiState.Sending(1, 3),
            BackupUiState.AllSafe(3, 0),
            BackupUiState.WaitingForConstraints,
            BackupUiState.CancelledCurrentRound,
            BackupUiState.NoAlbums,
            BackupUiState.Trouble("boom"),
        )
        notPaused.forEach { state ->
            assertFalse(
                "$state 不是用户暂停态，不该出现「取消当前轮」",
                cancelAffordanceVisible(state, pairingLost = false),
            )
            assertFalse(
                "$state + pairingLost 同样不该出现",
                cancelAffordanceVisible(state, pairingLost = true),
            )
        }
    }

    // ── 不变式：取消的出场集合必须是「继续」出场集合的子集 ────────────────
    //
    // 穷举全部 (state, pairingLost) 组合。只要这条成立，「取消顶替继续的
    // 位置」在结构上就不可能发生——不依赖任何单点用例。
    @Test
    fun cancel_visibility_is_a_subset_of_resume_visibility_across_every_combination() {
        val states = listOf(
            BackupUiState.Idle, BackupUiState.Scanning(0), BackupUiState.Hashing(0, 1),
            BackupUiState.Sending(0, 1), BackupUiState.AllSafe(0, 0), BackupUiState.Paused,
            BackupUiState.WaitingForConstraints, BackupUiState.CancelledCurrentRound,
            BackupUiState.NoAlbums, BackupUiState.Trouble("x"),
        )
        states.forEach { state ->
            listOf(true, false).forEach { lost ->
                if (cancelAffordanceVisible(state, lost)) {
                    assertEquals(
                        "取消出现时，「继续」必须同时在场（state=$state pairingLost=$lost）",
                        HeroAction.Resume,
                        heroActionOf(state, lost),
                    )
                }
            }
        }
    }

    // ── 接线还在：HomeScreen 必须用新判据 + 降级组件渲染取消 ──────────────
    //
    // 本仓 Android 侧没有 Robolectric，视觉层级无法在 JVM 单测里断言。
    // 这条只钉「接线还在」，不钉行为（AGENTS.md 对源文本门禁的定位）：
    // 一旦有人把判据改回 `state is BackupUiState.Paused`、或把取消改回
    // 与「继续」同款的 HeroSecondaryButton，这里变红。
    @Test
    fun home_screen_wires_cancel_through_the_new_rule_and_the_demoted_component() {
        val src = java.io.File(
            "src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt",
        ).readText()
        val block = src.substringAfter("if (cancelAffordanceVisible(state, pairingLost))")
            .substringBefore("}")
        assertTrue(
            "取消必须走降级组件 HeroTertiaryAction，不能与「继续」共用 HeroSecondaryButton",
            block.contains("HeroTertiaryAction"),
        )
        assertFalse(
            "取消不得再显示与「继续」相同的「处理中…」文案——那一刻两个相邻按钮完全无法分辨",
            block.contains("backup_command_processing"),
        )
    }
}
