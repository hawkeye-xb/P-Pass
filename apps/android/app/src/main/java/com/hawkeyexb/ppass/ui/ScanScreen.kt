// M2/M3（全页面状态稿）：暗底扫码页——顶部窄标题栏 + X 关闭（代替
// "取消"按钮）；取景框是四角括号 + 中线，不是简单描边方框；底部只有
// 一行文字链接切到独立的"输入配对串"子页（M3），不是内联展开。
// CameraX analysis frames decode through ZXing (pure Java, no Play
// Services — HarmonyOS-safe).
package com.hawkeyexb.ppass.ui

import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.hawkeyexb.ppass.R
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private fun decodeQr(image: ImageProxy, reader: MultiFormatReader): String? {
    val plane = image.planes[0]
    val bytes = ByteArray(plane.buffer.remaining()).also { plane.buffer.get(it) }
    val source = PlanarYUVLuminanceSource(
        bytes, plane.rowStride, image.height,
        0, 0, plane.rowStride, image.height, false,
    )
    return try {
        reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
    } catch (_: Exception) {
        null
    } finally {
        reader.reset()
    }
}

/** M2 取景框：四角括号 + 中线（设计稿样式），不是简单描边方框。 */
@Composable
private fun ViewfinderFrame(modifier: Modifier = Modifier) {
    Canvas(modifier.size(240.dp)) {
        val arm = 36.dp.toPx()
        val stroke = 3.5.dp.toPx()
        val w = size.width
        val h = size.height
        val color = PPColor.Safe
        // 四角 L 形括号
        drawLine(color, Offset(0f, 0f), Offset(arm, 0f), stroke, cap = StrokeCap.Round)
        drawLine(color, Offset(0f, 0f), Offset(0f, arm), stroke, cap = StrokeCap.Round)
        drawLine(color, Offset(w, 0f), Offset(w - arm, 0f), stroke, cap = StrokeCap.Round)
        drawLine(color, Offset(w, 0f), Offset(w, arm), stroke, cap = StrokeCap.Round)
        drawLine(color, Offset(0f, h), Offset(arm, h), stroke, cap = StrokeCap.Round)
        drawLine(color, Offset(0f, h), Offset(0f, h - arm), stroke, cap = StrokeCap.Round)
        drawLine(color, Offset(w, h), Offset(w - arm, h), stroke, cap = StrokeCap.Round)
        drawLine(color, Offset(w, h), Offset(w, h - arm), stroke, cap = StrokeCap.Round)
        // 中线（设计稿的扫描线）
        val inset = 16.dp.toPx()
        drawLine(
            color, Offset(inset, h / 2), Offset(w - inset, h / 2),
            2.dp.toPx(), cap = StrokeCap.Round,
        )
    }
}

@Composable
fun ScanScreen(onQr: (String) -> Unit, onCancel: () -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val delivered = remember { AtomicBoolean(false) }
    val executor = remember { Executors.newSingleThreadExecutor() }
    val reader = remember {
        MultiFormatReader().apply {
            setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE)))
        }
    }
    // H-10b/M3: 手动输入配对串（扫码扫不出的退路——二维码太密/摄像头差
    // 时），M3 是独立子页，不是内联展开。
    var manual by remember { mutableStateOf(false) }
    var input by remember { mutableStateOf("") }
    var inputError by remember { mutableStateOf(false) }

    if (manual) {
        ManualPairScreen(
            input = input,
            onInputChange = { input = it; inputError = false },
            error = inputError,
            onBack = { manual = false },
            onSubmit = {
                if (input.trim().startsWith("ppf://pair")) {
                    onQr(input.trim())
                } else {
                    inputError = true
                }
            },
        )
        return
    }

    PPScreen(background = PPColor.SurfaceDark) {
        Column(Modifier.fillMaxSize()) {
            // M2 头部：X 关闭（代替"取消"按钮）+ 居中标题 + 对称占位。
            Row(
                Modifier.fillMaxWidth().padding(20.dp, 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "✕", fontSize = 18.sp, color = PPColor.Paper,
                    modifier = Modifier.clickable(onClick = onCancel).padding(4.dp),
                )
                Text(
                    stringResource(R.string.scan_header_title),
                    fontSize = 15.sp, fontWeight = FontWeight.Bold, color = PPColor.Paper,
                    modifier = Modifier.weight(1f), textAlign = TextAlign.Center,
                )
                Spacer(Modifier.width(20.dp))
            }

            // 设计稿：取景窗口是固定 240dp 圆角方框，不是铺满全屏——窗口
            // 之外是纯黑背景（PPScreen 已经是 SurfaceDark），摄像头画面
            // 本身也裁到这个窗口里，不是裁剪只套在装饰框上而画面照样
            // 铺满全屏（那样黑底区域会全被摄像头画面占掉，跟设计稿的
            // "小窗口+大片纯黑"对不上）。
            Box(
                Modifier.weight(1f).fillMaxWidth(),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    // 裁剪只套在摄像头预览本身上——外层 Box 若也裁一次，
                    // 240dp 方框的圆角遮罩会把 ViewfinderFrame 画在方框
                    // 物理边缘（0,0 ~ w,h）上的四角括号尖角一并削掉，绿色
                    // 取景框看起来"缺了角"（用户实机反馈"圆角被截断了"）。
                    Box(
                        Modifier.size(240.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        AndroidView(
                            modifier = Modifier.fillMaxSize().clip(RoundedCornerShape(20.dp)),
                            factory = { ctx ->
                                val view = PreviewView(ctx)
                                val future = ProcessCameraProvider.getInstance(ctx)
                                future.addListener({
                                    val provider = future.get()
                                    val preview = Preview.Builder().build().also {
                                        it.surfaceProvider = view.surfaceProvider
                                    }
                                    val analysis = ImageAnalysis.Builder()
                                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                                        .build()
                                    analysis.setAnalyzer(executor) { image ->
                                        val text = decodeQr(image, reader)
                                        image.close()
                                        if (text != null && text.startsWith("ppf://pair") &&
                                            delivered.compareAndSet(false, true)
                                        ) {
                                            ContextCompat.getMainExecutor(ctx).execute { onQr(text) }
                                        }
                                    }
                                    provider.unbindAll()
                                    provider.bindToLifecycle(
                                        lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA,
                                        preview, analysis,
                                    )
                                }, ContextCompat.getMainExecutor(ctx))
                                view
                            },
                        )
                        ViewfinderFrame()
                    }
                    Spacer(Modifier.height(24.dp))
                    Text(
                        stringResource(R.string.scan_hint),
                        fontSize = 15.sp, lineHeight = 24.sp,
                        color = PPColor.PaperDim, textAlign = TextAlign.Center,
                    )
                }
            }

            // M2 底部：纯文字链接，不是按钮——切到 M3 独立子页。
            Text(
                stringResource(R.string.scan_manual_link),
                fontSize = 14.sp, fontWeight = FontWeight.Bold, color = PPColor.PaperDim,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth()
                    .clickable { manual = true }
                    .padding(26.dp, 8.dp, 26.dp, 28.dp),
            )
        }
    }
}

/** M3（全页面状态稿）：独立子页——说明段 + 单行粘贴框 + 提示 + 主按钮。 */
@Composable
private fun ManualPairScreen(
    input: String,
    onInputChange: (String) -> Unit,
    error: Boolean,
    onBack: () -> Unit,
    onSubmit: () -> Unit,
) {
    val context = LocalContext.current
    PPScreen {
        Column(Modifier.fillMaxSize().padding(24.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "‹", fontSize = 24.sp, color = PPColor.Ink,
                    modifier = Modifier.clickable(onClick = onBack).padding(4.dp, 0.dp, 10.dp, 0.dp),
                )
                Text(
                    stringResource(R.string.scan_manual_title),
                    fontSize = 24.sp, fontFamily = FontFamily.Serif, color = PPColor.Ink,
                )
            }
            Spacer(Modifier.height(18.dp))
            Text(
                stringResource(R.string.scan_manual_body),
                fontSize = 14.5.sp, lineHeight = 24.sp, color = PPColor.Ink60,
            )
            Spacer(Modifier.height(16.dp))
            Column(
                Modifier.fillMaxWidth()
                    .background(PPColor.Paper, RoundedCornerShape(PPSize.RadiusCard))
                    .border(1.5.dp, PPColor.BorderStrong, RoundedCornerShape(PPSize.RadiusCard)),
            ) {
                Column(Modifier.padding(16.dp)) {
                    // 真实可编辑输入框——之前误用 Text 纯展示，既打不了字也
                    // 长按不出系统粘贴菜单（用户实机反馈的真 bug）；
                    // BasicTextField 自带长按选择/粘贴工具条，不用自己接。
                    androidx.compose.foundation.text.BasicTextField(
                        value = input,
                        onValueChange = onInputChange,
                        singleLine = true,
                        textStyle = androidx.compose.ui.text.TextStyle(
                            fontSize = 15.sp, fontFamily = FontFamily.Monospace, color = PPColor.Ink,
                        ),
                        cursorBrush = androidx.compose.ui.graphics.SolidColor(PPColor.Ink),
                        modifier = Modifier.fillMaxWidth(),
                        decorationBox = { innerTextField ->
                            Box {
                                if (input.isEmpty()) {
                                    Text(
                                        stringResource(R.string.scan_manual_placeholder),
                                        fontSize = 15.sp, fontFamily = FontFamily.Monospace,
                                        color = PPColor.Ink40,
                                    )
                                }
                                innerTextField()
                            }
                        },
                    )
                    Spacer(Modifier.height(10.dp))
                    OutlinedButton(
                        onClick = {
                            val clip = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE)
                                    as? android.content.ClipboardManager
                            clip?.primaryClip?.getItemAt(0)?.text?.toString()?.let(onInputChange)
                        },
                        modifier = Modifier.height(38.dp),
                        shape = RoundedCornerShape(999.dp),
                        border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.BorderStrong),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(14.dp, 0.dp),
                    ) { Text(stringResource(R.string.scan_manual_paste), fontSize = 13.sp, color = PPColor.Ink60) }
                }
            }
            if (error) {
                Spacer(Modifier.height(10.dp))
                Text(
                    stringResource(R.string.scan_manual_invalid),
                    color = PPColor.Act, fontSize = 14.sp,
                )
            }
            Spacer(Modifier.height(14.dp))
            Text(
                stringResource(R.string.scan_manual_note),
                fontSize = 13.sp, lineHeight = 20.sp, color = PPColor.Ink40,
            )
            Spacer(Modifier.weight(1f))
            Button(
                onClick = onSubmit,
                modifier = Modifier.fillMaxWidth().height(60.dp),
                shape = RoundedCornerShape(PPSize.RadiusControl),
                colors = ButtonDefaults.buttonColors(
                    containerColor = PPColor.Ink, contentColor = PPColor.Paper
                ),
            ) {
                Text(
                    stringResource(R.string.scan_manual_submit),
                    fontSize = 18.sp, fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}
