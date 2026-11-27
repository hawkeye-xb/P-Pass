package com.hawkeyexb.ppass.ui

import android.content.res.Configuration
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.hawkeyexb.ppass.R
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * #2093：欢迎页视觉主次分层与中英文 / 1.5× 大字号布局交互回归测试（E2）。
 */
@RunWith(AndroidJUnit4::class)
class WelcomeScreenComposeTest {

    @get:Rule
    val compose = createComposeRule()

    private val ctx get() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun renderedTextStyle(node: SemanticsNodeInteraction) = run {
        val layouts = mutableListOf<TextLayoutResult>()
        val action = node.fetchSemanticsNode().config[SemanticsActions.GetTextLayoutResult]
        assertTrue("文本节点应提供 GetTextLayoutResult 语义", action.action?.invoke(layouts) == true)
        layouts.first().layoutInput.style
    }

    private fun assertWelcomeHierarchyAndClicks(locale: Locale) {
        val cfg = Configuration(ctx.resources.configuration).apply { setLocale(locale) }
        val locCtx = ctx.createConfigurationContext(cfg)
        var scanClicks = 0
        var manualClicks = 0
        var desktopClicks = 0

        compose.setContent {
            CompositionLocalProvider(
                LocalContext provides locCtx,
                LocalConfiguration provides cfg,
                LocalDensity provides Density(density = 2.8125f, fontScale = 1.0f),
            ) {
                PPTheme {
                    Box(Modifier.width(390.dp).height(844.dp)) {
                        WelcomeScreen(
                            onScan = { scanClicks++ },
                            onManual = { manualClicks++ },
                            onShareDesktopLink = { desktopClicks++ },
                        )
                    }
                }
            }
        }

        val scanText = locCtx.getString(R.string.welcome_scan)
        val manualText = locCtx.getString(R.string.scan_manual_link)
        val desktopText = locCtx.getString(R.string.welcome_desktop_link)

        compose.onNodeWithText(locCtx.getString(R.string.welcome_headline)).assertIsDisplayed()
        val scanNode = compose.onNodeWithText(scanText).assertIsDisplayed().assertHeightIsAtLeast(64.dp)
        val manualNode = compose.onNodeWithText(manualText).assertIsDisplayed().assertHeightIsAtLeast(48.dp)
        val desktopNode = compose.onNodeWithText(desktopText).assertIsDisplayed().assertHeightIsAtLeast(48.dp)

        val scanBounds = scanNode.getBoundsInRoot()
        val manualBounds = manualNode.getBoundsInRoot()
        val desktopBounds = desktopNode.getBoundsInRoot()

        val manualGap = manualBounds.top - scanBounds.bottom
        val footerGap = desktopBounds.top - manualBounds.bottom
        assertTrue("($locale) 无法扫码紧跟主按钮下方（实测间距 $manualGap）", manualGap >= 4.dp && manualGap <= 10.dp)
        assertTrue("($locale) 页脚链接与配对操作组留白必须明显大于操作组内间距", footerGap >= 28.dp && footerGap > manualGap * 2)
        assertTrue("($locale) 还没装电脑端应沉在页面底部（bottom=${desktopBounds.bottom}）", desktopBounds.bottom >= 760.dp)

        // 直接校验真实渲染 TextLayoutResult 的颜色与字重，避免只测静态常量而不测实际渲染
        val manualStyle = renderedTextStyle(manualNode)
        val desktopStyle = renderedTextStyle(desktopNode)
        assertEquals("($locale) 无法扫码真实渲染色须为 Ink60", PPColor.Ink60, manualStyle.color)
        assertEquals("($locale) 无法扫码真实字重须为 Bold", FontWeight.Bold, manualStyle.fontWeight)
        assertEquals("($locale) 还没装电脑端真实渲染色须弱化为 Ink40", PPColor.Ink40, desktopStyle.color)
        assertEquals("($locale) 还没装电脑端真实字重须降为 Normal", FontWeight.Normal, desktopStyle.fontWeight)

        scanNode.performClick()
        manualNode.performClick()
        desktopNode.performClick()
        assertEquals(1, scanClicks)
        assertEquals(1, manualClicks)
        assertEquals(1, desktopClicks)
    }

    private fun assertWelcomeScrollableAt15x(locale: Locale) {
        val cfg = Configuration(ctx.resources.configuration).apply { setLocale(locale) }
        val locCtx = ctx.createConfigurationContext(cfg)
        var scanClicks = 0
        var manualClicks = 0
        var desktopClicks = 0

        compose.setContent {
            CompositionLocalProvider(
                LocalContext provides locCtx,
                LocalConfiguration provides cfg,
                LocalDensity provides Density(density = 2.8125f, fontScale = 1.5f),
            ) {
                PPTheme {
                    Box(Modifier.width(360.dp).height(640.dp)) {
                        WelcomeScreen(
                            onScan = { scanClicks++ },
                            onManual = { manualClicks++ },
                            onShareDesktopLink = { desktopClicks++ },
                        )
                    }
                }
            }
        }

        val scanText = locCtx.getString(R.string.welcome_scan)
        val manualText = locCtx.getString(R.string.scan_manual_link)
        val desktopText = locCtx.getString(R.string.welcome_desktop_link)

        compose.onNodeWithText(locCtx.getString(R.string.welcome_headline)).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(scanText).performScrollTo().assertIsDisplayed().performClick()
        compose.onNodeWithText(manualText).performScrollTo().assertIsDisplayed().assertHeightIsAtLeast(48.dp).performClick()
        compose.onNodeWithText(desktopText).performScrollTo().assertIsDisplayed().assertHeightIsAtLeast(48.dp).performClick()

        val scanBounds = compose.onNodeWithText(scanText).getBoundsInRoot()
        val manualBounds = compose.onNodeWithText(manualText).getBoundsInRoot()
        val desktopBounds = compose.onNodeWithText(desktopText).getBoundsInRoot()
        assertTrue("($locale) 1.5× 下主按钮与无法扫码不能重叠", scanBounds.bottom <= manualBounds.top)
        assertTrue("($locale) 1.5× 下页脚链接与操作组保留 ≥28dp 间距", desktopBounds.top - manualBounds.bottom >= 28.dp)

        assertEquals(1, scanClicks)
        assertEquals(1, manualClicks)
        assertEquals(1, desktopClicks)
    }

    @Test
    fun welcome_groups_manual_link_tightly_and_pushes_desktop_link_to_bottom_en() {
        assertWelcomeHierarchyAndClicks(Locale.US)
    }

    @Test
    fun welcome_groups_manual_link_tightly_and_pushes_desktop_link_to_bottom_zh() {
        assertWelcomeHierarchyAndClicks(Locale.SIMPLIFIED_CHINESE)
    }

    @Test
    fun welcome_remains_scrollable_and_clickable_at_1_5x_font_en() {
        assertWelcomeScrollableAt15x(Locale.US)
    }

    @Test
    fun welcome_remains_scrollable_and_clickable_at_1_5x_font_zh() {
        assertWelcomeScrollableAt15x(Locale.SIMPLIFIED_CHINESE)
    }
}
