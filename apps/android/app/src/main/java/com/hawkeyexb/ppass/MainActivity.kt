// T-052: pairing flow — welcome → camera scan → waiting for Allow →
// joined. Paired phones land on a minimal home (T-055 builds it out).
package com.hawkeyexb.ppass

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
import com.hawkeyexb.ppass.backup.ConfirmedStore
import com.hawkeyexb.ppass.backup.isPartialMediaAccess
import com.hawkeyexb.ppass.backup.ReinstallHintPrefs
import com.hawkeyexb.ppass.backup.rescheduleAutoBackup
import com.hawkeyexb.ppass.backup.scheduleAutoBackup
import com.hawkeyexb.ppass.backup.pauseAutoBackup
import com.hawkeyexb.ppass.backup.resumeAutoBackup
import com.hawkeyexb.ppass.backup.triggerUserPresentBackup
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
import com.hawkeyexb.ppass.update.UpdateChannel
import com.hawkeyexb.ppass.update.UpdateChannelStore
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
    // MOB-03: 相册选择页权限链——「等授权结果后去哪」的落点。设置后由
    // bucketMediaPermission 回调消费；不进 Buckets 的路径立即清掉。
    var pendingBucketsPairing by remember { mutableStateOf<Pairing?>(null) }
    // MOB-03: 媒体权限被拒 → 人话引导（不崩不白屏，说清为什么需要）。
    var showMediaPermissionDialog by remember { mutableStateOf(false) }
    // MOB-02 §二: 部分授权态（API 34+「部分照片」）——ON_RESUME 一起刷新
    // （用户去系统设置改完全授权返回后引导卡消失）；bucketMediaPermission
    // 回调里也会即时重读。声明提前：launcher 回调需要引用。
    var partialMedia by remember { mutableStateOf(hasPartialMediaAccess(context)) }
    // MOB-02 §四事件①: 排队提示——触发时 Wi-Fi 要求不满足，WorkManager
    // 排队等网，首页显示「将在连上 Wi-Fi 后进行」。
    var wifiDeferred by remember { mutableStateOf(false) }
    // Paired phones: periodic backup + content trigger stay scheduled
    // (idempotent KEEP) and every app-open runs one catch-up — BUT only
    // if the last success is older than 24h (MOB-02 事件④, user-present
    // tier). UX-06: 全局暂停态下两者都不跑（重开 App 不自动恢复，
    // 直到用户恢复开关）。
    remember {
        val pairing = pairings.load()
        if (pairing != null && !AutoBackupPrefs(context.filesDir).paused()) {
            scheduleAutoBackup(context)
            // MOB-02 §四事件④：App 进前台且距上次成功 >24h → 用户在场档。
            val lastSuccess = ConfirmedStore(
                java.io.File(context.filesDir, "backup-state/${pairing.daemonNodeId}")
            ).lastSuccessAt()
            if (System.currentTimeMillis() - lastSuccess > MOB_APP_OPEN_GATE_MS) {
                triggerUserPresentBackup(context)
            }
        }
        // 新会话重新评估排队提示（上一轮的排队状态随进程重开作废）。
        wifiDeferred = false
        true
    }

    val cameraPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted -> if (granted) screen = Screen.Scan }

    // MOB-03: 相册选择页权限链——未授权先弹系统权限，完整授权后才进列表；
    // 部分授权 → Home 引导卡（MOB-02 §二，不显示假 0/0）；拒绝 → 人话对话框。
    val bucketMediaPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { _ ->
        val pairing = pendingBucketsPairing
        if (pairing != null) {
            pendingBucketsPairing = null
            // 系统弹窗关闭后状态已落定，直接重读（比 ON_RESUME 刷新更及时）。
            partialMedia = hasPartialMediaAccess(context)
            val stillNeeded = requiredMediaPermissions().filter {
                ContextCompat.checkSelfPermission(context, it) !=
                    PackageManager.PERMISSION_GRANTED
            }
            when {
                stillNeeded.isEmpty() && !partialMedia -> screen = Screen.Buckets(
                    pairing,
                    BackupScopeStore(context).selectedBucketIds() ?: emptySet(),
                )
                partialMedia -> screen = Screen.Home(pairing)
                else -> showMediaPermissionDialog = true
            }
        }
    }

    // UPD-01: 启动时检查一次更新（静默失败；draft/无 release = 无更新；
    // 对话框覆盖所有 screen，不打断当前流程）。REL-02: 按通道取源
    // （stable 默认 / test 最新 prerelease），切换通道后立即重查。
    val updateChannelStore = remember { UpdateChannelStore(context) }
    var updateChannel by remember { mutableStateOf(updateChannelStore.load()) }
    var updateInfo by remember { mutableStateOf<UpdateInfo?>(null) }
    LaunchedEffect(updateChannel) {
        updateInfo = fetchUpdate(BuildConfig.VERSION_NAME, updateChannel)
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

    // MOB-03: 媒体权限被拒的人话引导——说清为什么需要，给出去设置的路。
    if (showMediaPermissionDialog) {
        AlertDialog(
            onDismissRequest = { showMediaPermissionDialog = false },
            title = { Text(stringResource(R.string.media_permission_denied_title)) },
            text = { Text(stringResource(R.string.media_permission_denied_body)) },
            confirmButton = {
                TextButton(onClick = {
                    showMediaPermissionDialog = false
                    openAppDetailsSettings(context)
                }) { Text(stringResource(R.string.partial_access_action)) }
            },
            dismissButton = {
                TextButton(onClick = { showMediaPermissionDialog = false }) {
                    Text(stringResource(R.string.cancel))
                }
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
                partialMedia = hasPartialMediaAccess(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // MOB-03: 进相册选择页的完整权限链（Home「选择备份的相册」与 onboarding
    // 「配对成功→选相册」共用）——未授权 → 系统权限请求（完整授权后进列表）；
    // 部分授权 → Home 引导卡（MOB-02 §二，不显示假 0/0）；拒绝 → 人话对话框。
    // 备份主流程的入口，任何分支都不许白屏。
    fun enterBucketPicker(pairing: Pairing) {
        val needed = requiredMediaPermissions().filter {
            ContextCompat.checkSelfPermission(context, it) !=
                PackageManager.PERMISSION_GRANTED
        }
        when {
            needed.isNotEmpty() -> {
                pendingBucketsPairing = pairing
                bucketMediaPermission.launch(needed.toTypedArray())
            }
            hasPartialMediaAccess(context) -> screen = Screen.Home(pairing)
            else -> screen = Screen.Buckets(
                pairing,
                BackupScopeStore(context).selectedBucketIds() ?: emptySet(),
            )
        }
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
                    // DEV-01: 重装识别开关（默认开）——关掉时 pair.request
                    // 不带 device_hint，重装后按旧行为出新设备行。
                    pairWithQr(
                        client,
                        s.qr,
                        deviceName(),
                        reinstallHintEnabled = ReinstallHintPrefs(context.filesDir).enabled(),
                    )
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
            // MOB-02 卡面 §一：配对成功 → 引导进入相册选择页 → 选完走
            // 事件①触发首备份（配对本身不触发备份）。
            onDone = {
                // MOB-03: onboarding 入口同样过权限链（未授权先弹系统权限，
                // 完整授权后才进相册列表；拒绝/部分授权回引导）。
                enterBucketPicker(s.pairing)
            },
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
            // 按新约束重建周期任务。MOB-02 起语义为「需要充电/需要 Wi-Fi」
            // 两档运行条件（默认都开），设置页有后果描述 + 合成句。
            val backupSettings = remember { BackupSettings(context.filesDir) }
            var chargeOnly by remember { mutableStateOf(backupSettings.load().chargeOnly) }
            var wifiOnly by remember { mutableStateOf(backupSettings.load().wifiOnly) }
            // DEV-01: 重装识别开关（默认开）——Home 设置区切换，配对时读取。
            val hintPrefs = remember { ReinstallHintPrefs(context.filesDir) }
            var reinstallHintEnabled by remember { mutableStateOf(hintPrefs.enabled()) }
            // MOB-02 §三: 「需要 Wi-Fi」关闭需二次确认（移动网络消耗流量）。
            var pendingWifiOff by remember { mutableStateOf(false) }
            // REL-02: 更新通道切换对话框（显式操作，默认永远 stable）。
            var pendingChannelSwitch by remember { mutableStateOf(false) }
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
                        onWifiOnlyChange = { enable ->
                            // MOB-02 §三: 关闭「需要 Wi-Fi」需二次确认
                            // （移动网络也会备份，可能消耗流量）。
                            if (!enable) pendingWifiOff = true
                            else {
                                wifiOnly = true
                                backupSettings.save(chargeOnly, wifiOnly)
                                rescheduleAutoBackup(context)
                            }
                        },
                        autoBackupPaused = autoBackupPaused,
                        onToggleAutoBackup = { paused ->
                            autoBackupPaused = paused
                            if (paused) pauseAutoBackup(context)
                            else resumeAutoBackup(context)
                        },
                        // DEV-01: 重装识别开关（默认开）——落盘 ReinstallHintPrefs，
                        // 下次配对（pair.request）读取。
                        reinstallHintEnabled = reinstallHintEnabled,
                        onReinstallHintChange = { enabled ->
                            reinstallHintEnabled = enabled
                            ReinstallHintPrefs(context.filesDir).setEnabled(enabled)
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
                        // MOB-03: 相册选择入口走完整权限链——MOB-02 删首页手动
                        // 备份按钮时把挂在它身上的权限申请链一起删没了，
                        // 无权限直接进列表 = MediaStore 空查询 = 全白。
                        onOpenBucketPicker = { enterBucketPicker(s.pairing) },
                        // MOB-02 §一: 首页主按钮删除——hero 空闲态按钮 =
                        // 「选择备份的相册」；onBackupNow 保留给：进行中暂停、
                        // 失败红卡「再试一次」、设置页低调「立即备份」（狗粮）。
                        onBackupNow = {
                            val needed = requiredMediaPermissions().filter {
                                ContextCompat.checkSelfPermission(context, it) !=
                                    PackageManager.PERMISSION_GRANTED
                            }
                            if (needed.isEmpty()) holder.backupNow()
                            else mediaPermission.launch(needed.toTypedArray())
                        },
                        // MOB-02 §二: 部分授权引导（只授权了部分照片 →
                        // 一键去系统设置；部分授权态不保存范围、不显示假 0/0）。
                        partialAccess = partialMedia,
                        onOpenAppSettings = { openAppDetailsSettings(context) },
                        // MOB-02 §四事件①: 排队提示（Wi-Fi 要求不满足时）。
                        wifiDeferred = wifiDeferred,
                        // REL-02: 更新通道（stable 默认 / test）——显式切换。
                        updateChannel = updateChannel,
                        onChannelChangeRequest = { pendingChannelSwitch = true },
                    )
                },
            )
            if (pendingWifiOff) {
                AlertDialog(
                    onDismissRequest = { pendingWifiOff = false },
                    title = { Text(stringResource(R.string.wifi_off_confirm_title)) },
                    text = { Text(stringResource(R.string.wifi_off_confirm_body)) },
                    confirmButton = {
                        TextButton(onClick = {
                            pendingWifiOff = false
                            wifiOnly = false
                            backupSettings.save(chargeOnly, false)
                            rescheduleAutoBackup(context)
                        }) { Text(stringResource(R.string.wifi_off_confirm_ok)) }
                    },
                    dismissButton = {
                        TextButton(onClick = { pendingWifiOff = false }) {
                            Text(stringResource(R.string.cancel))
                        }
                    },
                )
            }
            if (pendingChannelSwitch) {
                // REL-02: 通道切换必须显式——两个选项 + 取消，默认永远 stable；
                // 切换后 LaunchedEffect(updateChannel) 立即按新通道重查更新。
                AlertDialog(
                    onDismissRequest = { pendingChannelSwitch = false },
                    title = { Text(stringResource(R.string.update_channel_switch_title)) },
                    text = {
                        Column {
                            Text(
                                stringResource(R.string.update_channel_stable),
                                fontSize = 16.sp, color = PPColor.Ink,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        pendingChannelSwitch = false
                                        updateChannelStore.save(UpdateChannel.Stable)
                                        updateChannel = UpdateChannel.Stable
                                    }
                                    .padding(vertical = 10.dp),
                            )
                            Text(
                                stringResource(R.string.update_channel_test),
                                fontSize = 16.sp, color = PPColor.Ink,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        pendingChannelSwitch = false
                                        updateChannelStore.save(UpdateChannel.Test)
                                        updateChannel = UpdateChannel.Test
                                    }
                                    .padding(vertical = 10.dp),
                            )
                        }
                    },
                    confirmButton = {},
                    dismissButton = {
                        TextButton(onClick = { pendingChannelSwitch = false }) {
                            Text(stringResource(R.string.cancel))
                        }
                    },
                )
            }
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
                    // MOB-02 §六: 新相册判定基准（null = 从未选过范围，全量模式）。
                    knownBuckets = scopeStore.knownBucketIds(),
                    onDone = { sel ->
                        // MOB-02 §二: 部分授权态不保存范围（选了也备不完整，
                        // 且会显示假 0/0）——直接回 Home，Home 显示部分授权
                        // 引导卡（一键去系统设置改完全授权）。
                        if (hasPartialMediaAccess(context)) {
                            screen = Screen.Home(s.pairing)
                            return@BucketScreen
                        }
                        // MOB-02 §六: 保存范围 + 记录当前全部相册（新相册
                        // 基准）；新出现的相册默认不包含（不在 sel 里）。
                        scopeStore.saveScope(
                            selected = sel,
                            allCurrent = list.map { it.id }.toSet(),
                        )
                        // MOB-02 §四事件①: 选完/改完备份范围返回 → 用户在场
                        // 档触发（只查 Wi-Fi 不查充电）；不满足则 WorkManager
                        // 排队，首页显示「将在连上 Wi-Fi 后进行」。
                        val settings = BackupSettings(context.filesDir).load()
                        wifiDeferred = settings.wifiOnly && !isOnUnmetered(context)
                        triggerUserPresentBackup(context)
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

// MOB-02 §四事件④: App 进前台且距上次成功 >24h → 用户在场档补跑。
private const val MOB_APP_OPEN_GATE_MS = 24L * 60 * 60 * 1000

/** MOB-02 §二: 部分授权检测（走纯函数判定，权限查询为生产注入）。 */
private fun hasPartialMediaAccess(context: Context): Boolean =
    isPartialMediaAccess(
        imagesGranted = ContextCompat.checkSelfPermission(
            context, Manifest.permission.READ_MEDIA_IMAGES
        ) == PackageManager.PERMISSION_GRANTED,
        visualSelectedGranted = ContextCompat.checkSelfPermission(
            context, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
        ) == PackageManager.PERMISSION_GRANTED,
        sdkInt = Build.VERSION.SDK_INT,
    )

/** MOB-02 §四事件①: 是否在不计流量网络（Wi-Fi）上——排队提示的判据。 */
private fun isOnUnmetered(context: Context): Boolean {
    val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        ?: return false
    val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
    return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
}

/** MOB-02 §二: 一键去系统设置（应用详情页）改完整相册权限。 */
private fun openAppDetailsSettings(context: Context) {
    val intent = android.content.Intent(
        android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
        android.net.Uri.fromParts("package", context.packageName, null),
    ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
    context.startActivity(intent)
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
