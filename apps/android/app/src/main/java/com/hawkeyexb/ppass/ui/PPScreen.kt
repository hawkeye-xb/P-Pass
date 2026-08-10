// MOB-01: 全应用唯一的安全区容器（edge-to-edge 配套，2026-08-11）。
//
// 背景铺满整屏（含系统栏区域），内容整体让出 status bar / navigation
// bar / display cutout / IME——手势导航与三键导航由 WindowInsets 天然
// 区分，不许逐页手搓 insets（三星真机底部导航键遮挡 bug 的根治）。
// 系统栏图标深浅随背景亮度自动切换：ScanScreen/查看器深底用浅色图标，
// Paper 页面用深色图标（enableEdgeToEdge 后默认只跟系统主题，深色页面
// 上会隐形，这里一处统一）。
package com.hawkeyexb.ppass.ui

import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

@Composable
fun PPScreen(
    background: Color = PPColor.Paper,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as? Activity)?.window ?: return@SideEffect
            val lightIcons = background.luminance() < 0.5f
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !lightIcons
                isAppearanceLightNavigationBars = !lightIcons
            }
        }
    }
    Box(
        modifier
            .fillMaxSize()
            .background(background)
            .safeDrawingPadding(),
    ) { content() }
}
