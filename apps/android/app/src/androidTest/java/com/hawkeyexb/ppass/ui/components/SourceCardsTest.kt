package com.hawkeyexb.ppass.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertWidthIsAtLeast
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.hasStateDescription
import androidx.compose.ui.test.isNotSelected
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.hawkeyexb.ppass.ui.PPTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
                // 三张卡叠在同一个固定尺寸容器里：每张都在相同约束下单独测量，
                // 不会像 Column 那样把前两张的高度从第三张里扣掉（窗口不足时会假红）。
                Box(modifier = Modifier.width(360.dp).height(400.dp)) {
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
    fun unselected_album_card_reports_its_kind_and_unselected_state() {
        compose.setContent {
            PPTheme {
                SourceCard(
                    title = "Camera", countLabel = "4 张", kind = SourceKind.ALBUM, kindLabel = "相册",
                    selected = false, selectedDescription = "已选择", unselectedDescription = "未选择",
                    onClick = {}, cover = {},
                )
            }
        }
        compose.onNodeWithContentDescription("相册").assertIsDisplayed()
        compose.onNodeWithText("Camera")
            .assert(withRole(Role.Checkbox))
            .assert(isNotSelected())
            .assert(hasStateDescription("未选择"))
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
    fun titled_nodes_trigger_their_click_callback() {
        var sourceClicked = false
        var addClicked = false
        compose.setContent {
            PPTheme {
                Column {
                    SourceCard(
                        title = "Blackmagic", countLabel = "2 张", kind = SourceKind.FOLDER, kindLabel = "文件夹",
                        selected = false, selectedDescription = "已选择", unselectedDescription = "未选择",
                        onClick = { sourceClicked = true }, cover = {},
                    )
                    AddSourceCard(
                        label = "添加文件夹", actionContentDescription = "动作",
                        onClick = { addClicked = true },
                    )
                }
            }
        }
        // 坐标点击和屏幕阅读器双击（语义动作）都要落到 onClick 上。
        compose.onNodeWithText("Blackmagic").performClick()
        compose.onNodeWithText("Blackmagic").performSemanticsAction(SemanticsActions.OnClick)
        compose.onNodeWithText("添加文件夹").performClick()
        compose.onNodeWithText("添加文件夹").performSemanticsAction(SemanticsActions.OnClick)
        assertTrue("带标题的来源卡点击没有回调 onClick", sourceClicked)
        assertTrue("带标题的添加卡点击没有回调 onClick", addClicked)
    }

    @Test
    fun source_details_do_not_overlap_icon_or_menu() {
        compose.setContent {
            PPTheme {
                SourceCard(
                    title = "Blackmagic", countLabel = "2 张", kind = SourceKind.FOLDER, kindLabel = "文件夹",
                    selected = false, selectedDescription = "已选择", unselectedDescription = "未选择",
                    onClick = {}, cover = {},
                    menuActions = listOf(SourceMenuAction("移除") {}),
                )
            }
        }
        val icon = compose.onNodeWithContentDescription("文件夹", useUnmergedTree = true).getBoundsInRoot()
        val title = compose.onNodeWithText("Blackmagic", useUnmergedTree = true).getBoundsInRoot()
        val menu = compose.onNodeWithContentDescription("更多操作", useUnmergedTree = true).getBoundsInRoot()
        assertTrue("类型图标与标题重叠", title.left >= icon.right)
        assertTrue("菜单按钮与标题重叠", title.right <= menu.left)
    }

    @Test
    fun labels_remain_visible_with_large_fonts() {
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(density = 1f, fontScale = 1.8f)) {
                PPTheme {
                    // 固定成手机宽度，避免 density=1f 下卡片铺满整块屏幕、长标题一行就放得下。
                    Box(modifier = Modifier.width(360.dp)) {
                        SourceCard(
                            title = "Blackmagic Camera 相机视频与照片备份文件夹 2026 年度归档存放位置 外部硬盘同步",
                            countLabel = "2 张", kind = SourceKind.FOLDER, kindLabel = "文件夹",
                            selected = false, selectedDescription = "已选择", unselectedDescription = "未选择",
                            onClick = {}, cover = {},
                        )
                    }
                }
            }
        }
        compose.onNodeWithText("Blackmagic Camera 相机视频与照片备份文件夹 2026 年度归档存放位置 外部硬盘同步").assertIsDisplayed()
        compose.onNodeWithText("2 张").assertIsDisplayed()
        val count = compose.onNodeWithText("2 张", useUnmergedTree = true).getBoundsInRoot()
        assertTrue("大字号下数量标签被压到不足一行高：${(count.bottom - count.top).value}dp", (count.bottom - count.top) >= 20.dp)
        compose.onNodeWithContentDescription("文件夹").assertIsDisplayed()
    }

    /**
     * #1868：AddSourceCard 接收 `enabled = false` 时，Compose 无障碍语义必须标记为不可用
     * （TalkBack 报 disabled），并且点击不再触发 onClick——由组件自身阻断，而不是靠调用点吞点击。
     */
    @Test
    fun disabled_add_card_exposes_disabled_semantics_and_blocks_clicks() {
        var clicked = false
        compose.setContent {
            PPTheme {
                AddSourceCard(
                    label = "添加文件夹",
                    actionContentDescription = "动作",
                    enabled = false,
                    onClick = { clicked = true },
                )
            }
        }
        compose.onNodeWithText("添加文件夹").assertIsNotEnabled()
        compose.onNodeWithText("添加文件夹").performClick()
        assertFalse("禁用态的添加卡不得触发 onClick", clicked)
    }
}
