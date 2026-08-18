// The design's two-tab shell: Photos and Backup, nothing else in the
// way. T-080 layout v1: flat bottom bar with a hairline on top; the
// active tab is ink + a 2dp top indicator, exactly as the design file.
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
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
@Composable
fun TwoTabs(
    tab: Int,
    onTab: (Int) -> Unit,
    photos: @Composable () -> Unit,
    backup: @Composable () -> Unit,
    showTabBar: Boolean = true,
    // M13 哨兵态：长期失联时设置图标角标一个红点（不是文字变色/变红——
    // 那个方案照的是过时设计稿快照，已在 798b7ae 里被官方最新稿否掉）。
    settingsAlert: Boolean = false,
) {
    PPScreen {
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f)) {
                if (tab == 0) photos() else backup()
            }
            if (showTabBar) {
                HorizontalDivider(color = PPColor.Border)
                Row(Modifier.fillMaxWidth().height(64.dp).background(PPColor.Paper)) {
                    TabCell(
                        stringResource(R.string.tab_photos), tab == 0, Modifier.weight(1f),
                        icon = { tint -> PhotosTabIcon(tint) },
                    ) { onTab(0) }
                    TabCell(
                        stringResource(R.string.tab_settings), tab == 1, Modifier.weight(1f),
                        icon = { tint -> SettingsTabIcon(tint) },
                        alert = settingsAlert,
                    ) { onTab(1) }
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
    val tint = if (selected) PPColor.Ink else PPColor.Ink40
    Column(modifier.fillMaxHeight().clickable(onClick = onClick)) {
        Box(
            Modifier.fillMaxWidth().height(2.dp)
                .background(if (selected) PPColor.Ink else Color.Transparent)
        )
        Column(
            Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Box {
                icon(tint)
                if (alert) {
                    Box(
                        Modifier
                            .align(Alignment.TopEnd)
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(PPColor.Act),
                    )
                }
            }
            Spacer(Modifier.height(3.dp))
            Text(
                label,
                fontSize = 11.5.sp,
                fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                color = tint,
            )
        }
    }
}
