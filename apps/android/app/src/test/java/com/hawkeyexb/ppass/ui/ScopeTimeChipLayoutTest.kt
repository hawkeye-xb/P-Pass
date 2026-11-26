package com.hawkeyexb.ppass.ui

import java.io.File
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1886 / #2067：
 * - 照片页继续使用可换行 `FlowRow` + `PhotoFilterChip`（`heightIn(min = 36.dp)` + `zIndex(1f)`）；
 * - 备份范围页顶部时间范围改用极轻区块标签（`scope_time_section`）+ 原生 M3 `SingleChoiceSegmentedButtonRow`，
 *   与照片页筛选条彻底区分，并通过 `IntrinsicSize.Min` + `fillMaxHeight()` + 2 行换行在大字号下自适应防裁切。
 */
class ScopeTimeChipLayoutTest {

    private fun source(rel: String): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/$rel").readText()
    }

    /** 范围页已改用原生二选一分段控件 + 区块标签，彻底脱离 PhotoFilterChip / FlowRow。 */
    @Test
    fun bucket_screen_uses_native_segmented_control_with_section_label_and_adaptive_height() {
        val bucket = source("BucketScreen.kt")
        assertTrue("必须加极轻时间区块标签", bucket.contains("R.string.scope_time_section"))
        assertTrue("时间范围改用原生 SingleChoiceSegmentedButtonRow", bucket.contains("SingleChoiceSegmentedButtonRow("))
        assertFalse("范围页不再使用照片页的 PhotoFilterChip", bucket.contains("PhotoFilterChip"))
        assertFalse("范围页不再使用 FlowRow 摆时间胶囊", bucket.contains("FlowRow("))

        val rowHeader = bucket.substringAfter("SingleChoiceSegmentedButtonRow(").substringBefore("{")
        assertTrue("分段控件行必须铺满宽", rowHeader.contains(".fillMaxWidth()"))
        assertTrue("分段控件行必须同步两段最小固有高度以兼容大字号换行", rowHeader.contains(".height(IntrinsicSize.Min)"))
        assertTrue("分段控件必须抬到滚动列表之上防触控框遮挡", rowHeader.contains(".zIndex(1f)"))
        assertTrue("承载网格的 Box 必须 clipToBounds()", bucket.contains("Box(Modifier.weight(1f).clipToBounds())"))

        val segBody = segmentedRowLambdaBody(bucket)
        assertTrue("第一段必须是 SINCE_TODAY", segBody.contains("ScopeTime.SINCE_TODAY"))
        assertTrue("第二段必须是 ALL", segBody.contains("ScopeTime.ALL"))
        assertTrue("分段必须撑满行高且保证 48dp 最小触控高度", segBody.contains(".fillMaxHeight()") && segBody.contains("heightIn(min = 48.dp)"))
        assertTrue("大字号下标签必须允许换行防截断", segBody.contains("maxLines = 2") && segBody.contains("softWrap = true"))
    }

    /** 反证：把照片页胶囊高度改回固定 height(36.dp) 本条即红。 */
    @Test
    fun chip_height_is_a_minimum_not_a_fixed_height() {
        val photos = source("PhotosScreen.kt")
        assertTrue("胶囊必须只有最小高度", photos.contains("heightIn(min = 36.dp)"))
        assertFalse("写死固定高度会让换行后的标签被裁掉", photos.contains("Modifier.height(36.dp)"))
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
     * 可点卡片会把自己的虚拟触控框外扩 24dp，遮住上面的控件。
     */
    @Test
    fun scrolled_card_touch_bounds_would_clip_chip_to_32dp_without_stacking() {
        val pxPerDp = 450.0 / 160.0 // 2.8125
        val chipTopPx = 317.0
        val chipBottomPx = 452.0
        val gridViewportTopPx = 474.0
        val cardTouchExpansionPx = 24.0 * pxPerDp
        val cardTouchTopPx = gridViewportTopPx - cardTouchExpansionPx
        assertEquals("顶边残片触控框上边 = 474 − 24dp", 406.5, cardTouchTopPx, 0.01)

        val clippedHeightPx = cardTouchTopPx - chipTopPx
        val clippedHeightDp = clippedHeightPx / pxPerDp
        assertTrue(
            "被遮挡后触控区只剩 ~32dp（实测 ${"%.1f".format(clippedHeightDp)}dp）",
            abs(clippedHeightDp - 32.0) <= 0.5,
        )
        assertTrue("32dp 低于 48dp 无障碍下限", clippedHeightDp < 48.0)
        assertEquals("完整触控区仍是 48dp", 135.0, chipBottomPx - chipTopPx, 0.01)
    }

    /** 反证：删掉照片页 `FlowRow(` 头部的 `Modifier.zIndex(1f)`，本条即红。 */
    @Test
    fun photos_filter_row_is_stacked_above_the_scrolling_grid() {
        val photos = source("PhotosScreen.kt")
        assertTrue(
            "照片页筛选 FlowRow 同样要抬到网格之上：${flowRowHeader(photos)}",
            flowRowHeader(photos).contains(".zIndex(1f)"),
        )
        assertTrue("胶囊仍要保留最小高度", photos.contains("heightIn(min = 36.dp)"))
    }

    private fun segmentedRowLambdaBody(source: String): String {
        val call = source.indexOf("SingleChoiceSegmentedButtonRow(")
        require(call >= 0) { "源码里找不到 SingleChoiceSegmentedButtonRow(" }
        val open = source.indexOf('{', call)
        require(open >= 0) { "SingleChoiceSegmentedButtonRow 没有 lambda" }
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
        error("SingleChoiceSegmentedButtonRow 的 lambda 没有闭合")
    }

    private fun flowRowHeader(source: String): String {
        val call = source.indexOf("FlowRow(")
        require(call >= 0) { "源码里找不到 FlowRow(" }
        val open = source.indexOf('{', call)
        require(open >= 0) { "FlowRow 没有 lambda" }
        return source.substring(call, open)
    }

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
