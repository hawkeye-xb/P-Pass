// UI-13 / #2082: 照片与备份两个底部 Tab 图标均用 22.dp 等粗线稿手绘在 Canvas 里，
// 零 material-icons-extended 体积增量，且严格不使用任何云朵形状（符合「不存云端」红线）。
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

/** 备份 tab 图标：双弧循环箭头（对位 iOS arrow.triangle.2.circlepath，非云朵图标）。 */
@Composable
fun BackupTabIcon(tint: Color, modifier: Modifier = Modifier) {
    Canvas(modifier.size(22.dp)) {
        val s = size.width / 24f
        val stroke = Stroke(width = 1.8f * s, cap = StrokeCap.Round, join = StrokeJoin.Round)
        val arcBoxTopLeft = Offset(4f * s, 4f * s)
        val arcBoxSize = Size(16f * s, 16f * s)
        drawArc(
            color = tint,
            startAngle = -145f,
            sweepAngle = 130f,
            useCenter = false,
            topLeft = arcBoxTopLeft,
            size = arcBoxSize,
            style = stroke,
        )
        val topArrow = Path().apply {
            moveTo(17.0f * s, 8.8f * s)
            lineTo(19.73f * s, 9.93f * s)
            lineTo(21.0f * s, 7.3f * s)
        }
        drawPath(topArrow, color = tint, style = stroke)
        drawArc(
            color = tint,
            startAngle = 35f,
            sweepAngle = 130f,
            useCenter = false,
            topLeft = arcBoxTopLeft,
            size = arcBoxSize,
            style = stroke,
        )
        val bottomArrow = Path().apply {
            moveTo(7.0f * s, 15.2f * s)
            lineTo(4.27f * s, 14.07f * s)
            lineTo(3.0f * s, 16.7f * s)
        }
        drawPath(bottomArrow, color = tint, style = stroke)
    }
}
