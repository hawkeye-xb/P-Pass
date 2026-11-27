package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * #2110：真实渲染 [CellRow] 的 Compose 布局与样式回归测试（E2）。
 *
 * 验证：
 * 1. 标准宽度下精简标题 + 邮箱稳稳单行并排，且 `Text` 实际渲染样式与 `rememberTextMeasurer()` 所用
 *    `labelStyle` / `valueStyle` 一致（不被 Material3 `ListItem` 的 `LabelSmall` Medium 字重覆写）；
 * 2. 在 8dp→16dp 尾部间距差值窗口内（以及旧长标题场景），`CellRow` 准确切为堆叠把邮箱落到
 *    `supportingContent`，绝不把左侧标题折断成两行；
 * 3. 1.5× 大字号与 320dp 窄屏（280dp 卡片）下均安全堆叠、左侧标题保持单行。
 */
@RunWith(AndroidJUnit4::class)
class CellRowLayoutComposeTest {

    @get:Rule
    val compose = createComposeRule()

    private val samsungDensity = 2.8125f
    private val email = "ppass@hawkeye-xb.com"

    private fun renderedTextLayout(node: SemanticsNodeInteraction): TextLayoutResult {
        val layouts = mutableListOf<TextLayoutResult>()
        val action = node.fetchSemanticsNode().config[SemanticsActions.GetTextLayoutResult]
        assertTrue("文本节点应提供 GetTextLayoutResult 语义", action.action?.invoke(layouts) == true)
        return layouts.first()
    }

    private fun renderCellRow(
        label: String,
        value: String,
        cardWidth: Dp,
        fontScale: Float,
        onCapturedExpectedStyles: ((TextStyle, TextStyle) -> Unit)? = null,
    ) {
        compose.setContent {
            CompositionLocalProvider(
                LocalDensity provides Density(density = samsungDensity, fontScale = fontScale),
            ) {
                PPTheme {
                    ProvideTextStyle(LocalTextStyle.current.copy(fontFamily = PPFont.Sans)) {
                        val expectedLabel = LocalTextStyle.current.copy(fontSize = 15.sp)
                        val expectedValue = LocalTextStyle.current.copy(fontSize = 14.sp)
                        onCapturedExpectedStyles?.invoke(expectedLabel, expectedValue)
                        Box(Modifier.width(cardWidth)) {
                            CellRow(label = label, value = value, onClick = {})
                        }
                    }
                }
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun concise_email_row_stays_single_line_and_matches_measured_text_styles() {
        var expectedLabelStyle: TextStyle? = null
        var expectedValueStyle: TextStyle? = null

        renderCellRow(
            label = "邮件反馈",
            value = email,
            cardWidth = 344.dp,
            fontScale = 1.08f,
            onCapturedExpectedStyles = { l, v ->
                expectedLabelStyle = l
                expectedValueStyle = v
            },
        )

        val labelNode = compose.onNodeWithText("邮件反馈", useUnmergedTree = true).assertIsDisplayed()
        val valueNode = compose.onNodeWithText(email, useUnmergedTree = true).assertIsDisplayed()

        val labelLayout = renderedTextLayout(labelNode)
        val valueLayout = renderedTextLayout(valueNode)
        val labelBounds = labelNode.getBoundsInRoot()
        val valueBounds = valueNode.getBoundsInRoot()

        assertEquals("标准字号下「邮件反馈」必须单行不折断", 1, labelLayout.lineCount)
        assertEquals("标准字号下邮箱必须单行不换行", 1, valueLayout.lineCount)
        assertTrue(
            "标题应在邮箱左侧并排显示（label=$labelBounds, value=$valueBounds）",
            labelBounds.right < valueBounds.left,
        )
        val labelMidY = (labelBounds.top.value + labelBounds.bottom.value) / 2f
        val valueMidY = (valueBounds.top.value + valueBounds.bottom.value) / 2f
        assertTrue(
            "标题与邮箱应处于同一水平行（labelMidY=$labelMidY, valueMidY=$valueMidY）",
            abs(labelMidY - valueMidY) <= 4f,
        )

        val actualLabelStyle = labelLayout.layoutInput.style
        val actualValueStyle = valueLayout.layoutInput.style
        assertEquals("标题字号必须与量测 labelStyle 一致", expectedLabelStyle!!.fontSize, actualLabelStyle.fontSize)
        assertEquals("标题字重必须与量测 labelStyle 一致", expectedLabelStyle!!.fontWeight, actualLabelStyle.fontWeight)
        assertEquals("标题字距必须与量测 labelStyle 一致", expectedLabelStyle!!.letterSpacing, actualLabelStyle.letterSpacing)
        assertEquals("右侧值字号必须与量测 valueStyle 一致", expectedValueStyle!!.fontSize, actualValueStyle.fontSize)
        assertEquals("右侧值字重必须与量测 valueStyle 一致（不得被 ListItem LabelSmall 改成 Medium）", expectedValueStyle!!.fontWeight, actualValueStyle.fontWeight)
        assertEquals("右侧值字距必须与量测 valueStyle 一致", expectedValueStyle!!.letterSpacing, actualValueStyle.letterSpacing)
        assertNotEquals("右侧值不得回退到 Material3 LabelSmall 的 Medium 字重", FontWeight.Medium, actualValueStyle.fontWeight)
    }

    /**
     * 精确构造落在 ListItem `8dp`（旧误估）与 `16dp`（真实 TrailingContentStartPadding）之间的行宽：
     * 容器宽 = 内容实测宽 + 32dp + 12dp（在旧 8dp 判定下认为放得下而走并排，导致 ListItem 真实扣 16dp 时把左侧标题折成 2 行；
     * 修复后判定准确切为堆叠，左侧标题保持 1 行，邮箱整体落入 supportingContent）。
     */
    @Test
    fun tight_margin_between_8dp_and_16dp_stacks_instead_of_breaking_title() {
        val tightLabel = "问题反馈（邮件）"
        compose.setContent {
            CompositionLocalProvider(
                LocalDensity provides Density(density = samsungDensity, fontScale = 1.08f),
            ) {
                PPTheme {
                    ProvideTextStyle(LocalTextStyle.current.copy(fontFamily = PPFont.Sans)) {
                        val density = LocalDensity.current
                        val measurer = rememberTextMeasurer()
                        val labelStyle = LocalTextStyle.current.copy(fontSize = 15.sp)
                        val valueStyle = LocalTextStyle.current.copy(fontSize = 14.sp)
                        val chevronStyle = LocalTextStyle.current.copy(fontSize = 16.sp)
                        val contentWidthPx =
                            measurer.measure(AnnotatedString(tightLabel), labelStyle, softWrap = false, maxLines = 1).size.width +
                                measurer.measure(AnnotatedString(email), valueStyle, softWrap = false, maxLines = 1).size.width +
                                measurer.measure(AnnotatedString("›"), chevronStyle, softWrap = false, maxLines = 1).size.width +
                                with(density) { 4.dp.roundToPx() }
                        // 留 32dp 左右内边距 + 12dp 尾部间距：严格大于旧 8dp 阈值、严格小于真实 16dp 阈值。
                        val boundaryCardWidth = with(density) { contentWidthPx.toDp() } + 32.dp + 12.dp
                        Box(Modifier.width(boundaryCardWidth)) {
                            CellRow(label = tightLabel, value = email, onClick = {})
                        }
                    }
                }
            }
        }
        compose.waitForIdle()

        val labelNode = compose.onNodeWithText(tightLabel, useUnmergedTree = true).assertIsDisplayed()
        val valueNode = compose.onNodeWithText(email, useUnmergedTree = true).assertIsDisplayed()
        val labelLayout = renderedTextLayout(labelNode)
        val labelBounds = labelNode.getBoundsInRoot()
        val valueBounds = valueNode.getBoundsInRoot()

        assertEquals("8dp..16dp 边界窗口内左侧标题绝不能被折断成两行", 1, labelLayout.lineCount)
        assertTrue(
            "8dp..16dp 边界窗口内邮箱必须切到 supportingContent 落在标题下方（label=$labelBounds, value=$valueBounds）",
            valueBounds.top >= labelBounds.bottom - 1.dp,
        )
    }

    @Test
    fun email_row_stacks_at_1_5x_font_scale_without_breaking_title() {
        renderCellRow(
            label = "邮件反馈",
            value = email,
            cardWidth = 344.dp,
            fontScale = 1.5f,
        )

        val labelNode = compose.onNodeWithText("邮件反馈", useUnmergedTree = true).assertIsDisplayed()
        val valueNode = compose.onNodeWithText(email, useUnmergedTree = true).assertIsDisplayed()
        val labelLayout = renderedTextLayout(labelNode)
        val labelBounds = labelNode.getBoundsInRoot()
        val valueBounds = valueNode.getBoundsInRoot()

        assertEquals("1.5× 大字号下左侧标题「邮件反馈」必须保持单行", 1, labelLayout.lineCount)
        assertTrue(
            "1.5× 大字号下邮箱必须切到 supportingContent 落在标题下方（label=$labelBounds, value=$valueBounds）",
            valueBounds.top >= labelBounds.bottom - 1.dp,
        )
    }

    @Test
    fun narrow_320dp_screen_stacks_without_breaking_title() {
        // 320dp 窄屏扣除 40dp 页边距后卡片宽 280dp。
        renderCellRow(
            label = "Email feedback",
            value = email,
            cardWidth = 280.dp,
            fontScale = 1.08f,
        )

        val labelNode = compose.onNodeWithText("Email feedback", useUnmergedTree = true).assertIsDisplayed()
        val valueNode = compose.onNodeWithText(email, useUnmergedTree = true).assertIsDisplayed()
        val labelLayout = renderedTextLayout(labelNode)
        val labelBounds = labelNode.getBoundsInRoot()
        val valueBounds = valueNode.getBoundsInRoot()

        assertEquals("320dp 窄屏下左侧标题「Email feedback」必须保持单行", 1, labelLayout.lineCount)
        assertTrue(
            "320dp 窄屏下邮箱必须切到 supportingContent 落在标题下方（label=$labelBounds, value=$valueBounds）",
            valueBounds.top >= labelBounds.bottom - 1.dp,
        )
    }
}
