package com.hawkeyexb.ppass.ui

import android.content.res.Configuration
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
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
 * #2106：验证首页英雄区在空闲/待传与传输忙碌态之间切换时底部高度保持一致，
 * 且 1.5× 大字号下自然撑高不截断。
 */
@RunWith(AndroidJUnit4::class)
class HomeHeroLayoutComposeTest {

    @get:Rule
    val compose = createComposeRule()

    private val ctx get() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun measureHeroSentinelTop(
        locale: Locale,
        fontScale: Float,
        state: BackupUiState,
        triplet: BackupTriplet,
        transferRow: TransferRow? = null,
        transferProgress: Float? = null,
        expectedText: String,
        expectedSecondText: String? = null,
    ): Dp {
        val cfg = Configuration(ctx.resources.configuration).apply { setLocale(locale) }
        val locCtx = ctx.createConfigurationContext(cfg)
        compose.setContent {
            CompositionLocalProvider(
                LocalContext provides locCtx,
                LocalConfiguration provides cfg,
                LocalDensity provides Density(density = 2.8125f, fontScale = fontScale),
            ) {
                PPTheme {
                    Box(Modifier.width(390.dp).height(900.dp)) {
                        HomeScreen(
                            storageName = "Home-PC",
                            state = state,
                            onBackupNow = {},
                            triplet = triplet,
                            autoBackupRuleOn = true,
                            mediaAccess = MediaAccess.FULL,
                            hasUsableSource = true,
                            hasSelectedAlbum = true,
                            transferRow = transferRow,
                            transferProgress = transferProgress,
                            notice = {
                                Box(Modifier.testTag("below_hero").fillMaxWidth().height(1.dp))
                            },
                        )
                    }
                }
            }
        }
        compose.onNodeWithText(expectedText).assertIsDisplayed()
        if (expectedSecondText != null) {
            compose.onNodeWithText(expectedSecondText).assertIsDisplayed()
            val firstBounds = compose.onNodeWithText(expectedText).getBoundsInRoot()
            val secondBounds = compose.onNodeWithText(expectedSecondText).getBoundsInRoot()
            assertTrue("($locale, scale=$fontScale) 忙碌态两行文字不能重叠", firstBounds.bottom <= secondBounds.top)
        }
        return compose.onNodeWithTag("below_hero").getBoundsInRoot().top
    }

    private fun assertHeroHeightStableAndScalesAt15x(locale: Locale) {
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

        val allSafeTop = measureHeroSentinelTop(
            locale = locale,
            fontScale = 1.0f,
            state = BackupUiState.AllSafe(ingested = 1, duplicates = 0),
            triplet = allSafeTriplet,
            expectedText = locCtx.getString(R.string.state_safe),
        )
        val pendingTop = measureHeroSentinelTop(
            locale = locale,
            fontScale = 1.0f,
            state = BackupUiState.Idle,
            triplet = activeTriplet,
            expectedText = locCtx.resources.getQuantityString(R.plurals.state_pending, 20, 20),
        )
        val preparingTop = measureHeroSentinelTop(
            locale = locale,
            fontScale = 1.0f,
            state = BackupUiState.Preparing,
            triplet = activeTriplet,
            expectedText = locCtx.getString(R.string.state_preparing),
        )
        val sendingTop = measureHeroSentinelTop(
            locale = locale,
            fontScale = 1.0f,
            state = BackupUiState.Sending(done = 11, total = 20, currentFile = "IMG_4821.HEIC"),
            triplet = activeTriplet,
            transferRow = sendingRow,
            transferProgress = 0.27f,
            expectedText = "IMG_4821.HEIC",
            expectedSecondText = locCtx.getString(R.string.state_sending_detail, "12.3 / 45.6 MB", 11, 20),
        )

        assertEquals("($locale) AllSafe 与 Sending 英雄区底部高度必须一致", sendingTop.value, allSafeTop.value, 0.5f)
        assertEquals("($locale) Pending 与 Sending 英雄区底部高度必须一致", sendingTop.value, pendingTop.value, 0.5f)
        assertEquals("($locale) Preparing 与 Sending 英雄区底部高度必须一致", sendingTop.value, preparingTop.value, 0.5f)

        val sending15xTop = measureHeroSentinelTop(
            locale = locale,
            fontScale = 1.5f,
            state = BackupUiState.Sending(done = 11, total = 20, currentFile = "IMG_4821.HEIC"),
            triplet = activeTriplet,
            transferRow = sendingRow,
            transferProgress = 0.27f,
            expectedText = "IMG_4821.HEIC",
            expectedSecondText = locCtx.getString(R.string.state_sending_detail, "12.3 / 45.6 MB", 11, 20),
        )
        assertTrue(
            "($locale) 1.5× 大字号下忙碌态英雄区必须自然撑高而不截断（1.0×=$sendingTop, 1.5×=$sending15xTop）",
            sending15xTop > sendingTop,
        )
    }

    @Test
    fun hero_progress_row_height_is_stable_and_expands_at_1_5x_en() {
        assertHeroHeightStableAndScalesAt15x(Locale.US)
    }

    @Test
    fun hero_progress_row_height_is_stable_and_expands_at_1_5x_zh() {
        assertHeroHeightStableAndScalesAt15x(Locale.SIMPLIFIED_CHINESE)
    }
}
