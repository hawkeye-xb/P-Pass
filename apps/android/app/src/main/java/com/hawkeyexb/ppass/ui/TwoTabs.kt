// The design's two-tab shell: Photos and Backup, nothing else in the
// way. T-080 layout v1: flat bottom bar with a hairline on top; the
// active tab is ink + a 2dp top indicator, exactly as the design file.
//
// UI-13: 评估过 Material3 `NavigationBar`/`NavigationBarItem` 整体替换
// 这个底部栏容器——结论是**暂不换，理由记在这里**：`NavigationBarItem`
// 的选中态视觉语言是"图标背后一个胶囊形高亮指示器"，跟设计稿的"顶部
// 2dp 墨色细线 + 图标/文字变墨色加粗"是两套不同的选中态表达方式，替换
// 不是机械的组件替换，是一次需要视觉签字确认的改动（本卡范围是"手写→
// 组件"的等价替换，不含重新设计选中态）。图标本体和角标已改用真实
// Material3 组件（见下），点击态改进的空间留给这一处；若产品后续认可
// 胶囊指示器的选中态，再拆一张卡专门做这个视觉决策。
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
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
    // UI-04a/c: 全局唯一提示呈现层。调用方（MainActivity）把已算好
    // 最高优先级的那一条 HomeNotice 包进这个 slot，这里只是渲染。
    // 放在 Box 上方，让它在 Photos 页和 Backup 页都可见——这就是
    // 「中断提示不再只有总览」的最小实现：一个宿主，而不是各页各拼一个。
    notice: (@Composable () -> Unit)? = null,
) {
    PPScreen {
        Column(Modifier.fillMaxSize()) {
            if (notice != null) {
                Box(Modifier.fillMaxWidth().padding(20.dp, 12.dp, 20.dp, 0.dp)) { notice() }
            }
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
                        icon = { tint ->
                            // UI-13: 齿轮手绘 Canvas 已删除——material-icons-core
                            // 自带 Settings，零额外体积（随 material3 传递依赖）。
                            Icon(Icons.Filled.Settings, contentDescription = null, tint = tint)
                        },
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
            // UI-13: 手写的 8dp 圆点 Box 换成 Material3 Badge/BadgedBox——
            // 角标现在带无障碍语义（读屏能读出"有未处理事项"），触发条件
            // 不变（settingsAlert，MOB-68 红线不动）。
            if (alert) {
                BadgedBox(badge = { Badge(containerColor = PPColor.Act) }) { icon(tint) }
            } else {
                icon(tint)
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
