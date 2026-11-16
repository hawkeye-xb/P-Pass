package com.hawkeyexb.ppass.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertWidthIsAtLeast
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.hasStateDescription
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.hawkeyexb.ppass.ui.PPTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SourceCardsTest {
    @get:Rule
    val compose = createComposeRule()

    private fun withRole(role: Role) = SemanticsMatcher("role=$role") {
        runCatching { it.config[SemanticsProperties.Role] }.getOrNull() == role
    }

    @Test
    fun source_and_action_cells_have_identical_dimensions() {
        compose.setContent {
            PPTheme {
                Column(modifier = Modifier.width(360.dp)) {
                    SourceCard(
                        title = "Camera", countLabel = "4 张", kind = SourceKind.ALBUM, kindLabel = "相册",
                        selected = true, selectedDescription = "已选择", unselectedDescription = "未选择",
                        onClick = {}, cover = {}, tag = "album",
                    )
                    SourceCard(
                        title = "Blackmagic", countLabel = "2 张", kind = SourceKind.FOLDER, kindLabel = "文件夹",
                        selected = false, selectedDescription = "已选择", unselectedDescription = "未选择",
                        onClick = {}, cover = {}, tag = "folder",
                    )
                    AddSourceCard(label = "添加文件夹", actionContentDescription = "动作", onClick = {}, tag = "add")
                }
            }
        }
        val album = compose.onNodeWithTag("album").getBoundsInRoot()
        val folder = compose.onNodeWithTag("folder").getBoundsInRoot()
        val add = compose.onNodeWithTag("add").getBoundsInRoot()
        assertEquals((album.bottom - album.top).value, (folder.bottom - folder.top).value, 0.01f)
        assertEquals((album.bottom - album.top).value, (add.bottom - add.top).value, 0.01f)
        assertEquals((album.right - album.left).value, (folder.right - folder.left).value, 0.01f)
        assertEquals((album.right - album.left).value, (add.right - add.left).value, 0.01f)
    }

    @Test
    fun source_kind_and_selection_are_exposed_to_talkback() {
        compose.setContent {
            PPTheme {
                SourceCard(
                    title = "Blackmagic", countLabel = "2 张", kind = SourceKind.FOLDER, kindLabel = "文件夹",
                    selected = true, selectedDescription = "已选择", unselectedDescription = "未选择",
                    onClick = {}, cover = {},
                )
            }
        }
        compose.onNodeWithContentDescription("文件夹").assertIsDisplayed()
        compose.onNodeWithText("Blackmagic")
            .assert(withRole(Role.Checkbox))
            .assert(isSelected())
            .assert(hasStateDescription("已选择"))
    }

    @Test
    fun add_action_is_a_button_without_selected_state() {
        compose.setContent {
            PPTheme {
                AddSourceCard(label = "添加文件夹", actionContentDescription = "动作", onClick = {})
            }
        }
        compose.onNodeWithText("添加文件夹")
            .assert(withRole(Role.Button))
            .assert(SemanticsMatcher("没有 selected 状态") { !it.config.contains(SemanticsProperties.Selected) })
        compose.onNodeWithContentDescription("动作").assertIsDisplayed()
    }

    @Test
    fun menu_uses_standard_actions_and_preserves_touch_target() {
        var removed = false
        compose.setContent {
            PPTheme {
                SourceCard(
                    title = "Blackmagic", countLabel = "2 张", kind = SourceKind.FOLDER, kindLabel = "文件夹",
                    selected = false, selectedDescription = "已选择", unselectedDescription = "未选择",
                    onClick = {}, cover = {},
                    menuActions = listOf(
                        SourceMenuAction("重新授权") {},
                        SourceMenuAction("移除") { removed = true },
                    ),
                )
            }
        }
        compose.onNodeWithContentDescription("更多操作")
            .assertHeightIsAtLeast(56.dp)
            .assertWidthIsAtLeast(56.dp)
            .performClick()
        compose.onNodeWithText("重新授权").assertIsDisplayed()
        compose.onNodeWithText("移除").assertIsDisplayed().performClick()
        assertTrue(removed)
    }

    @Test
    fun labels_remain_visible_with_large_fonts() {
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(density = 1f, fontScale = 1.3f)) {
                PPTheme {
                    SourceCard(
                        title = "Blackmagic Camera", countLabel = "2 张", kind = SourceKind.FOLDER, kindLabel = "文件夹",
                        selected = false, selectedDescription = "已选择", unselectedDescription = "未选择",
                        onClick = {}, cover = {},
                    )
                }
            }
        }
        compose.onNodeWithText("Blackmagic Camera").assertIsDisplayed()
        compose.onNodeWithText("2 张").assertIsDisplayed()
        compose.onNodeWithContentDescription("文件夹").assertIsDisplayed()
    }
}
