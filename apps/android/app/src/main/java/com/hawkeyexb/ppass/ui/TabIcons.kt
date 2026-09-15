// UI-13: 齿轮图标已删除，改用 Icons.Filled.Settings/Icons.Outlined.Settings
// （material-icons-core，随 material3 传递依赖，零体积增量，见
// build.gradle.kts 的依赖注释）。相机图标继续手绘——material-icons-core
// 的 49 图标集里没有相机/相册类图标（`unzip -l` 实测核对过完整清单），
// 而 material-icons-extended 在 build.gradle.kts 里已有明确记录的架构
// 决策：**故意不引**（release 未开 R8，extended 会实打实往 APK 里塞
// 几 MB，为一两个图标不划算）。为了一个相机图标反悔这条决策，不在本卡
// 授权范围内——这不是"忘了处理"的死角，是评估过后的真实约束。
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp

/** 照片 tab 图标：机身 + 镜头 + 取景线（对应设计稿相机 glyph）。 */
@Composable
fun PhotosTabIcon(tint: Color, modifier: Modifier = Modifier) {
    Canvas(modifier.size(22.dp)) {
        val s = size.width / 24f
        val stroke = Stroke(width = 1.8f * s, cap = StrokeCap.Round, join = StrokeJoin.Round)
        drawRoundRect(
            color = tint,
            topLeft = Offset(3f * s, 4f * s),
            size = Size(18f * s, 16f * s),
            cornerRadius = CornerRadius(2.5f * s, 2.5f * s),
            style = stroke,
        )
        drawCircle(color = tint, radius = 1.8f * s, center = Offset(9f * s, 10f * s), style = stroke)
        val path = Path().apply {
            moveTo(21f * s, 15.5f * s)
            lineTo(16.5f * s, 11f * s)
            lineTo(8f * s, 19.5f * s)
        }
        drawPath(path, color = tint, style = stroke)
    }
}
