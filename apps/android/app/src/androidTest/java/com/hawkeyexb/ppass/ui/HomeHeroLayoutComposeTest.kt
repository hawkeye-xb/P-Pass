package com.hawkeyexb.ppass.ui

import android.content.res.Configuration
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.DpRect
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.height
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.BackupTriplet
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.flow.TransferPace
import com.hawkeyexb.ppass.backup.flow.TransferRow
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * #2106：验证首页英雄区底部进度行在空闲/待传与传输忙碌态之间切换时自身高度一致，
 * 且 1.5× 大字号下进度行本身自然撑高、两行文字与进度条完整落在进度行内不截断。
 */
@RunWith(AndroidJUnit4::class)
class HomeHeroLayoutComposeTest {

    @get:Rule
    val compose = createComposeRule()

    private val ctx get() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun renderedTextLayout(node: SemanticsNodeInteraction): TextLayoutResult {
        val layouts = mutableListOf<TextLayoutResult>()
        val action = node.fetchSemanticsNode().config[SemanticsActions.GetTextLayoutResult]
        assertTrue("文本节点应提供 GetTextLayoutResult 语义", action.action?.invoke(layouts) == true)
        return layouts.first()
    }

    private fun assertContainedInRow(
        label: String,
        child: DpRect,
        row: DpRect,
    ) {
        assertTrue("$label top(${child.top}) 必须在进度行 top(${row.top}) 之内", child.top >= row.top - 0.5.dp)
        assertTrue("$label bottom(${child.bottom}) 必须在进度行 bottom(${row.bottom}) 之内", child.bottom <= row.bottom + 0.5.dp)
        assertTrue("$label left(${child.left}) 必须在进度行 left(${row.left}) 之内", child.left >= row.left - 0.5.dp)
        assertTrue("$label right(${child.right}) 必须在进度行 right(${row.right}) 之内", child.right <= row.right + 0.5.dp)
    }

    private fun assertHeroProgressRowStableAndExpandsAt15x(locale: Locale) {
        val densityPxPerDp = 2.8125f
        val cfg = Configuration(ctx.resources.configuration).apply { setLocale(locale) }
        val locCtx = ctx.createConfigurationContext(cfg)
        val allSafeTriplet = BackupTriplet(n = 100L, m = 100L, lastSuccessAt = 1L, confirmedRaw = 100L)
        val activeTriplet = BackupTriplet(n = 100L, m = 80L, lastSuccessAt = 1L, confirmedRaw = 80L)
        val sendingRow = TransferRow(
            fileName = "IMG_4821.HEIC",
            bytesText = "12.3 / 45.6 MB",
            pace = TransferPace.MOVING,
            quietSeconds = 0,
        )

        var uiState by mutableStateOf<BackupUiState>(BackupUiState.AllSafe(ingested = 1, duplicates = 0))
        var triplet by mutableStateOf(allSafeTriplet)
        var transferRow by mutableStateOf<TransferRow?>(null)
        var transferProgress by mutableStateOf<Float?>(null)
        var fontScale by mutableFloatStateOf(1.0f)

        compose.setContent {
            CompositionLocalProvider(
                LocalContext provides locCtx,
                LocalConfiguration provides cfg,
                LocalDensity provides Density(density = densityPxPerDp, fontScale = fontScale),
            ) {
                PPTheme {
                    Box(Modifier.width(390.dp).height(900.dp)) {
                        HomeScreen(
                            storageName = "Home-PC",
                            state = uiState,
                            onBackupNow = {},
                            triplet = triplet,
                            autoBackupRuleOn = true,
                            mediaAccess = MediaAccess.FULL,
                            hasUsableSource = true,
                            hasSelectedAlbum = true,
                            transferRow = transferRow,
                            transferProgress = transferProgress,
                        )
                    }
                }
            }
        }

        fun measureRowHeight(): Float {
            compose.waitForIdle()
            return compose.onNodeWithTag("hero_progress_row").getBoundsInRoot().height.value
        }

        // 1. AllSafe (1.0×)
        compose.onNodeWithText(locCtx.getString(R.string.state_safe)).assertIsDisplayed()
        val allSafeRowHeight = measureRowHeight()

        // 2. Pending (1.0×)
        compose.runOnIdle {
            uiState = BackupUiState.Idle
            triplet = activeTriplet
        }
        compose.waitForIdle()
        compose.onNodeWithText(locCtx.resources.getQuantityString(R.plurals.state_pending, 20, 20)).assertIsDisplayed()
        val pendingRowHeight = measureRowHeight()

        // 3. Preparing (1.0×)
        compose.runOnIdle {
            uiState = BackupUiState.Preparing
            transferRow = null
            transferProgress = null
        }
        compose.waitForIdle()
        compose.onNodeWithText(locCtx.getString(R.string.state_preparing)).assertIsDisplayed()
        val preparingRowHeight = measureRowHeight()

        // 4. Sending (1.0×)
        compose.runOnIdle {
            uiState = BackupUiState.Sending(done = 11, total = 20, currentFile = "IMG_4821.HEIC")
            transferRow = sendingRow
            transferProgress = 0.27f
        }
        compose.waitForIdle()
        compose.onNodeWithText("IMG_4821.HEIC").assertIsDisplayed()
        compose.onNodeWithText(locCtx.getString(R.string.state_sending_detail, "12.3 / 45.6 MB", 11, 20)).assertIsDisplayed()
        val sendingRowHeight = measureRowHeight()

        assertTrue("($locale) 进度行最小高度须 >= 64dp（实际=$sendingRowHeight）", sendingRowHeight >= 63.5f)
        assertEquals("($locale) AllSafe 与 Sending 进度行自身高度必须一致", sendingRowHeight, allSafeRowHeight, 0.5f)
        assertEquals("($locale) Pending 与 Sending 进度行自身高度必须一致", sendingRowHeight, pendingRowHeight, 0.5f)
        assertEquals("($locale) Preparing 与 Sending 进度行自身高度必须一致", sendingRowHeight, preparingRowHeight, 0.5f)

        // 5. Sending (1.5× 大字号)：直接测进度行自身及其内部两行文字、进度条边界
        compose.runOnIdle {
            fontScale = 1.5f
        }
        compose.waitForIdle()
        val row15x = compose.onNodeWithTag("hero_progress_row").assertIsDisplayed().getBoundsInRoot()
        val line1Node = compose.onNodeWithTag("hero_progress_line1").assertIsDisplayed()
        val line2Node = compose.onNodeWithTag("hero_progress_line2").assertIsDisplayed()
        val barNode = compose.onNodeWithTag("hero_progress_bar").assertIsDisplayed()

        val line1Bounds = line1Node.getBoundsInRoot()
        val line2Bounds = line2Node.getBoundsInRoot()
        val barBounds = barNode.getBoundsInRoot()

        assertTrue(
            "($locale) 1.5× 下进度行自身高度(${row15x.height.value})必须大于 1.0×($sendingRowHeight)",
            row15x.height.value > sendingRowHeight + 4f,
        )
        assertContainedInRow("($locale) line1", line1Bounds, row15x)
        assertContainedInRow("($locale) line2", line2Bounds, row15x)
        assertContainedInRow("($locale) bar", barBounds, row15x)
        assertTrue("($locale) 1.5× 下两行文字不能重叠", line1Bounds.bottom <= line2Bounds.top + 0.5.dp)
        assertTrue("($locale) 1.5× 下第二行文字与进度条不能重叠", line2Bounds.bottom <= barBounds.top + 0.5.dp)
        assertTrue("($locale) 1.5× 下进度条高度必须保持 >= 6dp", barBounds.height.value >= 5.5f)

        val line1TextDp = renderedTextLayout(line1Node).size.height / densityPxPerDp
        val line2TextDp = renderedTextLayout(line2Node).size.height / densityPxPerDp
        assertTrue(
            "($locale) 1.5× 下第一行渲染文本高(${line1TextDp}dp)不得被容器(${line1Bounds.height.value}dp)垂直裁剪",
            line1Bounds.height.value >= line1TextDp - 1.0f,
        )
        assertTrue(
            "($locale) 1.5× 下第二行渲染文本高(${line2TextDp}dp)不得被容器(${line2Bounds.height.value}dp)垂直裁剪",
            line2Bounds.height.value >= line2TextDp - 1.0f,
        )
    }

    @Test
    fun hero_progress_row_height_is_stable_and_expands_at_1_5x_en() {
        assertHeroProgressRowStableAndExpandsAt15x(Locale.US)
    }

    @Test
    fun hero_progress_row_height_is_stable_and_expands_at_1_5x_zh() {
        assertHeroProgressRowStableAndExpandsAt15x(Locale.SIMPLIFIED_CHINESE)
    }
}
