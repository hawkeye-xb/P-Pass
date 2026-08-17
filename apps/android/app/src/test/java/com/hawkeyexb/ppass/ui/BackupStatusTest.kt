package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R
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
        // Pending 映射到 state_pending——它的真实中文文案不得含「都存好了」。
        val pending = zh.getValue("state_pending")
        assertFalse("state_pending 文案说了假话: $pending", pending.contains("都存好了"))
        assertTrue("state_pending 应说明欠账: $pending", pending.contains("待备份"))
        // 「都存好了」只允许住在 state_safe 里（AllSafe 裁决独占）。
        val offenders = zh.filterValues { it.contains("都存好了") }.keys
        assertEquals("「都存好了」只允许出现在 state_safe: $offenders", setOf("state_safe"), offenders)
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

    // ── timingSummaryKey：设计稿"什么时候备份"cell 的四组合短句判定
    //    （跟 policySentenceKey 同一份逻辑，只是短句形式，各自独立测）──
    @Test
    fun timing_summary_both_when_charge_and_wifi() {
        assertEquals(R.string.timing_summary_both, timingSummaryKey(chargeOnly = true, wifiOnly = true))
    }

    @Test
    fun timing_summary_charge_only_when_only_charging() {
        assertEquals(
            R.string.timing_summary_charge_only,
            timingSummaryKey(chargeOnly = true, wifiOnly = false),
        )
    }

    @Test
    fun timing_summary_wifi_only_when_only_wifi() {
        assertEquals(
            R.string.timing_summary_wifi_only,
            timingSummaryKey(chargeOnly = false, wifiOnly = true),
        )
    }

    @Test
    fun timing_summary_none_when_neither_required() {
        assertEquals(R.string.timing_summary_none, timingSummaryKey(chargeOnly = false, wifiOnly = false))
    }

    // ── 工具：解析真实 values-zh/strings.xml（同 StringsSymmetryTest 手法）──

    private fun zhStrings(): Map<String, String> {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found above ${System.getProperty("user.dir")}")
        }
        val xml = File(dir, "apps/android/app/src/main/res/values-zh/strings.xml")
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(xml)
        val nodes = doc.getElementsByTagName("string")
        val result = LinkedHashMap<String, String>()
        for (i in 0 until nodes.length) {
            val el = nodes.item(i) as Element
            result[el.getAttribute("name")] = el.textContent?.trim().orEmpty()
        }
        return result
    }
}
