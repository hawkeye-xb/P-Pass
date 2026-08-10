// T-052: pairing flow — welcome → camera scan → waiting for Allow →
// joined. Paired phones land on a minimal home (T-055 builds it out).
package com.hawkeyexb.ppass

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.work.WorkManager
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
import com.hawkeyexb.ppass.backup.BackupScopeStore
import com.hawkeyexb.ppass.backup.BackupSettings
import com.hawkeyexb.ppass.backup.MediaScanner
import com.hawkeyexb.ppass.backup.AutoBackupPrefs
import com.hawkeyexb.ppass.backup.backupOnceNow
import com.hawkeyexb.ppass.backup.rescheduleAutoBackup
import com.hawkeyexb.ppass.backup.scheduleAutoBackup
import com.hawkeyexb.ppass.backup.pauseAutoBackup
import com.hawkeyexb.ppass.backup.resumeAutoBackup
import com.hawkeyexb.ppass.backup.BACKUP_WORK_NAME
import com.hawkeyexb.ppass.backup.WatermarkStore
import com.hawkeyexb.ppass.backup.clearConfirmedCacheForRemote
import com.hawkeyexb.ppass.backup.BackupUiStateHolder
import com.hawkeyexb.ppass.ui.BackupUiState
import com.hawkeyexb.ppass.ui.HomeScreen
import com.hawkeyexb.ppass.ui.PhotosScreen
import com.hawkeyexb.ppass.ui.TimelineLoader
import com.hawkeyexb.ppass.ui.TwoTabs
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import com.hawkeyexb.ppass.ui.JoinedScreen
import com.hawkeyexb.ppass.ui.PairStatusScreen
import com.hawkeyexb.ppass.ui.BucketScreen
import com.hawkeyexb.ppass.ui.PPColor
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
    // T6: 相册选择（从 Home 的设置区进入）
    data class Buckets(val pairing: Pairing, val current: Set<Long>) : Screen()
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // MOB-01: 统一 edge-to-edge——API 35+ 默认强制，低版本主动
        // 开启后行为一致；各屏内容安全区由 PPScreen 一处处理。
        enableEdgeToEdge()
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
                        // 存储端移除/吊销本设备后：主按钮变「重新扫码连接」——
                        // 本地照清（无需 unpair，daemon 端本就不认本设备），
                        // 回 Welcome 扫码，新 token 走 rejoin 门重建。
                        pairingLost = holder.pairingLost.value,
                        onRepair = {
                            clearLocalPairing(context, pairings, s.pairing)
                            screen = Screen.Welcome
                        },
                        // T6: 备份范围——「选择相册」与「发起备份」两个动作。
                        selectedBucketCount = remember {
                            BackupScopeStore(context).selectedBucketIds()?.size
                        },
                        onOpenBucketPicker = {
                            screen = Screen.Buckets(
                                s.pairing,
                                BackupScopeStore(context).selectedBucketIds() ?: emptySet(),
                            )
                        },
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
                            scope.launch {
                                // UX-06 单方停止：本地断开不依赖 daemon 回应。
                                // unpair 只是尽力通知 daemon 撤销本设备——
                                // 设备已被存储端移除/吊销时 authz 只给未配对/
                                // 已吊销设备留 pair.request 一扇门，unpair 必被
                                // 拒，此时 daemon 端本就不认本设备，无需再撤销；
                                // daemon 不可达同理。unpair 失败不再阻塞断开，
                                // 否则本地 pairing 永远清不掉，重新扫码入口
                                // （Welcome）永久消失（存储端移除设备后的死锁）。
                                val peer = try {
                                    parsePeerAddrToken(s.pairing.daemonAddrToken)
                                } catch (t: Throwable) {
                                    null
                                }
                                if (peer != null) {
                                    try {
                                        withTimeout(5_000) { client.unpair(peer) }
                                    } catch (_: Throwable) {
                                        // 尽力而为——本地照断，重扫用新 token 重建。
                                    }
                                }
                                clearLocalPairing(context, pairings, s.pairing)
                                screen = Screen.Welcome
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
        }

        // T6: 相册选择页——「选择备份内容」与「发起备份」是两个动作。
        is Screen.Buckets -> {
            val scopeStore = remember { BackupScopeStore(context) }
            var buckets by remember { mutableStateOf<List<MediaScanner.Bucket>?>(null) }
            LaunchedEffect(Unit) {
                buckets = withContext(Dispatchers.IO) {
                    MediaScanner(context.contentResolver).listBuckets()
                }
            }
            val list = buckets
            if (list == null) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(stringResource(R.string.bucket_loading), color = PPColor.Ink40)
                }
            } else {
                BucketScreen(
                    buckets = list,
                    selected = s.current,
                    onDone = { sel ->
                        scopeStore.saveSelectedBucketIds(sel)
                        // 回 Home——重建时重新读范围，三元组/扫描随之生效。
                        screen = Screen.Home(s.pairing)
                    },
                    onCancel = { screen = Screen.Home(s.pairing) },
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

/**
 * 本地单方断开（UX-06/UX-06b 语义）——清空这台手机的配对现场：
 * pairing 记录、该 remote 的确认缓存（重配对后 M 从 0 重新计数）、
 * watermark、自动备份暂停态、周期任务。断开与「配对已失效重新扫码」
 * 共用此清理；不依赖 daemon 是否可达/是否已撤销本设备。
 */
private fun clearLocalPairing(
    context: Context,
    pairings: PairingStore,
    pairing: Pairing,
) {
    pairings.clear()
    // UX-06b: 清该 remote 的确认缓存（backup-state/<daemonNodeId>/）——
    // 重配对到同一台电脑后 M 从 0 重新计数，不沿用旧缓存
    // （电脑端删过库时 M 虚高，首屏是错的）。
    clearConfirmedCacheForRemote(context.filesDir, pairing.daemonNodeId)
    WatermarkStore(context.filesDir).save(0)
    AutoBackupPrefs(context.filesDir).setPaused(false)
    WorkManager.getInstance(context).cancelUniqueWork(BACKUP_WORK_NAME)
}
