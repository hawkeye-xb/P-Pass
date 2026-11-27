// 照片与备份两个底部 Tab 图标均在 22.dp Canvas 内绘制，零 material-icons-extended 体积增量，
// 严格不使用云朵形状（符合「不存云端」红线），并以线框/实心强调形态区分未选中与选中态。
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
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp

internal enum class TabIconRenderMode {
    OUTLINED,
    FILLED,
}

internal data class PhotosTabIconSpec(
    val mode: TabIconRenderMode,
    val strokeWidthUnits: Float,
    val detailColor: Color?,
)

internal data class BackupTabIconSpec(
    val mode: TabIconRenderMode,
    val strokeWidthUnits: Float,
    val arcSweepDegrees: Float,
    val filledArrowHeads: Boolean,
)

internal fun photosTabIconSpec(
    selected: Boolean,
    detailColor: Color = PPColor.Paper,
): PhotosTabIconSpec =
    if (selected) {
        PhotosTabIconSpec(
            mode = TabIconRenderMode.FILLED,
            strokeWidthUnits = 0f,
            detailColor = detailColor,
        )
    } else {
        PhotosTabIconSpec(
            mode = TabIconRenderMode.OUTLINED,
            strokeWidthUnits = 1.8f,
            detailColor = null,
        )
    }

internal fun backupTabIconSpec(selected: Boolean): BackupTabIconSpec =
    if (selected) {
        BackupTabIconSpec(
            mode = TabIconRenderMode.FILLED,
            strokeWidthUnits = 2.5f,
            arcSweepDegrees = 120f,
            filledArrowHeads = true,
        )
    } else {
        BackupTabIconSpec(
            mode = TabIconRenderMode.OUTLINED,
            strokeWidthUnits = 1.8f,
            arcSweepDegrees = 130f,
            filledArrowHeads = false,
        )
    }

/** 照片 tab 图标：未选中为线框相框，选中为实心相框配留白太阳与山峰剪影。 */
@Composable
fun PhotosTabIcon(
    tint: Color,
    selected: Boolean,
    modifier: Modifier = Modifier,
    detailColor: Color = PPColor.Paper,
) {
    val spec = photosTabIconSpec(selected = selected, detailColor = detailColor)
    Canvas(modifier.size(22.dp)) {
        val s = size.width / 24f
        val frameTopLeft = Offset(3f * s, 4f * s)
        val frameSize = Size(18f * s, 16f * s)
        val cornerRadius = CornerRadius(2.5f * s, 2.5f * s)
        when (spec.mode) {
            TabIconRenderMode.FILLED -> {
                val cutout = spec.detailColor ?: PPColor.Paper
                drawRoundRect(
                    color = tint,
                    topLeft = frameTopLeft,
                    size = frameSize,
                    cornerRadius = cornerRadius,
                    style = Fill,
                )
                drawCircle(
                    color = cutout,
                    radius = 1.65f * s,
                    center = Offset(8.6f * s, 9.4f * s),
                    style = Fill,
                )
                val mountain = Path().apply {
                    moveTo(5.4f * s, 17.6f * s)
                    lineTo(9.2f * s, 13.8f * s)
                    lineTo(11.2f * s, 15.6f * s)
                    lineTo(15.2f * s, 11.2f * s)
                    lineTo(18.6f * s, 17.6f * s)
                    close()
                }
                drawPath(mountain, color = cutout, style = Fill)
            }
            TabIconRenderMode.OUTLINED -> {
                val stroke = Stroke(
                    width = spec.strokeWidthUnits * s,
                    cap = StrokeCap.Round,
                    join = StrokeJoin.Round,
                )
                drawRoundRect(
                    color = tint,
                    topLeft = frameTopLeft,
                    size = frameSize,
                    cornerRadius = cornerRadius,
                    style = stroke,
                )
                drawCircle(
                    color = tint,
                    radius = 1.8f * s,
                    center = Offset(9f * s, 10f * s),
                    style = stroke,
                )
                val path = Path().apply {
                    moveTo(21f * s, 15.5f * s)
                    lineTo(16.5f * s, 11f * s)
                    lineTo(8f * s, 19.5f * s)
                }
                drawPath(path, color = tint, style = stroke)
            }
        }
    }
}

/** 备份 tab 图标：双弧循环箭头（对位 iOS arrow.triangle.2.circlepath，非云朵图标）；选中态加粗弧线并配实心箭头。 */
@Composable
fun BackupTabIcon(
    tint: Color,
    selected: Boolean,
    modifier: Modifier = Modifier,
) {
    val spec = backupTabIconSpec(selected = selected)
    Canvas(modifier.size(22.dp)) {
        val s = size.width / 24f
        val stroke = Stroke(
            width = spec.strokeWidthUnits * s,
            cap = StrokeCap.Round,
            join = StrokeJoin.Round,
        )
        val arcBoxTopLeft = Offset(4f * s, 4f * s)
        val arcBoxSize = Size(16f * s, 16f * s)
        drawArc(
            color = tint,
            startAngle = -145f,
            sweepAngle = spec.arcSweepDegrees,
            useCenter = false,
            topLeft = arcBoxTopLeft,
            size = arcBoxSize,
            style = stroke,
        )
        drawArc(
            color = tint,
            startAngle = 35f,
            sweepAngle = spec.arcSweepDegrees,
            useCenter = false,
            topLeft = arcBoxTopLeft,
            size = arcBoxSize,
            style = stroke,
        )
        if (spec.filledArrowHeads) {
            val topArrow = Path().apply {
                moveTo(19.95f * s, 11.0f * s)
                lineTo(21.7f * s, 7.2f * s)
                lineTo(16.7f * s, 8.7f * s)
                close()
            }
            drawPath(topArrow, color = tint, style = Fill)
            val bottomArrow = Path().apply {
                moveTo(4.05f * s, 13.0f * s)
                lineTo(2.3f * s, 16.8f * s)
                lineTo(7.3f * s, 15.3f * s)
                close()
            }
            drawPath(bottomArrow, color = tint, style = Fill)
        } else {
            val topArrow = Path().apply {
                moveTo(17.0f * s, 8.8f * s)
                lineTo(19.73f * s, 9.93f * s)
                lineTo(21.0f * s, 7.3f * s)
            }
            drawPath(topArrow, color = tint, style = stroke)
            val bottomArrow = Path().apply {
                moveTo(7.0f * s, 15.2f * s)
                lineTo(4.27f * s, 14.07f * s)
                lineTo(3.0f * s, 16.7f * s)
            }
            drawPath(bottomArrow, color = tint, style = stroke)
        }
    }
}
