// UI-16: 英雄卡的绿色是承诺——五条闸门全满足才准用 PPColor.Safe。
//
// 事实源：docs/design/2026-09-22-home-notice-priority.md §2.2 规则 G、
// §2.3 规则 H（H-C）、§2.3b 规则 S。
//
// HomeScreen 是 Compose、本仓无 Robolectric，所以判据全部提纯成纯函数
// （与 shouldShowWifiDeferredHint / heroActionOf 同一条路），真行为由本文件
// 直接测；「生产链路真的接上了这些判据」由末尾的源文本门禁守。
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.BackupTriplet
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.tripletOf
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UI16HeroGreenGateTest {

    private fun homeScreen() =
        File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()

    /** 五条闸门全过的基线：10 张全部确认、无失败、未暂停。 */
    private fun healthy(): BackupTriplet = tripletOf(n = 10L, confirmedCount = 10L, lastSuccessAt = 1L)

    // ── 规则 G：五条闸门各一例（其余四条恒满足，一例只动一条） ──

    @Test
    fun g1_partial_or_no_media_access_forbids_green() {
        for (blocked in listOf(MediaAccess.PARTIAL, MediaAccess.NONE)) {
            assertFalse(
                "G1：相册权限不完整（$blocked）时 N/M 是假数，主数字不得为绿",
                heroNumberIsSafe(blocked, healthy(), pairingLost = false),
            )
        }
    }

    @Test
    fun g2_an_unavailable_triplet_forbids_green() {
        assertFalse(
            "G2：三元组读不出来（null）时没有任何数可以染绿",
            heroNumberIsSafe(MediaAccess.FULL, null, pairingLost = false),
        )
    }

    @Test
    fun g3_a_lost_pairing_forbids_green() {
        assertFalse(
            "G3：配对已失效——备份完全停了，绿色是替一件不会发生的事作保",
            heroNumberIsSafe(MediaAccess.FULL, healthy(), pairingLost = true),
        )
    }

    @Test
    fun g4_a_failed_item_awaiting_the_user_forbids_green() {
        val withFailure = tripletOf(
            n = 10L, confirmedCount = 10L, lastSuccessAt = 1L,
            hasFailedNeedsUser = true,
        )
        assertFalse(
            "G4：账本里有 FAILED_NEEDS_USER 时不是「数据已安全存好」",
            heroNumberIsSafe(MediaAccess.FULL, withFailure, pairingLost = false),
        )
    }

    @Test
    fun g5_a_user_pause_forbids_green() {
        val paused = tripletOf(
            n = 10L, confirmedCount = 10L, lastSuccessAt = 1L,
            pausedByUser = true,
        )
        assertFalse(
            "G5：传输被用户按停时不许用绿色宣布完成",
            heroNumberIsSafe(MediaAccess.FULL, paused, pairingLost = false),
        )
    }

    @Test
    fun the_healthy_state_is_still_green_and_still_renders_the_fraction() {
        // 正常态不许改坏：权限完整 / 无失败 / 未暂停 / m == n → 绿 + 分数。
        val t = healthy()
        assertTrue(heroNumberIsSafe(MediaAccess.FULL, t, pairingLost = false))
        assertEquals(HeroRender.Triplet, heroRenderOf(MediaAccess.FULL, t))
        assertEquals(10L, t.m)
        assertEquals(10L, t.n)
        assertTrue(
            allSafeTextAllowed(
                MediaAccess.FULL, t, pairingLost = false,
                missingSourceCount = 0,
            ),
        )
    }

    // ── 规则 H：主位四选一 ──

    @Test
    fun h_c_renders_no_fraction_when_the_two_counts_disagree() {
        // 账本说 51 张已确认、相册里只有 10 张 —— 两个数对不上。
        val drifted = tripletOf(n = 10L, confirmedCount = 51L, lastSuccessAt = 1L)

        assertEquals(
            "clamp 后的 m 看不见这件事，判据必须读 clamp 前的 confirmedRaw",
            HeroRender.Unreconciled,
            heroRenderOf(MediaAccess.FULL, drifted),
        )
        assertEquals("clamp 仍在（不许回到「51 / 10」那种假话）", 10L, drifted.m)
        assertEquals(51L, drifted.confirmedRaw)
    }

    @Test
    fun h_a_and_h_b_keep_their_existing_branches() {
        assertEquals(HeroRender.AccessBlocked, heroRenderOf(MediaAccess.NONE, healthy()))
        assertEquals(HeroRender.AccessBlocked, heroRenderOf(MediaAccess.PARTIAL, healthy()))
        assertEquals(HeroRender.Unreadable, heroRenderOf(MediaAccess.FULL, null))
    }

    // ── 规则 S：状态行 ──

    @Test
    fun rule_s_blocks_all_safe_text_on_every_gate_and_on_both_skip_notices() {
        val t = healthy()
        assertFalse(
            "S1（G3）：配对已失效时不许说「照片都存好了」",
            allSafeTextAllowed(MediaAccess.FULL, t, true, 0),
        )
        assertFalse(
            "S2：有「已跳过 N 张…不会再重传」时不许同屏说都存好了",
            allSafeTextAllowed(MediaAccess.FULL, t, false, 1),
        )
        // #418：S3 改读三元组里「范围内用户取消过的张数」（取消轮已删除）。
        // 反证：allSafeTextAllowed 去掉 skippedByUser 条件 → 这条为 true，红。
        assertFalse(
            "S3：范围内有用户取消过（SKIPPED_BY_USER）的照片时不许说都存好了",
            allSafeTextAllowed(MediaAccess.FULL, t.copy(skippedByUser = 3), false, 0),
        )
    }

    @Test
    fun rule_s_also_blocks_all_safe_text_while_the_two_counts_disagree() {
        // 可达且最普通的漂移场景：备份成功后用户把照片从手机相册删掉
        // （终态 CONFIRMED 不会被改写成 SKIPPED_SOURCE_MISSING）——账本 51 项
        // 全部已确认、相册只剩 10 张。主位走 H-C 说「两个数对不上」，此时
        // 状态行不许在它正下方说「照片都存好了」（L0 压过一切完成度结论）。
        val drifted = tripletOf(n = 10L, confirmedCount = 51L, lastSuccessAt = 1L)

        assertEquals(HeroRender.Unreconciled, heroRenderOf(MediaAccess.FULL, drifted))
        assertFalse(
            "H-C 与「照片都存好了」不许同屏",
            allSafeTextAllowed(MediaAccess.FULL, drifted, false, 0),
        )
    }

    // ── 两次真机组合（回归用例：刻意同时触发多条闸门） ──

    @Test
    fun real_device_combo_1_pairing_lost_plus_one_failed_item_shows_no_green_completion() {
        // 真机：「配对已失效」红卡 + 绿字「10 / 10 张已回家」，且有 1 张失败。
        val t = tripletOf(
            n = 10L, confirmedCount = 10L, lastSuccessAt = 1L,
            hasFailedNeedsUser = true,
        )
        assertFalse(heroNumberIsSafe(MediaAccess.FULL, t, pairingLost = true))
        assertFalse(allSafeTextAllowed(MediaAccess.FULL, t, true, 0))
    }

    @Test
    fun real_device_combo_2_paused_with_four_pending_shows_no_green_completion() {
        // 真机：绿字「23 / 23 张已回家」，实有 4 张待传、传输被按停。
        // m == n，clamp 是恒等变换——堵它的是 G5，不是 clamp。
        val t = tripletOf(
            n = 23L, confirmedCount = 23L, lastSuccessAt = 1L,
            pausedByUser = true,
        )
        assertFalse(heroNumberIsSafe(MediaAccess.FULL, t, pairingLost = false))
        assertFalse(allSafeTextAllowed(MediaAccess.FULL, t, false, 0))
    }

    // ── 生产链路门禁（源文本：证明判据真的接进了渲染） ──

    @Test
    fun the_hero_number_is_not_hardcoded_green_anymore() {
        val source = homeScreen()
        assertFalse(
            "英雄卡主数字不许无条件用 PPColor.Safe——绿色必须过规则 G 的五条闸门",
            source.contains("fontSize = 40.sp, fontFamily = PPFont.Serif,\n                            color = PPColor.Safe,"),
        )
        assertTrue(
            "颜色必须由规则 G 的裁决函数决定",
            source.contains("if (heroNumberIsSafe(mediaAccess, t, pairingLost)) PPColor.Safe else"),
        )
    }

    @Test
    fun the_render_branch_and_the_status_line_are_both_wired_to_the_pure_decisions() {
        val source = homeScreen()
        assertTrue(
            "主位必须走规则 H 的裁决，而不是只判 triplet != null",
            source.contains("val heroRender = heroRenderOf(mediaAccess, t)"),
        )
        assertTrue(
            "H-C 分支必须在场（两个数对不上时的第三种渲染）",
            source.contains("heroRender == HeroRender.Unreconciled") &&
                source.contains("R.string.hero_unreconciled_title"),
        )
        assertTrue(
            "状态行必须过规则 S 的闸门",
            source.contains("allSafeTextAllowed("),
        )

        // H-C 分支体内不许出现任何 m/n 分数（groupThousands / hero_of_n）。
        val branch = source.substringAfter("heroRender == HeroRender.Unreconciled")
            .substringBefore("DOG-01d")
        assertFalse(
            "H-C 分支不许渲染任何 m/n 分数",
            branch.contains("groupThousands") || branch.contains("hero_of_n"),
        )
        assertFalse("H-C 分支不许用 PPColor.Safe", branch.contains("PPColor.Safe"))
    }
}
