// P-Pass 的 Material3 主题：把 PPColor 映射进 M3 colorScheme 的每个槽位。
//
// 没有这一层时，所有没显式传颜色的 M3 组件都落到 M3 基线配色（开关开启
// 是紫色 #6750A4、对话框底是偏紫的浅灰、TextButton 文字是紫色）。在根部
// 包一层主题，是 Compose 的标准做法：组件默认色从这里取，一处堵住全部默认色。
//
// 对齐 iOS 的两层结构：根部 tint = ink（PPassApp.swift / RootView.swift），
// 设置页 Toggle 单独 tint = safe（SettingsScreen.swift）。所以这里
// primary = Ink（tokens.json：ink 是「文字与主按钮」），开关的 Safe 在
// RuleSwitchRow 里单独给——不用 primary = Safe：那会让「取消」「去设置」
// 这类没传色的 TextButton 也变绿，违反「绿色只表示安全」。
//
// 只有浅色：P-Pass 没有暗色设计；也绝不用 dynamicColorScheme（三星会按壁纸取色）。
package com.hawkeyexb.ppass.ui

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

/** 槽位成对给全：contentColorFor(bg) 按 scheme 查表，漏了 on- 色会让现有 Surface 的内容色变。 */
val PPColorScheme: ColorScheme = lightColorScheme(
    primary = PPColor.Ink,
    onPrimary = PPColor.Paper,
    primaryContainer = PPColor.Linen,
    onPrimaryContainer = PPColor.Ink,
    inversePrimary = PPColor.Paper,
    secondary = PPColor.Ink60,
    onSecondary = PPColor.Paper,
    secondaryContainer = PPColor.Linen,
    onSecondaryContainer = PPColor.Ink,
    tertiary = PPColor.Ink60,
    onTertiary = PPColor.Paper,
    tertiaryContainer = PPColor.Linen,
    onTertiaryContainer = PPColor.Ink,
    background = PPColor.Paper,
    onBackground = PPColor.Ink,
    surface = PPColor.Paper,
    onSurface = PPColor.Ink,
    surfaceVariant = PPColor.Linen,
    onSurfaceVariant = PPColor.Ink60,
    // tonalElevation 叠色用 Paper 叠 Paper，等于不叠。
    surfaceTint = PPColor.Paper,
    inverseSurface = PPColor.Ink,
    inverseOnSurface = PPColor.Paper,
    error = PPColor.Act,
    onError = PPColor.Paper,
    errorContainer = PPColor.ActBg,
    onErrorContainer = PPColor.Act,
    // 开关关闭态：滑块与描边取 outline，轨道取 surfaceContainerHighest。
    outline = PPColor.Ink40,
    outlineVariant = PPColor.Divider,
    surfaceBright = PPColor.Paper,
    surfaceDim = PPColor.Canvas,
    // AlertDialog 底取 surfaceContainerHigh——与界面同一张纸。
    surfaceContainerLowest = PPColor.Paper,
    surfaceContainerLow = PPColor.Paper,
    surfaceContainer = PPColor.Paper,
    surfaceContainerHigh = PPColor.Paper,
    surfaceContainerHighest = PPColor.Hairline,
)

@Composable
fun PPTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = PPColorScheme, content = content)
}
