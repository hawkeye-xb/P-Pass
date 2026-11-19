package com.hawkeyexb.ppass.ui

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
}
