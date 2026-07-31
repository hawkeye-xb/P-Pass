// T-052: pairing flow — welcome → camera scan → waiting for Allow →
// joined. Paired phones land on a minimal home (T-055 builds it out).
package com.hawkeyexb.ppass

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.PairOutcome
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PairingStore
import com.hawkeyexb.ppass.transport.pairWithQr
import com.hawkeyexb.ppass.ui.JoinedScreen
import com.hawkeyexb.ppass.ui.PairStatusScreen
import com.hawkeyexb.ppass.ui.ScanScreen
import com.hawkeyexb.ppass.ui.WelcomeScreen

private sealed class Screen {
    data object Welcome : Screen()
    data object Scan : Screen()
    data class Waiting(val qr: String) : Screen()
    data class Joined(val pairing: Pairing) : Screen()
    data class Trouble(val title: String, val titleZh: String, val body: String) : Screen()
    data class Home(val pairing: Pairing) : Screen()
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { PPassApp() }
    }
}

@Composable
fun PPassApp() {
    val context = LocalContext.current
    val identity = remember { IdentityStore(context.filesDir) }
    val pairings = remember { PairingStore(context.filesDir) }
    val client = remember { DaemonClient() }

    var screen by remember {
        mutableStateOf<Screen>(pairings.load()?.let { Screen.Home(it) } ?: Screen.Welcome)
    }

    val cameraPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted -> if (granted) screen = Screen.Scan }

    when (val s = screen) {
        is Screen.Welcome -> WelcomeScreen(onScan = {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
                == PackageManager.PERMISSION_GRANTED
            ) {
                screen = Screen.Scan
            } else {
                cameraPermission.launch(Manifest.permission.CAMERA)
            }
        })

        is Screen.Scan -> ScanScreen(
            onQr = { qr -> screen = Screen.Waiting(qr) },
            onCancel = { screen = Screen.Welcome },
        )

        is Screen.Waiting -> {
            PairStatusScreen(
                title = "Asking the computer…",
                titleZh = "正在请求加入",
                body = "On the computer, click Allow when it asks.\n回到电脑，在弹出的请求上点「允许」。",
                action = null,
            )
            LaunchedEffect(s.qr) {
                // Catch Throwable, not Exception: a missing native lib
                // (UnsatisfiedLinkError) must land on the trouble screen,
                // never crash the app (real-phone T-052 lesson).
                val outcome = try {
                    client.bind(identity.secretKey())
                    pairWithQr(client, s.qr, deviceName())
                } catch (t: Throwable) {
                    PairOutcome.Failed(t.toString())
                }
                screen = when (outcome) {
                    is PairOutcome.Joined -> {
                        pairings.save(outcome.pairing)
                        Screen.Joined(outcome.pairing)
                    }
                    is PairOutcome.Refused -> Screen.Trouble(
                        "The computer said no.", "电脑拒绝了这次加入",
                        "Ask the family owner to generate a fresh code and try again.\n请管理员重新生成二维码后再试一次。",
                    )
                    is PairOutcome.Failed -> Screen.Trouble(
                        "Could not reach the computer.", "没能连上电脑",
                        "Make sure the computer is on and both devices have internet, then scan again.\n确认电脑开着、两边都能上网，然后重新扫码。\n(${outcome.reason.take(120)})",
                    )
                }
            }
        }

        is Screen.Joined -> JoinedScreen(
            storageName = s.pairing.storageDeviceName,
            onDone = { screen = Screen.Home(s.pairing) },
        )

        is Screen.Trouble -> PairStatusScreen(
            title = s.title, titleZh = s.titleZh, body = s.body,
            action = "Scan again 重新扫码" to { screen = Screen.Scan },
        )

        is Screen.Home -> PairStatusScreen(
            title = "Connected to ${s.pairing.storageDeviceName}.",
            titleZh = "已连接「${s.pairing.storageDeviceName}」",
            body = "Backup starts with the next milestone (T-053/54).\n备份功能随下一里程碑到来。",
            action = null,
        )
    }
}

private fun deviceName(): String {
    val m = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android"
    return m
}
