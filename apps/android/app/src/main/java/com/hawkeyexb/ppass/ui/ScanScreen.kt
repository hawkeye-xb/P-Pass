// T-052 scan screen — dark surface, one green frame, auto-detect only
// (design: "No shutter, no focus tap"). CameraX analysis frames decode
// through ZXing (pure Java, no Play Services — HarmonyOS-safe).
package com.hawkeyexb.ppass.ui

import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
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
    // H-10b: 手动输入配对码（扫码扫不出的退路——二维码太密/摄像头差时）。
    var manual by remember { mutableStateOf(false) }
    var input by remember { mutableStateOf("") }
    var inputError by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().background(PPColor.SurfaceDark).padding(24.dp)) {
        Text(
            stringResource(R.string.scan_title),
            fontSize = 30.sp, fontFamily = FontFamily.Serif, color = PPColor.Paper,
        )
        Spacer(Modifier.height(20.dp))

        if (manual) {
            // 手动输入区：粘贴配对码 → 提交（与扫码同一 onQr 入口）
            Column(
                Modifier.weight(1f).fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                OutlinedTextField(
                    value = input,
                    onValueChange = {
                        input = it
                        inputError = false
                    },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text(stringResource(R.string.scan_manual_hint), color = PPColor.PaperDim) },
                    textStyle = androidx.compose.ui.text.TextStyle(
                        color = PPColor.Paper, fontSize = 14.sp,
                        fontFamily = FontFamily.Monospace,
                    ),
                    shape = RoundedCornerShape(PPSize.RadiusControl),
                    minLines = 3, maxLines = 5,
                )
                if (inputError) {
                    Text(
                        stringResource(R.string.scan_manual_invalid),
                        color = PPColor.Act, fontSize = 14.sp,
                        modifier = Modifier.padding(top = 10.dp),
                    )
                }
                Spacer(Modifier.height(16.dp))
                OutlinedButton(
                    onClick = {
                        val clip = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE)
                                as? android.content.ClipboardManager
                        clip?.primaryClip?.getItemAt(0)?.text?.toString()?.let {
                            input = it
                            inputError = false
                        }
                    },
                    modifier = Modifier.fillMaxWidth().height(54.dp),
                    shape = RoundedCornerShape(PPSize.RadiusControl),
                    border = androidx.compose.foundation.BorderStroke(1.5.dp, PPColor.PaperDim),
                ) { Text(stringResource(R.string.scan_manual_paste), fontSize = 17.sp, color = PPColor.Paper) }
                Spacer(Modifier.height(12.dp))
                OutlinedButton(
                    onClick = {
                        if (input.trim().startsWith("ppf://pair")) {
                            onQr(input.trim())
                        } else {
                            inputError = true
                        }
                    },
                    modifier = Modifier.fillMaxWidth().height(58.dp),
                    shape = RoundedCornerShape(PPSize.RadiusControl),
                    border = androidx.compose.foundation.BorderStroke(1.5.dp, PPColor.Safe),
                ) { Text(stringResource(R.string.scan_manual_submit), fontSize = 18.sp, color = PPColor.Safe) }
            }
        } else {
            Box(
                Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(28.dp)),
                contentAlignment = Alignment.Center,
            ) {
                AndroidView(
                    modifier = Modifier.fillMaxSize(),
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
                // The one green frame — the only meaning colour on screen.
                Box(Modifier.size(236.dp).border(3.dp, PPColor.Safe, RoundedCornerShape(24.dp)))
                Text(
                    stringResource(R.string.scan_hint),
                    modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 26.dp),
                    fontSize = PPSize.BodyMin, lineHeight = 25.sp,
                    color = PPColor.PaperDim, textAlign = TextAlign.Center,
                )
            }
        }

        Spacer(Modifier.height(18.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton(
                onClick = { manual = !manual },
                modifier = Modifier.weight(1f).height(54.dp),
                shape = RoundedCornerShape(PPSize.RadiusControl),
                border = androidx.compose.foundation.BorderStroke(1.5.dp, PPColor.PaperDim),
            ) {
                Text(
                    stringResource(if (manual) R.string.scan_manual_back else R.string.scan_manual),
                    fontSize = 16.sp, color = PPColor.Paper,
                )
            }
            OutlinedButton(
                onClick = onCancel,
                modifier = Modifier.weight(1f).height(54.dp),
                shape = RoundedCornerShape(PPSize.RadiusControl),
                border = androidx.compose.foundation.BorderStroke(1.5.dp, PPColor.PaperDim),
            ) { Text(stringResource(R.string.cancel), fontSize = 16.sp, color = PPColor.Paper) }
        }
        Spacer(Modifier.height(14.dp))
    }
}
