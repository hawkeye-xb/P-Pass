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
import com.hawkeyexb.ppass.backup.BackupRunner
import com.hawkeyexb.ppass.backup.backupOnceNow
import com.hawkeyexb.ppass.backup.scheduleAutoBackup
import com.hawkeyexb.ppass.backup.BackupUiStateHolder
import com.hawkeyexb.ppass.ui.BackupUiState
import com.hawkeyexb.ppass.ui.HomeScreen
import com.hawkeyexb.ppass.ui.PhotosScreen
import com.hawkeyexb.ppass.ui.TimelineLoader
import com.hawkeyexb.ppass.ui.TwoTabs
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
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
    // Paired phones: periodic backup stays scheduled (idempotent KEEP)
    // and every app-open triggers one catch-up run — the phone backs
    // itself up without anyone finding a button.
    remember {
        if (pairings.load() != null) {
            scheduleAutoBackup(context)
            backupOnceNow(context)
        }
        true
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
                action = "Cancel 取消" to { screen = Screen.Welcome },
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
                // The user may have cancelled while we waited — a stale
                // result must not yank them out of another screen.
                if (screen != s) return@LaunchedEffect
                screen = when (outcome) {
                    is PairOutcome.Joined -> {
                        pairings.save(outcome.pairing)
                        scheduleAutoBackup(context)
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

        is Screen.Home -> {
            val holder = remember { BackupUiStateHolder(context, client, identity, s.pairing) }
            val loader = remember {
                TimelineLoader(client, parsePeerAddrToken(s.pairing.daemonAddrToken)) {
                    client.bind(identity.secretKey())
                }
            }
            var tab by remember { mutableStateOf(0) } // 0=Photos 1=Backup
            LaunchedEffect(Unit) { client.bind(identity.secretKey()) }
            val mediaPermission = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestMultiplePermissions()
            ) { grants -> if (grants.values.any { it }) holder.backupNow() }
            TwoTabs(
                tab = tab,
                onTab = { tab = it },
                photos = { PhotosScreen(loader) },
                backup = {
                    HomeScreen(
                        storageName = s.pairing.storageDeviceName,
                        state = holder.state.value,
                        onBackupNow = {
                            val needed = requiredMediaPermissions().filter {
                                ContextCompat.checkSelfPermission(context, it) !=
                                    PackageManager.PERMISSION_GRANTED
                            }
                            if (needed.isEmpty()) holder.backupNow()
                            else mediaPermission.launch(needed.toTypedArray())
                        },
                    )
                },
            )
        }
    }
}

private fun requiredMediaPermissions(): List<String> =
    if (Build.VERSION.SDK_INT >= 33) {
        listOf(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
        )
    } else {
        listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

private fun deviceName(): String {
    val m = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android"
    return m
}
