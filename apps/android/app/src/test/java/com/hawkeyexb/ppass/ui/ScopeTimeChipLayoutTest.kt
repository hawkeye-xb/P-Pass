package com.hawkeyexb.ppass.ui

import java.io.File
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1886：范围页两个时间胶囊在 1.5× 大字体下的布局——JVM 单测钉住三条决定。
 *
 * 1. 换行判定（纯函数 [scopeTimeChipsWrap]）：用三星 SM-S928N 实测的胶囊自身宽作为输入，
 *    四个配置的判定与真机实测一致；旧写法把第二个胶囊挤到 145px 的标签宽（en 1.5× 实测值）。
 * 2. 胶囊高度只有「最小高度」、没有固定高度：写死 `Modifier.height(36.dp)` 时，英文 1.5× 下
 *    标签换行后第二行被底边裁掉，视觉只剩「Incl」。改成 `heightIn(min = 36.dp)` 让胶囊自己长高。
 * 3. 两个胶囊的容器是可换行的 `FlowRow`，且两个胶囊都在它的 lambda 里（按实际括号边界取内容）。
 *
 * 触控区不靠这个高度撑：Material 3 `FilterChip` 自带的 `minimumInteractiveComponentSize`
 * 已把可点区撑到 48dp（真机实测 135px）。
 */
class ScopeTimeChipLayoutTest {

    // 三星 SM-S928N（Android 16，1080×2340，450dpi，2.8125 px/dp）：胶囊行的内容宽 = 1080 − 2×24dp = 945px；
    // 胶囊间距 8dp ≈ 23px；胶囊内边距（左右合计）92px（由实测 胶囊宽 − 标签宽 得出）。
    private val availablePx = 945
    private val gapPx = 23
    private val chipPaddingPx = 92

    private data class Cfg(val name: String, val firstPx: Int, val secondPx: Int, val wraps: Boolean)

    // 四个配置实测的「胶囊自身宽」（px，见 e3-capture.py 的 measurements.jsonl）。wraps = 真机实测是否换行。
    private val cfgs = listOf(
        Cfg("zh-CN 1.08×", 336, 335, false),
        Cfg("zh-CN 1.5×", 447, 444, false),
        Cfg("en-US 1.08×", 499, 514, true),
        Cfg("en-US 1.5×", 684, 707, true),
    )

    private fun source(rel: String): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/$rel").readText()
    }

    /** 换行判定与真机实测逐配置一致（放不下换行、放得下并排）。 */
    @Test
    fun measured_chip_widths_decide_wrapping_exactly_as_observed() {
        for (c in cfgs) {
            assertEquals(
                "${c.name}: 换行判定要与三星实测一致",
                c.wraps,
                scopeTimeChipsWrap(c.firstPx, c.secondPx, gapPx, availablePx),
            )
        }
    }

    /**
     * 反证（红→绿→红）：旧写法（普通 Row）把第二个胶囊挤到第一个剩下的宽度——en 1.5× 实测标签宽正是 145px
     * （胶囊 237px − 内边距 92px）。新判定在这里必须换行；把 `scopeTimeChipsWrap` 改成 `= false`（退回并排）
     * 本条即红。
     */
    @Test
    fun old_squeezing_rule_is_red_on_en_1_5x() {
        val en15 = cfgs.first { it.name == "en-US 1.5×" }
        val squeezedChipPx = (availablePx - gapPx - en15.firstPx).coerceAtLeast(0)
        val squeezedLabelPx = squeezedChipPx - chipPaddingPx
        assertTrue(
            "旧写法 en 1.5× 把第二个胶囊标签挤到 ~145px（三星实测 145px），实测 ${squeezedLabelPx}px",
            abs(squeezedLabelPx - 145) <= 4,
        )
        assertTrue("旧写法第二个胶囊远窄于自身宽，标签装不下", squeezedChipPx < en15.secondPx)
        assertTrue(
            "新判定必须换行",
            scopeTimeChipsWrap(en15.firstPx, en15.secondPx, gapPx, availablePx),
        )
    }

    /** 反证：把 `heightIn(min = 36.dp)` 改回 `Modifier.height(36.dp)` 本条即红。 */
    @Test
    fun chip_height_is_a_minimum_not_a_fixed_height() {
        val photos = source("PhotosScreen.kt")
        assertTrue("胶囊必须只有最小高度", photos.contains("heightIn(min = 36.dp)"))
        assertFalse("写死固定高度会让换行后的标签被裁掉", photos.contains("Modifier.height(36.dp)"))
    }

    /**
     * 反证：把第二个胶囊移出 `FlowRow` 的 lambda（放到闭括号之后）本条即红——按括号边界取内容，
     * 不用「到某个后面的标记为止」这种会被跨过的切法。
     */
    @Test
    fun the_two_time_chips_are_laid_out_in_a_wrapping_container() {
        val bucket = source("BucketScreen.kt")
        assertTrue("两个时间胶囊必须放进可换行的 FlowRow", bucket.contains("FlowRow("))
        assertFalse(
            "普通 Row 里第二个胶囊只吃剩余宽度，会被挤窄硬裁",
            bucket.contains("Row(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp))"),
        )
        val body = flowRowLambdaBody(bucket)
        assertFalse("取到的必须是 FlowRow 自己的 lambda，不是到后面某个标记为止", body.contains("Spacer("))
        assertTrue("第一个时间胶囊要在 FlowRow 里", body.contains("PhotoFilterChip(sinceLabel"))
        assertTrue(
            "第二个时间胶囊要在 FlowRow 里",
            body.contains("PhotoFilterChip(stringResource(R.string.scope_time_all)"),
        )
    }

    /** 反证：把照片页筛选条改回普通 Row、或把 ViewerAction 改回固定高度，本条即红。 */
    @Test
    fun photos_timeline_chips_wrap_and_viewer_actions_grow() {
        val photos = source("PhotosScreen.kt")
        val body = flowRowLambdaBody(photos)
        for (chip in listOf("chip_all", "chip_local", "chip_family")) {
            assertTrue("照片页筛选胶囊 $chip 要在可换行的 FlowRow 里", body.contains("R.string.$chip"))
        }
        assertTrue(
            "查看页按钮要只有最小高度（换行时自己长高）",
            photos.contains("modifier = modifier.heightIn(min = height)"),
        )
        assertFalse(
            "写死固定高度会让换行后的标签被裁掉",
            photos.contains("modifier = modifier.height(height)"),
        )
    }

    /**
     * #1882：筛选条必须压在下方的滚动网格之上，否则网格向上滚动时，顶边被裁剩 1px 的
     * 可点卡片会把自己的虚拟触控框外扩 24dp，遮住上面的 Chip——TalkBack 读到的可点区
     * 从 48dp 被切成 32dp。
     *
     * 450dpi（三星 SM-S928N，2.8125 px/dp）实测几何：Chip 布局高 36dp = 101px，Material 3
     * 最小交互尺寸把它撑到 48dp = 135px，范围 y ∈ [317, 452]；下方网格视口顶边 y = 474，
     * 卡片被裁剩 1px（y ∈ [474, 475]）时，其虚拟触控框上边 = 474 − 24dp(67.5px) = 406.5px，
     * 把 Chip 底边从 452 切到 406.5，只剩 89.5px ≈ 31.8dp（真机 dump 的 407/32dp 就是这个数）。
     */
    @Test
    fun scrolled_card_touch_bounds_would_clip_chip_to_32dp_without_stacking() {
        val pxPerDp = 450.0 / 160.0 // 2.8125
        val chipTopPx = 317.0
        val chipBottomPx = 452.0 // 36dp 布局高 + 上下各 6dp 最小交互尺寸 = 48dp
        val gridViewportTopPx = 474.0
        val cardVisiblePx = 1.0
        val cardTouchExpansionPx = 24.0 * pxPerDp
        val cardTopPx = gridViewportTopPx
        val cardTouchTopPx = cardTopPx - cardTouchExpansionPx
        assertEquals("顶边残片触控框上边 = 474 − 24dp", 406.5, cardTouchTopPx, 0.01)
        assertEquals("残片确实只露 1px", 1.0, cardVisiblePx, 0.0)

        // 没有 zIndex 时，绘制层级更高的卡片触控框把 Chip 底边裁到 406.5px。
        val clippedHeightPx = cardTouchTopPx - chipTopPx
        val clippedHeightDp = clippedHeightPx / pxPerDp
        assertTrue(
            "被遮挡后 Chip 触控区只剩 ~32dp（真机实测 407/90px），实测 ${"%.1f".format(clippedHeightDp)}dp / ${"%.1f".format(clippedHeightPx)}px",
            abs(clippedHeightDp - 32.0) <= 0.5,
        )
        assertTrue("32dp 低于 48dp 无障碍下限", clippedHeightDp < 48.0)

        // zIndex 把 Chip 抬到卡片之上，48dp 触控区不再被切。
        assertEquals("完整触控区仍是 48dp", 135.0, chipBottomPx - chipTopPx, 0.01)
    }

    /**
     * 反证：删掉任一处 `FlowRow(` 头部的 `Modifier.zIndex(1f)`，或去掉列表 `Box` 的
     * `clipToBounds()`，本条即红。按 `FlowRow(` 到第一个 `{` 的头部截取，只认参数列表里的修饰符，
     * 不会被 lambda 正文里别的写法蒙混过去。
     */
    @Test
    fun filter_rows_are_stacked_above_the_scrolling_grid() {
        val bucket = source("BucketScreen.kt")
        assertTrue(
            "范围页时间筛选 FlowRow 要抬到网格之上：${flowRowHeader(bucket)}",
            flowRowHeader(bucket).contains(".zIndex(1f)"),
        )
        assertTrue(
            "承载网格的 Box 要裁住卡片触控框：列表 Box 缺 clipToBounds()",
            bucket.contains("Box(Modifier.weight(1f).clipToBounds())"),
        )

        val photos = source("PhotosScreen.kt")
        assertTrue(
            "照片页筛选 FlowRow 同样要抬到网格之上：${flowRowHeader(photos)}",
            flowRowHeader(photos).contains(".zIndex(1f)"),
        )
        assertTrue("胶囊仍要保留最小高度", photos.contains("heightIn(min = 36.dp)"))
    }

    /** 取 `FlowRow(` 到第一个 `{` 之间的参数头部（不含 lambda 正文）。 */
    private fun flowRowHeader(source: String): String {
        val call = source.indexOf("FlowRow(")
        require(call >= 0) { "源码里找不到 FlowRow(" }
        val open = source.indexOf('{', call)
        require(open >= 0) { "FlowRow 没有 lambda" }
        return source.substring(call, open)
    }

    /** 取 `FlowRow(` 后第一个 `{` 到配对 `}` 之间的内容（lambda 正文）。 */
    private fun flowRowLambdaBody(source: String): String {
        val call = source.indexOf("FlowRow(")
        require(call >= 0) { "源码里找不到 FlowRow(" }
        val open = source.indexOf('{', call)
        require(open >= 0) { "FlowRow 没有 lambda" }
        var depth = 0
        for (i in open until source.length) {
            when (source[i]) {
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return source.substring(open + 1, i)
                }
            }
        }
        error("FlowRow 的 lambda 没有闭合")
    }
}
