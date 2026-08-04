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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.content.ContextCompat
import kotlinx.coroutines.launch
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.work.WorkManager
import kotlinx.coroutines.launch
import com.hawkeyexb.ppass.battery.isIgnoringBatteryOptimizations
import com.hawkeyexb.ppass.battery.openBatteryOptimizationSettings
import com.hawkeyexb.ppass.i18n.DiagText
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.PairOutcome
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PairingStore
import com.hawkeyexb.ppass.transport.pairWithQr
import com.hawkeyexb.ppass.backup.BackupRunner
import com.hawkeyexb.ppass.backup.BackupSettings
import com.hawkeyexb.ppass.backup.AutoBackupPrefs
import com.hawkeyexb.ppass.backup.backupOnceNow
import com.hawkeyexb.ppass.backup.rescheduleAutoBackup
import com.hawkeyexb.ppass.backup.scheduleAutoBackup
import com.hawkeyexb.ppass.backup.pauseAutoBackup
import com.hawkeyexb.ppass.backup.resumeAutoBackup
import com.hawkeyexb.ppass.backup.BACKUP_WORK_NAME
import com.hawkeyexb.ppass.backup.WatermarkStore
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
import com.hawkeyexb.ppass.update.UpdateInfo
import com.hawkeyexb.ppass.update.downloadAndInstall
import com.hawkeyexb.ppass.update.fetchUpdate

private sealed class Screen {
    data object Welcome : Screen()
    data object Scan : Screen()
    data class Waiting(val qr: String) : Screen()
    data class Joined(val pairing: Pairing) : Screen()
    data class Trouble(val titleRes: Int, val bodyRes: Int, val detail: String = "") : Screen()
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
    // UPD-01: 下载安装是 suspend（IO 线程下载）——按钮 onClick 从协程调。
    val scope = rememberCoroutineScope()
    val identity = remember { IdentityStore(context.filesDir) }
    val pairings = remember { PairingStore(context.filesDir) }
    val client = remember { DaemonClient() }

    var screen by remember {
        mutableStateOf<Screen>(pairings.load()?.let { Screen.Home(it) } ?: Screen.Welcome)
    }
    // Paired phones: periodic backup stays scheduled (idempotent KEEP)
    // and every app-open triggers one catch-up run — the phone backs
    // itself up without anyone finding a button. UX-06: 全局暂停态下
    // 两者都不跑（重开 App 不自动恢复，直到用户恢复开关）。
    remember {
        if (pairings.load() != null && !AutoBackupPrefs(context.filesDir).paused()) {
            scheduleAutoBackup(context)
            backupOnceNow(context)
        }
        true
    }

    val cameraPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted -> if (granted) screen = Screen.Scan }

    // UPD-01: 启动时检查一次更新（静默失败；draft/无 release = 无更新；
    // 对话框覆盖所有 screen，不打断当前流程）
    var updateInfo by remember { mutableStateOf<UpdateInfo?>(null) }
    LaunchedEffect(Unit) {
        updateInfo = fetchUpdate(BuildConfig.VERSION_NAME)
    }
    updateInfo?.let { info ->
        AlertDialog(
            onDismissRequest = { updateInfo = null },
            title = { Text("发现新版本 v${info.version}") },
            text = {
                Text(
                    if (info.notes.isBlank()) "是否下载并安装？" else info.notes.take(200)
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    scope.launch {
                        downloadAndInstall(context, info.url)
                        updateInfo = null
                    }
                }) { Text("下载安装") }
            },
            dismissButton = {
                TextButton(onClick = { updateInfo = null }) { Text("以后再说") }
            },
        )
    }

    // DOG-02: 电池白名单状态——ON_RESUME 刷新（从系统设置返回立即更新，
    // 加白后卡片消失；拒绝授权时保持卡片）
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    var batteryWhitelisted by remember { mutableStateOf(isIgnoringBatteryOptimizations(context)) }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                batteryWhitelisted = isIgnoringBatteryOptimizations(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

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
                title = androidx.compose.ui.res.stringResource(R.string.pair_waiting_title),
                body = androidx.compose.ui.res.stringResource(R.string.pair_waiting_body),
                action = androidx.compose.ui.res.stringResource(R.string.cancel) to
                    { screen = Screen.Welcome },
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
                        R.string.pair_refused_title,
                        R.string.pair_refused_body,
                        // T-072: 具体拒绝原因走 diag 字典（msg_key → 双语人话）
                        // 渲染在通用文案下方；未知 key 显示空详情，绝不崩溃。
                        DiagText.resolve(context, outcome.msgKey) ?: "",
                    )
                    is PairOutcome.Failed -> Screen.Trouble(
                        R.string.pair_failed_title, R.string.pair_failed_body,
                        "(${outcome.reason.take(160)})",
                    )
                }
            }
        }

        is Screen.Joined -> JoinedScreen(
            storageName = s.pairing.storageDeviceName,
            onDone = { screen = Screen.Home(s.pairing) },
        )

        is Screen.Trouble -> PairStatusScreen(
            title = androidx.compose.ui.res.stringResource(s.titleRes),
            body = androidx.compose.ui.res.stringResource(s.bodyRes) +
                if (s.detail.isNotEmpty()) "\n${s.detail}" else "",
            action = androidx.compose.ui.res.stringResource(R.string.scan_again) to
                { screen = Screen.Scan },
        )

        is Screen.Home -> {
            val holder = remember { BackupUiStateHolder(context, client, identity, s.pairing) }
            // UX-03: 极简设置状态（仅充电/仅 WiFi）——改开关即落盘 +
            // 按新约束重建周期任务。
            val backupSettings = remember { BackupSettings(context.filesDir) }
            var chargeOnly by remember { mutableStateOf(backupSettings.load().chargeOnly) }
            var wifiOnly by remember { mutableStateOf(backupSettings.load().wifiOnly) }
            val loader = remember {
                TimelineLoader(client, parsePeerAddrToken(s.pairing.daemonAddrToken)) {
                    client.bind(identity.secretKey())
                }
            }
            var tab by remember { mutableStateOf(0) } // 0=Photos 1=Backup
            // UX-06: 暂停态持久化——重开 App 保持用户选择；恢复时重新排周期任务。
            val prefs = remember { AutoBackupPrefs(context.filesDir) }
            var autoBackupPaused by remember { mutableStateOf(prefs.paused()) }
            // UX-06: 断开连接警示页（产品档案 §二移动端 1 告知清单）——确认后
            // ①daemon 撤销本设备（device.unpair，验收「断开后 hello 被拒」）
            // ②清 pairing/watermark ③回 Welcome（重扫可重建）。
            var showDisconnectDialog by remember { mutableStateOf(false) }
            var disconnectError by remember { mutableStateOf<String?>(null) }
            val scope = rememberCoroutineScope()
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
                        triplet = holder.triplet.value,
                        batteryWhitelisted = batteryWhitelisted,
                        onOpenBatterySettings = {
                            openBatteryOptimizationSettings(context)
                        },
                        chargeOnly = chargeOnly,
                        onChargeOnlyChange = {
                            chargeOnly = it
                            backupSettings.save(chargeOnly, wifiOnly)
                            rescheduleAutoBackup(context)
                        },
                        wifiOnly = wifiOnly,
                        onWifiOnlyChange = {
                            wifiOnly = it
                            backupSettings.save(chargeOnly, wifiOnly)
                            rescheduleAutoBackup(context)
                        },
                        autoBackupPaused = autoBackupPaused,
                        onToggleAutoBackup = { paused ->
                            autoBackupPaused = paused
                            if (paused) pauseAutoBackup(context)
                            else resumeAutoBackup(context)
                        },
                        onDisconnect = { showDisconnectDialog = true },
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
            if (showDisconnectDialog) {
                AlertDialog(
                    onDismissRequest = { showDisconnectDialog = false },
                    title = { Text(stringResource(R.string.disconnect_confirm_title)) },
                    text = { Text(stringResource(R.string.disconnect_confirm_body)) },
                    confirmButton = {
                        TextButton(onClick = {
                            showDisconnectDialog = false
                            disconnectError = null
                            scope.launch {
                                val peer = try {
                                    parsePeerAddrToken(s.pairing.daemonAddrToken)
                                } catch (t: Throwable) {
                                    null
                                }
                                val unpaired = peer != null && runCatching {
                                    client.unpair(peer)
                                }.getOrDefault(false)
                                if (unpaired || peer == null) {
                                    // 单方停止：本地状态清空（pairing/watermark），
                                    // daemon 端已撤销（unpaired）或不可达（peer 解析
                                    // 失败——本地照清，重扫用新 token 走 rejoin 门）。
                                    pairings.clear()
                                    WatermarkStore(context.filesDir).save(0)
                                    AutoBackupPrefs(context.filesDir).setPaused(false)
                                    WorkManager.getInstance(context)
                                        .cancelUniqueWork(BACKUP_WORK_NAME)
                                    screen = Screen.Welcome
                                } else {
                                    disconnectError = context.getString(R.string.disconnect_failed)
                                }
                            }
                        }) { Text(stringResource(R.string.disconnect_confirm_ok)) }
                    },
                    dismissButton = {
                        TextButton(onClick = { showDisconnectDialog = false }) {
                            Text(stringResource(R.string.cancel))
                        }
                    },
                )
            }
            disconnectError?.let { err ->
                AlertDialog(
                    onDismissRequest = { disconnectError = null },
                    title = { Text(stringResource(R.string.disconnect_failed_title)) },
                    text = { Text(err) },
                    confirmButton = {
                        TextButton(onClick = { disconnectError = null }) {
                            Text(stringResource(R.string.ok))
                        }
                    },
                )
            }
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
