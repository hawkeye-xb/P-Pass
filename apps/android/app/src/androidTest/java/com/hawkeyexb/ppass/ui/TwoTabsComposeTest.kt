package com.hawkeyexb.ppass.ui

import android.content.res.Configuration
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.hawkeyexb.ppass.R
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * #2113：Android 底部导航 Tab 真实渲染行为与无障碍回归测试（Compose UI E2）。
 * 验证：
 * 1. 移除选中 Tab 顶部的 2.dp PPColor.Ink 横杠指示器；
 * 2. 选中/未选中态文字颜色与字重切换（Ink+Bold vs Ink40+Medium）；
 * 3. 照片与备份图标在选中/未选中态渲染形态明显变化（实心/加粗强调 vs 线框）；
 * 4. settingsAlert 红点角标显隐与 Tab 读屏角色/选中语义保持正常。
 */
@RunWith(AndroidJUnit4::class)
class TwoTabsComposeTest {

    @get:Rule
    val compose = createComposeRule()

    private val ctx get() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun renderedTextStyle(node: SemanticsNodeInteraction) = run {
        val layouts = mutableListOf<TextLayoutResult>()
        val action = node.fetchSemanticsNode().config[SemanticsActions.GetTextLayoutResult]
        assertTrue("文本节点应提供 GetTextLayoutResult 语义", action.action?.invoke(layouts) == true)
        layouts.first().layoutInput.style
    }

    private fun colorsClose(a: Color, b: Color, tolerance: Float = 0.08f): Boolean =
        abs(a.red - b.red) <= tolerance &&
            abs(a.green - b.green) <= tolerance &&
            abs(a.blue - b.blue) <= tolerance &&
            abs(a.alpha - b.alpha) <= tolerance

    private fun countNonBackgroundPixels(node: SemanticsNodeInteraction): Int {
        val pixels = node.captureToImage().toPixelMap()
        var count = 0
        for (y in 0 until pixels.height) {
            for (x in 0 until pixels.width) {
                if (!colorsClose(pixels[x, y], PPColor.Paper, tolerance = 0.06f)) {
                    count++
                }
            }
        }
        return count
    }

    private fun countPixelsMatching(node: SemanticsNodeInteraction, target: Color): Int {
        val pixels = node.captureToImage().toPixelMap()
        var count = 0
        for (y in 0 until pixels.height) {
            for (x in 0 until pixels.width) {
                if (colorsClose(pixels[x, y], target)) {
                    count++
                }
            }
        }
        return count
    }

    private fun assertNoTopInkIndicatorBar(tabCellTag: String, density: Float) {
        val pixels = compose.onNodeWithTag(tabCellTag).captureToImage().toPixelMap()
        val topStripHeight = max(2, (2f * density).toInt())
        var darkPixelsInTopStrip = 0
        for (y in 0 until topStripHeight.coerceAtMost(pixels.height)) {
            for (x in 0 until pixels.width) {
                if (colorsClose(pixels[x, y], PPColor.Ink, tolerance = 0.12f)) {
                    darkPixelsInTopStrip++
                }
            }
        }
        assertEquals(
            "选中态 $tabCellTag 顶部 2dp 内不得出现 PPColor.Ink 横杠（实际深色像素=$darkPixelsInTopStrip）",
            0,
            darkPixelsInTopStrip,
        )
    }

    private fun assertTabSelectionVisualsAndSemantics(locale: Locale) {
        val densityPxPerDp = 2.8125f
        val cfg = Configuration(ctx.resources.configuration).apply { setLocale(locale) }
        val locCtx = ctx.createConfigurationContext(cfg)
        var currentTab by mutableIntStateOf(0)
        var settingsAlert by mutableStateOf(false)
        var showTabBar by mutableStateOf(true)

        compose.setContent {
            CompositionLocalProvider(
                LocalContext provides locCtx,
                LocalConfiguration provides cfg,
                LocalDensity provides Density(density = densityPxPerDp, fontScale = 1.0f),
            ) {
                PPTheme {
                    Box(Modifier.width(390.dp).height(640.dp)) {
                        TwoTabs(
                            tab = currentTab,
                            onTab = { currentTab = it },
                            photos = { Text("photos-pane") },
                            backup = { Text("backup-pane") },
                            showTabBar = showTabBar,
                            settingsAlert = settingsAlert,
                        )
                    }
                }
            }
        }

        val photosLabel = locCtx.getString(R.string.tab_photos)
        val settingsLabel = locCtx.getString(R.string.tab_settings)
        val tabRoleMatcher = SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Tab)

        // 1. 初始状态：照片选中、备份未选中，无红点角标
        compose.onNodeWithText("photos-pane").assertIsDisplayed()
        compose.onNodeWithTag("tab_cell_photos")
            .assertIsDisplayed()
            .assertHeightIsAtLeast(48.dp)
            .assert(tabRoleMatcher)
            .assertIsSelected()
        compose.onNodeWithTag("tab_cell_settings")
            .assertIsDisplayed()
            .assertHeightIsAtLeast(48.dp)
            .assert(tabRoleMatcher)
            .assertIsNotSelected()
        compose.onAllNodesWithTag("tab_alert_badge", useUnmergedTree = true).assertCountEquals(0)

        val photosLabelSelectedStyle = renderedTextStyle(compose.onNodeWithText(photosLabel, useUnmergedTree = true))
        val settingsLabelUnselectedStyle = renderedTextStyle(compose.onNodeWithText(settingsLabel, useUnmergedTree = true))
        assertEquals("($locale) 选中「照片」文字须为 PPColor.Ink", PPColor.Ink, photosLabelSelectedStyle.color)
        assertEquals("($locale) 选中「照片」字重须为 Bold", FontWeight.Bold, photosLabelSelectedStyle.fontWeight)
        assertEquals("($locale) 未选中「备份」文字须为 PPColor.Ink40", PPColor.Ink40, settingsLabelUnselectedStyle.color)
        assertEquals("($locale) 未选中「备份」字重须为 Medium", FontWeight.Medium, settingsLabelUnselectedStyle.fontWeight)

        assertNoTopInkIndicatorBar("tab_cell_photos", densityPxPerDp)
        val photosSelectedFg = countNonBackgroundPixels(compose.onNodeWithTag("tab_icon_photos", useUnmergedTree = true))
        val photosSelectedInk = countPixelsMatching(compose.onNodeWithTag("tab_icon_photos", useUnmergedTree = true), PPColor.Ink)
        val backupUnselectedFg = countNonBackgroundPixels(compose.onNodeWithTag("tab_icon_settings", useUnmergedTree = true))
        val backupUnselectedInk40 = countPixelsMatching(compose.onNodeWithTag("tab_icon_settings", useUnmergedTree = true), PPColor.Ink40)
        assertTrue("($locale) 选中照片图标须渲染主色 Ink 实心区域", photosSelectedInk > 0)
        assertTrue("($locale) 未选中备份图标须渲染次要色 Ink40 线框", backupUnselectedInk40 > 0)

        // 2. 点击切换到「备份」Tab
        compose.onNodeWithTag("tab_cell_settings").performClick()
        compose.waitForIdle()
        assertEquals(1, currentTab)
        compose.onNodeWithText("backup-pane").assertIsDisplayed()
        compose.onNodeWithTag("tab_cell_photos").assertIsNotSelected()
        compose.onNodeWithTag("tab_cell_settings").assertIsSelected()

        val photosLabelUnselectedStyle = renderedTextStyle(compose.onNodeWithText(photosLabel, useUnmergedTree = true))
        val settingsLabelSelectedStyle = renderedTextStyle(compose.onNodeWithText(settingsLabel, useUnmergedTree = true))
        assertEquals("($locale) 未选中「照片」文字须切为 PPColor.Ink40", PPColor.Ink40, photosLabelUnselectedStyle.color)
        assertEquals("($locale) 未选中「照片」字重须切为 Medium", FontWeight.Medium, photosLabelUnselectedStyle.fontWeight)
        assertEquals("($locale) 选中「备份」文字须切为 PPColor.Ink", PPColor.Ink, settingsLabelSelectedStyle.color)
        assertEquals("($locale) 选中「备份」字重须切为 Bold", FontWeight.Bold, settingsLabelSelectedStyle.fontWeight)

        assertNoTopInkIndicatorBar("tab_cell_settings", densityPxPerDp)
        val photosUnselectedFg = countNonBackgroundPixels(compose.onNodeWithTag("tab_icon_photos", useUnmergedTree = true))
        val photosUnselectedInk = countPixelsMatching(compose.onNodeWithTag("tab_icon_photos", useUnmergedTree = true), PPColor.Ink)
        val backupSelectedFg = countNonBackgroundPixels(compose.onNodeWithTag("tab_icon_settings", useUnmergedTree = true))
        val backupSelectedInk = countPixelsMatching(compose.onNodeWithTag("tab_icon_settings", useUnmergedTree = true), PPColor.Ink)

        assertTrue(
            "($locale) 照片图标选中实心像素($photosSelectedFg)必须明显多于未选中线框($photosUnselectedFg)",
            photosSelectedFg > photosUnselectedFg * 1.15,
        )
        assertEquals("($locale) 未选中照片图标不得再使用主色 Ink 渲染", 0, photosUnselectedInk)
        assertTrue(
            "($locale) 备份图标选中加粗实心箭头像素($backupSelectedFg)必须多于未选中轻态线框($backupUnselectedFg)",
            backupSelectedFg > backupUnselectedFg,
        )
        assertTrue("($locale) 选中备份图标须渲染主色 Ink", backupSelectedInk > 0)

        // 3. 开启 settingsAlert 红点角标，角标显示且不破坏 Tab 语义与配色
        compose.runOnIdle { settingsAlert = true }
        compose.waitForIdle()
        val badgeNode = compose.onNodeWithTag("tab_alert_badge", useUnmergedTree = true).assertIsDisplayed()
        assertTrue("($locale) settingsAlert 红点角标须使用 PPColor.Act 渲染", countPixelsMatching(badgeNode, PPColor.Act) > 0)
        compose.onNodeWithTag("tab_cell_settings").assert(tabRoleMatcher).assertIsSelected()

        // 4. 隐藏底部栏（查看大图/二级页场景）
        compose.runOnIdle { showTabBar = false }
        compose.waitForIdle()
        compose.onAllNodesWithTag("two_tabs_bar").assertCountEquals(0)
        compose.onAllNodesWithTag("tab_cell_photos").assertCountEquals(0)
        compose.onAllNodesWithTag("tab_cell_settings").assertCountEquals(0)
    }

    @Test
    fun bottom_tabs_use_morphology_and_color_without_top_bar_en() {
        assertTabSelectionVisualsAndSemantics(Locale.US)
    }

    @Test
    fun bottom_tabs_use_morphology_and_color_without_top_bar_zh() {
        assertTabSelectionVisualsAndSemantics(Locale.SIMPLIFIED_CHINESE)
    }
}
