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
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
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

    Column(Modifier.fillMaxSize().background(PPColor.SurfaceDark).padding(24.dp)) {
        Text(
            "Point at the computer screen.",
            fontSize = 30.sp, fontFamily = FontFamily.Serif, color = PPColor.Paper,
        )
        Spacer(Modifier.height(6.dp))
        Text("对准电脑屏幕上的二维码", fontSize = 19.sp, color = PPColor.PaperDim)
        Spacer(Modifier.height(20.dp))

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
                "Hold steady — it reads by itself.\n拿稳就行，会自动识别。",
                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 26.dp),
                fontSize = PPSize.BodyMin, lineHeight = 25.sp,
                color = PPColor.PaperDim, textAlign = TextAlign.Center,
            )
        }

        Spacer(Modifier.height(18.dp))
        OutlinedButton(
            onClick = onCancel,
            modifier = Modifier.fillMaxWidth().height(58.dp),
            shape = RoundedCornerShape(PPSize.RadiusControl),
            border = androidx.compose.foundation.BorderStroke(1.5.dp, PPColor.PaperDim),
        ) { Text("Cancel 取消", fontSize = 18.sp, color = PPColor.Paper) }
        Spacer(Modifier.height(14.dp))
    }
}
