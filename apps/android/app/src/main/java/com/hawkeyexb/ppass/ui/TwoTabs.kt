// The two-tab shell (Photos and Backup): flat bottom bar with a top divider.
// Selected vs unselected state is expressed by color, label weight, and icon morphology.
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R

/**
 * [showTabBar] = false（2026-08-17，大图查看页导航修复）：查看大图时
 * 主 [照片]/[设置] tab 栏不应该出现——不是"盖住了看不见"，是根本不
 * 渲染（参考系统相册的惯例：网格页有主 tab 栏，进大图页换成大图页
 * 自己的操作行，不是两套导航叠在一起）。调用方（MainActivity）按
 * "是否正在看大图"传入，`photos`/`backup` 内容区不受影响，只是底部
 * 那一整条 tab 栏 Row 在 showTabBar=false 时不进组合树。
 */
/**
 * #1926：首页（照片/设置双 tab）与全屏媒体查看器共用 `TwoTabs` 唯一顶层 [PPScreen]。
 * 查看器打开时整屏（含顶部状态栏与底部导航栏安全区）切到 [PPColor.SurfaceDark]（浅色图标），
 * 退出查看器时立即切回 [PPColor.Paper]（深色图标），不再在子树里嵌套第二层 [PPScreen]。
 */
internal fun twoTabsBackground(viewerOpen: Boolean): Color =
    if (viewerOpen) PPColor.SurfaceDark else PPColor.Paper

internal data class TabCellStyle(
    val tint: Color,
    val fontWeight: FontWeight,
)

internal fun tabCellStyle(selected: Boolean): TabCellStyle =
    if (selected) {
        TabCellStyle(tint = PPColor.Ink, fontWeight = FontWeight.Bold)
    } else {
        TabCellStyle(tint = PPColor.Ink40, fontWeight = FontWeight.Medium)
    }

@Composable
fun TwoTabs(
    tab: Int,
    onTab: (Int) -> Unit,
    photos: @Composable () -> Unit,
    backup: @Composable () -> Unit,
    background: Color = PPColor.Paper,
    showTabBar: Boolean = true,
    // M13 哨兵态：长期失联时设置图标角标一个红点（不是文字变色/变红——
    // 那个方案照的是过时设计稿快照，已在 798b7ae 里被官方最新稿否掉）。
    settingsAlert: Boolean = false,
    // #1962：系统告示条不再挂在两个 Tab 的顶层——它只在「设置」页（HomeScreen 的
    // 备份 tab）里展示，与 iOS `SettingsScreen` 对齐。见 `HomeScreen(notice = …)`。
) {
    PPScreen(background = background) {
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f)) {
                if (tab == 0) photos() else backup()
            }
            if (showTabBar) {
                HorizontalDivider(color = PPColor.Border)
                Row(
                    Modifier
                        .fillMaxWidth()
                        .height(64.dp)
                        .background(PPColor.Paper)
                        .selectableGroup()
                        .testTag("two_tabs_bar"),
                ) {
                    TabCell(
                        label = stringResource(R.string.tab_photos),
                        selected = tab == 0,
                        modifier = Modifier.weight(1f).testTag("tab_cell_photos"),
                        icon = { tint ->
                            PhotosTabIcon(
                                tint = tint,
                                selected = tab == 0,
                                modifier = Modifier.testTag("tab_icon_photos"),
                            )
                        },
                        onClick = { onTab(0) },
                    )
                    TabCell(
                        label = stringResource(R.string.tab_settings),
                        selected = tab == 1,
                        modifier = Modifier.weight(1f).testTag("tab_cell_settings"),
                        icon = { tint ->
                            BackupTabIcon(
                                tint = tint,
                                selected = tab == 1,
                                modifier = Modifier.testTag("tab_icon_settings"),
                            )
                        },
                        alert = settingsAlert,
                        onClick = { onTab(1) },
                    )
                }
            }
        }
    }
}

@Composable
private fun TabCell(
    label: String,
    selected: Boolean,
    modifier: Modifier,
    icon: @Composable (Color) -> Unit,
    alert: Boolean = false,
    onClick: () -> Unit,
) {
    val style = tabCellStyle(selected)
    Column(
        modifier
            .fillMaxHeight()
            .selectable(
                selected = selected,
                role = Role.Tab,
                onClick = onClick,
            ),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        if (alert) {
            BadgedBox(
                badge = {
                    Badge(
                        containerColor = PPColor.Act,
                        modifier = Modifier.testTag("tab_alert_badge"),
                    )
                },
            ) { icon(style.tint) }
        } else {
            icon(style.tint)
        }
        Spacer(Modifier.height(3.dp))
        Text(
            label,
            fontSize = 11.5.sp,
            fontWeight = style.fontWeight,
            color = style.tint,
        )
    }
}
