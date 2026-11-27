package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1881：设置页「备份范围」行「并排还是换行」判定的 JVM 单测。
 *
 * 输入取自三星 SM-S928N（Android 16，1080×2340，450dpi，2.8125 px/dp）实测，见共享笔记
 * `1881-settings-scope-row.md`：
 *
 *  | 配置        | 整行 | 内边距 | 摘要 | 箭头 | 间距 | 标签列 |
 *  | zh-CN 1.08× | 968  | 45     | 439  | 31   | 11   | 397    |
 *  | zh-CN 1.5×  | 968  | 45     | 639  | 40   | 11   | 188    |
 *  | en-US 1.08× | 968  | 45     | 470  | 31   | 11   | 366    |
 *  | en-US 1.5×  | 968  | 45     | 684  | 40   | 11   | 143    |
 *
 * 「标签列」= 整行 − 两内边距 − 摘要 − 箭头 − 间距，正是旧写法（标签 `weight(1f)` 吃剩余）
 * 下标签拿到的宽度。1.08× 时标签在该列里放得下（单行）；1.5× 时放不下（中文断成 2 行、
 * 英文断成 4 行 `Bac / kup / rang / e`）。所以判定比的是「标签单行宽 vs 标签列」，标签单行宽
 * 随字号线性放大。
 */
class CellRowLayoutTest {

    private val availablePx = 968 - 2 * 45 // 878：整行去掉左右各 45px 内边距

    private data class Config(
        val name: String,
        val summaryPx: Int,
        val chevronPx: Int,
        val spacerPx: Int,
        val labelColumnPx: Int,
        val labelIntrinsicPx: Int,
    )

    // 1.08× 的「标签单行宽」取该字号下的实测标签列——标签在该列里放得下，单行宽 ≤ 列宽，
    // 取列宽是这个方向的最紧上界。1.5× 的标签单行宽随字号线性放大（×1.5/1.08）；实测已断行，
    // 真实单行宽必大于列宽，放大值同样大于列宽。
    private val configs = listOf(
        Config("zh-CN 1.08×", 439, 31, 11, 397, 397),
        Config("zh-CN 1.5×", 639, 40, 11, 188, (397 * 1.5 / 1.08).toInt()),
        Config("en-US 1.08×", 470, 31, 11, 366, 366),
        Config("en-US 1.5×", 684, 40, 11, 143, (366 * 1.5 / 1.08).toInt()),
    )

    private fun decision(c: Config) =
        cellRowStacks(c.labelIntrinsicPx, c.summaryPx, availablePx, c.chevronPx + c.spacerPx)

    private fun homeScreenSource(): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(
            dir,
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt",
        ).readText()
    }

    /**
     * 反证（红→绿→红）：纯函数对了还不够——`CellRow` 必须真的调用它并按结果分支。把 `CellRow` 里的
     * `if (stacked)` 改回永远并排（真正的撤销），本条即红；只把纯函数改成 `= false` 则由上面
     * [label_that_does_not_fit_its_column_stacks] 抓住。两条一起钉住「判定存在」且「被调用」。
     */
    @Test
    fun cell_row_actually_branches_on_the_decision() {
        val source = homeScreenSource()
        assertTrue("CellRow 必须调用 cellRowStacks 判定", source.contains("cellRowStacks("))
        assertTrue("CellRow 必须按判定分支（并排 / 换行）", source.contains("if (stacked)"))
    }

    /** 几何自洽：标签列 = 可用宽 − 摘要 − 箭头 − 间距，与实测一致（证明四个输入取自同一组测量）。 */
    @Test
    fun measured_label_column_matches_the_row_geometry() {
        for (c in configs) {
            assertEquals(
                "${c.name}: 标签列必须等于 可用宽−摘要−箭头−间距",
                c.labelColumnPx,
                availablePx - c.summaryPx - c.chevronPx - c.spacerPx,
            )
        }
    }

    /** 判定契约：并排放得下（标签+摘要+末尾 ≤ 可用宽）判并排；超过一个像素就判换行。 */
    @Test
    fun decision_flips_exactly_at_the_available_width() {
        assertFalse("刚好放得下必须并排", cellRowStacks(436, 400, 878, 42)) // 878 == 878
        assertTrue("多一个像素就放不下，必须换行", cellRowStacks(437, 400, 878, 42)) // 879 > 878
    }

    /** 1.08×：标签在列里放得下 ⇒ 并排（不换行），与实测「标签单行」一致。 */
    @Test
    fun label_that_fits_its_column_stays_side_by_side() {
        for (c in configs.filter { it.name.endsWith("1.08×") }) {
            assertFalse("${c.name}: 放得下必须并排", decision(c))
        }
    }

    /** 1.5×：标签在列里放不下 ⇒ 换行（摘要下移），与实测「标签断成多行」一致。 */
    @Test
    fun label_that_does_not_fit_its_column_stacks() {
        for (c in configs.filter { it.name.endsWith("1.5×") }) {
            assertTrue("${c.name}: 放不下必须换行", decision(c))
        }
    }

    /**
     * 反证（红→绿→红）：旧写法「`Row` 里标签吃剩余、摘要永远并排」等价于判定恒为 false。
     * en-US 1.5× 实测标签列只有 143px，装不下 1.5× 的「Backup range」（已断成 4 行），
     * 新判定在这里给出「换行」，旧规则给出「并排」——两者必须相反，所以本条在旧规则上必红。
     * 把 `cellRowStacks` 改成 `= false`（退回旧行为）即可看到 [label_that_does_not_fit_its_column_stacks]
     * 与本条一起变红。
     */
    @Test
    fun old_always_side_by_side_rule_is_red_on_en_1_5x() {
        val en15 = configs.first { it.name == "en-US 1.5×" }
        val oldRuleAlwaysSideBySide = false
        val newDecision = decision(en15)
        assertTrue("en-US 1.5× 必须判换行", newDecision)
        assertNotEquals("旧规则永远并排，与新判定相反——旧行为在这组必红", newDecision, oldRuleAlwaysSideBySide)
    }

    /**
     * #2110：Material3 ListItem 实际有左右各 16dp（90px）与 TrailingContentStartPadding 16dp（45px），
     * 三星 384dp 屏（卡片 344dp = 968px，2.8125 px/dp）上真正留给 headline+trailing 内容的宽度是 833px
     * （旧误估 8dp 时为 855px）。
     *
     * 覆盖四类真实输入：
     * 1. 标准字号 1.08×「邮件反馈」+ ppass@hawkeye-xb.com（698px ≤ 833px）稳稳单行；
     * 2. 落在 (833, 855] 窗口的边界输入（335 + 468 + 42 = 845px）：旧 8dp 误判并排（断言红），
     *    当前 16dp 正确判堆叠（断言绿），把 HomeScreen.kt 改回 8dp 必回红；
     * 3. 1.5× 大字号（962px > 833px）切换为堆叠；
     * 4. 320dp 窄屏（卡片 280dp ≈ 787px，可用 652px < 698px）切换为堆叠。
     */
    @Test
    fun about_email_row_stays_single_line_at_standard_scale_and_stacks_when_tight() {
        val samsungDensity = 2.8125f
        val listItemAvailablePx = cellRowAvailableWidthPx(maxWidthPx = 968, density = samsungDensity, hasTrailing = true)
        assertEquals("三星 968px 卡片扣除 32dp 左右与 16dp 尾部前置间距后可用宽必须为 833px", 833, listItemAvailablePx)

        val emailAt108Px = 468
        val chevronAndGapAt108Px = 31 + 11
        val conciseLabelAt108Px = 188 // 「邮件反馈」（4 个汉字 @ 15sp × 1.08）

        assertFalse(
            "1.08× 标准字号下「邮件反馈」+ 邮箱（698px ≤ 833px）必须单行并排",
            cellRowStacks(conciseLabelAt108Px, emailAt108Px, listItemAvailablePx, chevronAndGapAt108Px),
        )

        val emailAt15Px = (emailAt108Px * 1.5 / 1.08).toInt()
        val conciseLabelAt15Px = (conciseLabelAt108Px * 1.5 / 1.08).toInt()
        val chevronAndGapAt15Px = 40 + 11
        assertTrue(
            "1.5× 大字号下「邮件反馈」+ 邮箱超出可用宽，必须切为堆叠",
            cellRowStacks(conciseLabelAt15Px, emailAt15Px, listItemAvailablePx, chevronAndGapAt15Px),
        )

        val narrow320CardPx = (280 * samsungDensity).toInt() // 320dp 屏扣 40dp 页边距 = 280dp ≈ 787px
        val narrowAvailablePx = cellRowAvailableWidthPx(maxWidthPx = narrow320CardPx, density = samsungDensity, hasTrailing = true)
        assertEquals("320dp 窄屏（280dp≈787px 卡片）扣除 32dp+16dp 后可用宽应为 652px", 652, narrowAvailablePx)
        assertTrue(
            "320dp 窄屏下「邮件反馈」+ 邮箱（698px > 652px）放不下，必须切为堆叠",
            cellRowStacks(conciseLabelAt108Px, emailAt108Px, narrowAvailablePx, chevronAndGapAt108Px),
        )
    }

    /**
     * #2110 基线反证（8dp → 16dp 宽裕量）：
     * 335 + 468 + 42 = 845px 落在 (833, 855] 区间——旧 8dp 误估下 available=855px 会错判并排（本条必红），
     * 当前 16dp 真实值下 available=833px 正确判堆叠（本条为绿）。
     */
    @Test
    fun boundary_between_8dp_and_16dp_trailing_padding_stacks() {
        val availablePx = cellRowAvailableWidthPx(maxWidthPx = 968, density = 2.8125f, hasTrailing = true)
        assertTrue(
            "845px 落在 (833, 855] 区间：按真实 16dp 尾部间距必须判堆叠（退回旧 8dp=855px 会误判并排并令本条回红）",
            cellRowStacks(labelWidthPx = 335, valueWidthPx = 468, availableWidthPx = availablePx, trailingWidthPx = 42),
        )
    }
}
