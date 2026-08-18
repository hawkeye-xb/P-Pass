// 设计稿 M7-M13：底部 tab 每一张都画了图标（相机/齿轮），手绘 Canvas
// 图标，不新引入图标库（ICON-02 卡另算，避免两条线打架）。
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
import androidx.compose.ui.graphics.drawscope.rotate
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

/**
 * 设置 tab 图标：环 + 8 颗齿（对应设计稿齿轮 glyph；用规则齿简化原稿
 * 的贝塞尔外轮廓，手绘 Canvas 场景下更稳，视觉上仍是一望而知的齿轮）。
 */
@Composable
fun SettingsTabIcon(tint: Color, modifier: Modifier = Modifier) {
    Canvas(modifier.size(22.dp)) {
        val s = size.width / 24f
        val stroke = Stroke(width = 1.8f * s, cap = StrokeCap.Round, join = StrokeJoin.Round)
        val center = Offset(12f * s, 12f * s)
        drawCircle(color = tint, radius = 3f * s, center = center, style = stroke)
        drawCircle(color = tint, radius = 6.4f * s, center = center, style = stroke)
        repeat(8) { i ->
            rotate(degrees = i * 45f, pivot = center) {
                drawLine(
                    color = tint,
                    start = Offset(center.x, center.y - 6.4f * s),
                    end = Offset(center.x, center.y - 8.6f * s),
                    strokeWidth = 1.8f * s,
                    cap = StrokeCap.Round,
                )
            }
        }
    }
}
