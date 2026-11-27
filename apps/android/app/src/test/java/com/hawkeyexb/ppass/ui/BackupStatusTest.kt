package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.BackupTriplet
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.flow.WaitReason
import com.hawkeyexb.ppass.backup.tripletOf
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * T-080: 状态条裁决逻辑（纯函数）——锁死两个真机确认过的缺陷：
 *  (a) 待备份 K > 0 时顶部状态不得出现「照片都存好了」类文案；
 *  (b) 从未成功备份（时间戳 <= 0）必须走「还没有成功备份过」，
 *      日期分支绝不接到 epoch 0（真机曾渲染「01-01 08:00」假话）。
 *
 * 裁决 → 文案的映射固定为：Pending → state_pending、AllSafe → state_safe、
 * Never → last_success_never（HomeScreen.statusText / lastSuccessText）。
 * 本测试同时解析真实 values-zh/strings.xml，把断言落到实际中文文案上，
 * 防止有人改字符串绕过裁决。
 */
class BackupStatusTest {

    // ── 缺陷 (a)：待备份 > 0 永不允许 AllSafe ──────────────────────

    @Test
    fun pending_over_zero_never_yields_all_safe() {
        // 刚跑完一轮成功（AllSafe 运行态），但三元组说还欠 54 张：
        val afterRun = statusLineOf(BackupUiState.AllSafe(ingested = 3, duplicates = 1), pendingK = 54)
        assertTrue("K>0 时必须是 Pending，实际: $afterRun", afterRun is StatusLine.Pending)
        assertEquals(54L, (afterRun as StatusLine.Pending).k)

        // 静止态（Idle）同样受 K 约束：
        val idle = statusLineOf(BackupUiState.Idle, pendingK = 1)
        assertTrue("Idle + K>0 时必须是 Pending，实际: $idle", idle is StatusLine.Pending)

        // 反向卫兵：K == 0 且确有成功运行 → 才允许 AllSafe。
        val clean = statusLineOf(BackupUiState.AllSafe(3, 0), pendingK = 0)
        assertTrue("K=0 + AllSafe 运行态应为 AllSafe，实际: $clean", clean is StatusLine.AllSafe)
    }

    @Test
    fun pending_copy_does_not_say_all_safe() {
        val zh = zhStrings()
        // Pending 映射到 state_pending——它的真实中文文案不得含「已全部备份」（10-29 定稿前是「都存好了」）。
        val pending = zh.getValue("state_pending")
        assertFalse("state_pending 文案说了假话: $pending", pending.contains("已全部备份"))
        assertTrue("state_pending 应说明欠账: $pending", pending.contains("待备份"))
        // 「已全部备份」只允许住在 state_safe 里（AllSafe 裁决独占）。
        val offenders = zh.filterValues { it.contains("已全部备份") }.keys
        assertEquals("「已全部备份」只允许出现在 state_safe: $offenders", setOf("state_safe"), offenders)
    }

    @Test
    fun working_and_trouble_outrank_pending() {
        // 进行中/失败的优先级高于欠账——进度和失败必须先说。
        assertTrue(statusLineOf(BackupUiState.Sending(2, 9), 54) is StatusLine.Working)
        assertTrue(statusLineOf(BackupUiState.Trouble("x"), 54) is StatusLine.Trouble)
    }

    // ── 缺陷 (b)：时间戳 0 = 从未成功，绝不渲染日期 ────────────────

    @Test
    fun epoch_zero_yields_never_not_a_date() {
        val now = 1_754_400_000_000L // 2026-08-05 前后，任意固定 now
        assertEquals(LastSuccess.Never, lastSuccessOf(0L, now))
        assertEquals(LastSuccess.Never, lastSuccessOf(-1L, now))
        // Never 对应的真实文案：
        val never = zhStrings().getValue("last_success_never")
        assertTrue("last_success_never 文案不对: $never", never.contains("还没有成功备份过"))
        // 日期分支（At）只有正时间戳才可达：
        val old = lastSuccessOf(now - 3 * 24 * 3600_000L, now)
        assertTrue(old is LastSuccess.At)
        assertTrue((old as LastSuccess.At).ts > 0)
    }

    @Test
    fun recent_timestamps_humanize() {
        val now = 1_754_400_000_000L
        assertEquals(LastSuccess.JustNow, lastSuccessOf(now - 30_000, now))
        assertEquals(LastSuccess.MinutesAgo(5), lastSuccessOf(now - 5 * 60_000, now))
        assertEquals(LastSuccess.HoursAgo(3), lastSuccessOf(now - 3 * 3600_000, now))
    }

    // ── 照片页轻过滤器（纯函数） ───────────────────────────────────

    @Test
    fun timeline_filter_partitions_by_confirmed_hashes() {
        val items = listOf("a", "b", "c")
        val mine = setOf("a", "c")
        assertEquals(items, filterTimeline(items, TimelineFilter.All, mine) { it })
        assertEquals(listOf("a", "c"), filterTimeline(items, TimelineFilter.LocalOnly, mine) { it })
        assertEquals(listOf("b"), filterTimeline(items, TimelineFilter.Family, mine) { it })
    }

    // ── #2082：英雄卡四档底色状态机 + 去重 + 备份 Tab / 分组标题文案 ──

    @Test
    fun hero_surface_tone_matrix_enforces_four_semantic_tones() {
        val done = tripletOf(n = 10L, confirmedCount = 10L, lastSuccessAt = 1L)
        val pending = tripletOf(n = 10L, confirmedCount = 4L, lastSuccessAt = 1L)
        val zero = tripletOf(n = 0L, confirmedCount = 0L, lastSuccessAt = 0L)
        val unreconciled = tripletOf(n = 10L, confirmedCount = 20L, lastSuccessAt = 1L)

        // !autoRule 一律 neutral
        assertEquals(HeroSurfaceTone.Neutral, heroSurfaceTone(false, HeroRender.AccessBlocked, false, BackupUiState.Idle, done, false, false))
        assertEquals(HeroSurfaceTone.Neutral, heroSurfaceTone(false, HeroRender.Triplet, false, BackupUiState.Waiting(WaitReason.WIFI), pending, false, false))
        assertEquals(HeroSurfaceTone.Neutral, heroSurfaceTone(false, HeroRender.Triplet, false, BackupUiState.AllSafe(10, 0), done, false, true))

        // act：权限阻断或混合相册不完整
        assertEquals(HeroSurfaceTone.Act, heroSurfaceTone(true, HeroRender.AccessBlocked, false, BackupUiState.Idle, done, false, false))
        assertEquals(HeroSurfaceTone.Act, heroSurfaceTone(true, HeroRender.Triplet, true, BackupUiState.Sending(1, 2, "a.jpg"), pending, false, false))

        // waiting：对账中 / 等待中 / 已暂停 / 进行中 / k > 0 / 版本等待
        assertEquals(HeroSurfaceTone.Waiting, heroSurfaceTone(true, HeroRender.Unreconciled, false, BackupUiState.Idle, unreconciled, false, false))
        assertEquals(HeroSurfaceTone.Waiting, heroSurfaceTone(true, HeroRender.Triplet, false, BackupUiState.Waiting(WaitReason.WIFI), done, false, true))
        assertEquals(HeroSurfaceTone.Waiting, heroSurfaceTone(true, HeroRender.Triplet, false, BackupUiState.Paused, done, false, false))
        assertEquals(HeroSurfaceTone.Waiting, heroSurfaceTone(true, HeroRender.Triplet, false, BackupUiState.Preparing, done, false, true))
        assertEquals(HeroSurfaceTone.Waiting, heroSurfaceTone(true, HeroRender.Triplet, false, BackupUiState.Sending(1, 2, "a.jpg"), done, false, true))
        assertEquals(HeroSurfaceTone.Waiting, heroSurfaceTone(true, HeroRender.Triplet, false, BackupUiState.Idle, pending, false, true))
        assertEquals(HeroSurfaceTone.Waiting, heroSurfaceTone(true, HeroRender.Triplet, false, BackupUiState.AllSafe(10, 0), done, false, true, hasWaitReason = true))

        // neutral：未选范围 / 计数不可读 / 读不出 / 从今天起空态 / 失败态 / allSafeAllowed == false
        assertEquals(HeroSurfaceTone.Neutral, heroSurfaceTone(true, HeroRender.NoAlbums, false, BackupUiState.NoAlbums, null, false, false))
        assertEquals(HeroSurfaceTone.Neutral, heroSurfaceTone(true, HeroRender.CountsUnreadable, false, BackupUiState.Idle, null, false, false))
        assertEquals(HeroSurfaceTone.Neutral, heroSurfaceTone(true, HeroRender.Unreadable, false, BackupUiState.Idle, null, false, false))
        assertEquals(HeroSurfaceTone.Neutral, heroSurfaceTone(true, HeroRender.Triplet, false, BackupUiState.Idle, zero, true, true))
        assertEquals(HeroSurfaceTone.Neutral, heroSurfaceTone(true, HeroRender.Triplet, false, BackupUiState.Trouble("err"), done, false, true))
        assertEquals(HeroSurfaceTone.Neutral, heroSurfaceTone(true, HeroRender.Triplet, false, BackupUiState.AllSafe(10, 0), done, false, false))

        // safe：仅 allSafeAllowed 且无等待/进行中/异常
        assertEquals(HeroSurfaceTone.Safe, heroSurfaceTone(true, HeroRender.Triplet, false, BackupUiState.AllSafe(10, 0), done, false, true))

        // 底色与分隔线 token 映射
        assertEquals(PPColor.ActBg, heroSurfaceBackground(HeroSurfaceTone.Act))
        assertEquals(PPColor.WaitingBg, heroSurfaceBackground(HeroSurfaceTone.Waiting))
        assertEquals(PPColor.Linen, heroSurfaceBackground(HeroSurfaceTone.Neutral))
        assertEquals(PPColor.SafeBg, heroSurfaceBackground(HeroSurfaceTone.Safe))
        assertEquals(PPColor.Hairline, heroSurfaceDivider(HeroSurfaceTone.Neutral))
    }

    @Test
    fun mobile_visual_hierarchy_copy_matches_both_languages_and_drops_pending_count() {
        val zh = stringsFor("values-zh")
        val en = stringsFor("values")
        assertFalse("pending_count 已移除以消除重复待备份拼接", zh.containsKey("pending_count"))
        assertFalse("pending_count 已移除以消除重复待备份拼接", en.containsKey("pending_count"))
        assertEquals("备份", zh["tab_settings"])
        assertEquals("Backup", en["tab_settings"])
        assertEquals("单次手动传", zh["settings_section_single_transfer"])
        assertEquals("Send once", en["settings_section_single_transfer"])
        assertEquals("偏好与更多", zh["settings_section_preferences"])
        assertEquals("Preferences", en["settings_section_preferences"])
        assertEquals("或先手动传几张", zh["decision_single_transfer_prompt"])
        assertEquals("Or send a few manually", en["decision_single_transfer_prompt"])
    }

    // ── 工具：解析真实 values{-zh,}/strings.xml（同 StringsSymmetryTest 手法）──

    private fun zhStrings(): Map<String, String> = stringsFor("values-zh")

    private fun stringsFor(localeDir: String): Map<String, String> {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found above ${System.getProperty("user.dir")}")
        }
        val xml = File(dir, "apps/android/app/src/main/res/$localeDir/strings.xml")
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(xml)
        val nodes = doc.getElementsByTagName("string")
        val result = LinkedHashMap<String, String>()
        for (i in 0 until nodes.length) {
            val el = nodes.item(i) as Element
            result[el.getAttribute("name")] = el.textContent?.trim().orEmpty()
        }
        // plurals（#418 回归起 state_pending 等带数量的文案是 plurals）：取 other 那一条参与同样的断言。
        val plurals = doc.getElementsByTagName("plurals")
        for (i in 0 until plurals.length) {
            val el = plurals.item(i) as Element
            val items = el.getElementsByTagName("item")
            for (j in 0 until items.length) {
                val item = items.item(j) as Element
                if (item.getAttribute("quantity") == "other") result[el.getAttribute("name")] = item.textContent?.trim().orEmpty()
            }
        }
        return result
    }
}
