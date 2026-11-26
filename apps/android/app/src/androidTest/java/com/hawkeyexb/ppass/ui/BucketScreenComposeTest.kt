package com.hawkeyexb.ppass.ui

import android.content.res.Configuration
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import java.util.Locale
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.MediaScanner
import com.hawkeyexb.ppass.backup.ScopeTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * #2067：备份范围页真实 Compose UI 行为与 1.5× 大字号布局回归测试（E2）。
 */
@RunWith(AndroidJUnit4::class)
class BucketScreenComposeTest {

    @get:Rule
    val compose = createComposeRule()

    private val ctx get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun no_folders_hides_folder_section_and_exposes_top_bar_add_button() {
        var addCalls = 0
        compose.setContent {
            PPTheme {
                BucketScreen(
                    buckets = listOf(MediaScanner.Bucket(1L, "Camera", 12)),
                    selected = emptySet(),
                    sinceLabel = "From Nov 26 onward",
                    firstTime = false,
                    folderBuckets = emptyList(),
                    onAddFolder = { addCalls++ },
                    onDone = { _, _, _ -> },
                    onCancel = {},
                )
            }
        }
        compose.onAllNodesWithText(ctx.getString(R.string.scope_folders_section)).assertCountEquals(0)
        compose.onAllNodesWithText(ctx.getString(R.string.folder_add)).assertCountEquals(0)
        compose.onNodeWithContentDescription(ctx.getString(R.string.folder_add))
            .assertIsDisplayed()
            .performClick()
        assertEquals(1, addCalls)
    }

    @Test
    fun saving_disables_top_bar_add_folder_button() {
        var addCalls = 0
        compose.setContent {
            PPTheme {
                BucketScreen(
                    buckets = emptyList(),
                    selected = emptySet(),
                    sinceLabel = "From Nov 26 onward",
                    firstTime = false,
                    saving = true,
                    onAddFolder = { addCalls++ },
                    onDone = { _, _, _ -> },
                    onCancel = {},
                )
            }
        }
        compose.onNodeWithContentDescription(ctx.getString(R.string.folder_add))
            .assertIsNotEnabled()
            .performClick()
        assertEquals(0, addCalls)
    }

    @Test
    fun folders_render_below_albums_with_reauth_and_confirm_remove() {
        val reauthKeys = mutableListOf<String>()
        val removedKeys = mutableListOf<String>()
        val folder = FolderBucketUi(
            key = "folder-1",
            bucket = MediaScanner.Bucket(100L, "Blackmagic", 5),
            registered = true,
            needsPermission = true,
        )
        compose.setContent {
            PPTheme {
                BucketScreen(
                    buckets = listOf(MediaScanner.Bucket(1L, "Camera", 12)),
                    selected = setOf(1L),
                    sinceLabel = "From Nov 26 onward",
                    firstTime = false,
                    folderBuckets = listOf(folder),
                    selectedFolderKeys = setOf("folder-1"),
                    onReauthorizeFolder = { reauthKeys += it },
                    onRemoveFolder = { removedKeys += it },
                    onDone = { _, _, _ -> },
                    onCancel = {},
                )
            }
        }
        val albumBounds = compose.onNodeWithText("Camera").getBoundsInRoot()
        val folderHeaderBounds = compose.onNodeWithText(ctx.getString(R.string.scope_folders_section)).getBoundsInRoot()
        assertTrue(
            "文件夹分组必须在相册网格下方 (albumBottom=${albumBounds.bottom}, headerTop=${folderHeaderBounds.top})",
            folderHeaderBounds.top >= albumBounds.bottom,
        )

        compose.onNodeWithText(ctx.getString(R.string.folder_status_needs_permission)).assertIsDisplayed()
        compose.onNodeWithText(ctx.getString(R.string.folder_reauthorize))
            .assertIsDisplayed()
            .performClick()
        assertEquals(listOf("folder-1"), reauthKeys)

        compose.onNodeWithContentDescription(ctx.getString(R.string.source_more_actions)).performClick()
        compose.onNodeWithText(ctx.getString(R.string.folder_remove)).performClick()
        assertTrue("打开移除弹窗前不得触发移除", removedKeys.isEmpty())
        compose.onNodeWithText(ctx.getString(R.string.folder_remove_confirm_action)).performClick()
        assertEquals(listOf("folder-1"), removedKeys)
    }

    @Test
    fun segmented_time_picker_adapts_at_1_5x_font_without_overlap_and_submits_selected_time() {
        val submittedTimes = mutableListOf<ScopeTime>()
        val sinceText = "From Nov 26 onward"
        val allText = ctx.getString(R.string.scope_time_all)
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(density = 2.8125f, fontScale = 1.5f)) {
                PPTheme {
                    Box(Modifier.width(360.dp)) {
                        BucketScreen(
                            buckets = listOf(MediaScanner.Bucket(1L, "Camera", 12)),
                            selected = setOf(1L),
                            initialTime = ScopeTime.SINCE_TODAY,
                            sinceLabel = sinceText,
                            firstTime = false,
                            onDone = { _, _, time -> submittedTimes += time },
                            onCancel = {},
                        )
                    }
                }
            }
        }
        compose.onNodeWithText(ctx.getString(R.string.scope_time_section)).assertIsDisplayed()
        val seg1Btn = compose.onNodeWithText(sinceText).assertIsDisplayed().assertHeightIsAtLeast(48.dp).getBoundsInRoot()
        val seg2Btn = compose.onNodeWithText(allText).assertIsDisplayed().assertHeightIsAtLeast(48.dp).getBoundsInRoot()
        assertEquals(
            "两段容器高度必须一致 (seg1=${seg1Btn.bottom - seg1Btn.top}, seg2=${seg2Btn.bottom - seg2Btn.top})",
            (seg1Btn.bottom - seg1Btn.top).value,
            (seg2Btn.bottom - seg2Btn.top).value,
            1.5f,
        )
        val seg1Text = compose.onNodeWithText(sinceText, useUnmergedTree = true).assertIsDisplayed().getBoundsInRoot()
        val seg2Text = compose.onNodeWithText(allText, useUnmergedTree = true).assertIsDisplayed().getBoundsInRoot()
        assertTrue(
            "两段文字标签不能水平重叠 (seg1Text.right=${seg1Text.right}, seg2Text.left=${seg2Text.left})",
            seg1Text.right <= seg2Text.left,
        )

        compose.onNodeWithText(allText).performClick()
        val saveLabel = ctx.getString(
            R.string.bucket_action_with_summary,
            ctx.getString(R.string.bucket_save),
            ctx.resources.getQuantityString(R.plurals.backup_scope_n, 1, 1),
        )
        compose.onNodeWithText(saveLabel).performClick()
        assertEquals(listOf(ScopeTime.ALL), submittedTimes)
    }

    @Test
    fun partial_access_keeps_notice_and_updates_summary_live() {
        val a = MediaScanner.Bucket(1L, "Camera", 8)
        val b = MediaScanner.Bucket(2L, "Screenshots", 4)
        val folder = FolderBucketUi("f1", MediaScanner.Bucket(100L, "Docs", 2), registered = true)
        compose.setContent {
            PPTheme {
                BucketScreen(
                    buckets = listOf(a, b),
                    selected = setOf(1L),
                    sinceLabel = "From Nov 26 onward",
                    firstTime = false,
                    folderBuckets = listOf(folder),
                    selectedFolderKeys = setOf("f1"),
                    albumAccess = MediaAccess.PARTIAL,
                    onDone = { _, _, _ -> },
                    onCancel = {},
                )
            }
        }
        compose.onNodeWithText(ctx.getString(R.string.scope_album_no_access_title)).assertIsDisplayed()
        compose.onNodeWithText("Camera").assertIsDisplayed()
        compose.onAllNodesWithText("Screenshots").assertCountEquals(0)

        val saveBase = ctx.getString(R.string.bucket_save)
        val album1 = ctx.resources.getQuantityString(R.plurals.backup_scope_n, 1, 1)
        val folder1 = ctx.resources.getQuantityString(R.plurals.backup_scope_folder_n, 1, 1)
        compose.onNodeWithText(ctx.getString(R.string.bucket_action_with_summary, saveBase, "$album1 · $folder1"))
            .assertIsDisplayed()

        // Uncheck Camera -> summary updates live to 1 folder only
        compose.onNodeWithText("Camera").performClick()
        compose.onNodeWithText(ctx.getString(R.string.bucket_action_with_summary, saveBase, folder1))
            .assertIsDisplayed()

        // Uncheck Docs folder -> summary updates live to empty
        compose.onNodeWithText("Docs").performClick()
        compose.onNodeWithText(ctx.getString(R.string.bucket_action_empty, saveBase))
            .assertIsDisplayed()
    }

    @Test
    fun segmented_time_picker_adapts_chinese_1_5x_font_without_overlap() {
        val zhConfig = Configuration(ctx.resources.configuration).apply { setLocale(Locale.SIMPLIFIED_CHINESE) }
        val zhCtx = ctx.createConfigurationContext(zhConfig)
        val sinceZh = "11月26日以后"
        val allZh = zhCtx.getString(R.string.scope_time_all)
        compose.setContent {
            CompositionLocalProvider(
                LocalContext provides zhCtx,
                LocalConfiguration provides zhConfig,
                LocalDensity provides Density(density = 2.8125f, fontScale = 1.5f),
            ) {
                PPTheme {
                    Box(Modifier.width(360.dp)) {
                        BucketScreen(
                            buckets = listOf(MediaScanner.Bucket(1L, "相册", 6)),
                            selected = setOf(1L),
                            initialTime = ScopeTime.SINCE_TODAY,
                            sinceLabel = sinceZh,
                            firstTime = false,
                            onDone = { _, _, _ -> },
                            onCancel = {},
                        )
                    }
                }
            }
        }
        val seg1Btn = compose.onNodeWithText(sinceZh).assertIsDisplayed().assertHeightIsAtLeast(48.dp).getBoundsInRoot()
        val seg2Btn = compose.onNodeWithText(allZh).assertIsDisplayed().assertHeightIsAtLeast(48.dp).getBoundsInRoot()
        assertEquals(
            (seg1Btn.bottom - seg1Btn.top).value,
            (seg2Btn.bottom - seg2Btn.top).value,
            1.5f,
        )
        val seg1Text = compose.onNodeWithText(sinceZh, useUnmergedTree = true).assertIsDisplayed().getBoundsInRoot()
        val seg2Text = compose.onNodeWithText(allZh, useUnmergedTree = true).assertIsDisplayed().getBoundsInRoot()
        assertTrue(
            "中文 1.5× 下两段文字不能水平重叠 (seg1Text.right=${seg1Text.right}, seg2Text.left=${seg2Text.left})",
            seg1Text.right <= seg2Text.left,
        )
    }
}
