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
import com.hawkeyexb.ppass.transport.ForegroundHeartbeat
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
import com.hawkeyexb.ppass.ui.BackupStartedScreen
import com.hawkeyexb.ppass.ui.BackupUiState
import com.hawkeyexb.ppass.ui.HomeScreen
import com.hawkeyexb.ppass.ui.LoaderTimelineChannel
import com.hawkeyexb.ppass.ui.PhotosScreen
import com.hawkeyexb.ppass.ui.TimelineLoader
import com.hawkeyexb.ppass.ui.TimelineSubscriptionHolder
import com.hawkeyexb.ppass.ui.TwoTabs
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import com.hawkeyexb.ppass.ui.PairStatusScreen
import com.hawkeyexb.ppass.ui.BucketScreen
import com.hawkeyexb.ppass.ui.PPColor
import com.hawkeyexb.ppass.ui.ScanScreen
import com.hawkeyexb.ppass.ui.WelcomeScreen
import com.hawkeyexb.ppass.update.UpdateInfo
import com.hawkeyexb.ppass.update.UpdateChannel
import com.hawkeyexb.ppass.update.channelFromVersion
import com.hawkeyexb.ppass.update.downloadAndInstall
import com.hawkeyexb.ppass.update.fetchUpdate

private sealed class Screen {
    data object Welcome : Screen()
    data object Scan : Screen()
    data class Waiting(val qr: String) : Screen()
    data class Trouble(val titleRes: Int, val bodyRes: Int, val detail: String = "") : Screen()
    data class Home(val pairing: Pairing) : Screen()
    // T6: 相册选择（配对成功直接进这页，或从 Home 的设置区重进）；
    // M4（全页面状态稿）：配对成功不再停一个要点按钮的 Joined 中间页，
    // firstTime 记这次是不是 onboarding 首次选相册——只有这个分支选完
    // 才过 M6 安心收尾页，设置页重选直接回 Home（用户实机反馈：
    // "完成页只有首次 onboarding 才需要"）。
    data class Buckets(val pairing: Pairing, val current: Set<Long>, val firstTime: Boolean) : Screen()
    // M6 完成页（全页面状态稿）：选相册→触发首次备份之后、落到 Home 之前
    // 的安心收尾页。
    data class Started(val pairing: Pairing, val photoCount: Int) : Screen()
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
    var pendingBucketsFirstTime by remember { mutableStateOf(false) }
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
                    pendingBucketsFirstTime,
                )
                partialMedia -> screen = Screen.Home(pairing)
                else -> showMediaPermissionDialog = true
            }
        }
    }

    // UPD-01: 启动时检查一次更新（静默失败；draft/无 release = 无更新；
    // 对话框覆盖所有 screen，不打断当前流程）。REL-02: 按通道取源
    // （stable 默认 / test 最新 prerelease），切换通道后立即重查。
    // DESK-02①: 更新通道由构建推导——版本含 `-test.`（构建期 PPF_BUILD_VERSION
    // 注入）→ test，否则 stable。零 UI、零持久化；正式构建永远 stable。
    val updateChannel = channelFromVersion(BuildConfig.VERSION_NAME)
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
    // Onboarding「通知」权限——Home 页跳过引导卡用（同款「未加白就一直
    // 显示」风格，跟电池白名单卡对称，不额外记「是否已经跳过过」）。
    var notificationGrantedForHome by remember { mutableStateOf(hasNotificationPermission(context)) }
    // 设计稿"失联多少天"——复用 SENT-01 既有的 SentinelStore（不是新
    // 造的判定），距上次确认可达的天数；从未确认可达过（lastReachableAt
    // <= 0）时为 null，调用方（PhotosScreen）走不编造天数的兜底文案。
    fun computeDaysUnreachable(): Int? {
        val last = com.hawkeyexb.ppass.backup.SentinelStore(context.filesDir).load().lastReachableAt
        if (last <= 0) return null
        return ((System.currentTimeMillis() - last) / (24 * 60 * 60 * 1000L)).toInt()
    }
    var daysUnreachable by remember { mutableStateOf(computeDaysUnreachable()) }
    // PRES-01: 前台轻心跳——ON_RESUME 起、ON_STOP 停（退后台绝不心跳，
    // 耗电红线）；app 在前台时 daemon 每 ~30s 收到一次 hello，桌面设备行
    // 才显示「在线」而不是「离线」（锁屏 ≠ 离开）。
    val heartbeat = remember { ForegroundHeartbeat(client, pairings, scope) }
    // SYNC-06: 订阅连接生命周期跟心跳对齐——ON_RESUME 起 / ON_STOP 停，
    // App 前台期间不管显示哪个 tab 都保持订阅（脱钩 tab 切换，旧实现
    // 绑在 PhotosScreen 组合可见性上，切设置 tab 就断）。只有退后台/
    // 锁屏/进程被杀才断开；回前台重建并整页刷新补齐错过的变化。
    val timeline = remember {
        TimelineSubscriptionHolder(
            scope = scope,
            currentPairing = { pairings.load() },
            channelFor = { p ->
                LoaderTimelineChannel(
                    TimelineLoader(client, parsePeerAddrToken(p.daemonAddrToken)) {
                        client.bind(identity.secretKey())
                    }
                )
            },
        )
    }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> {
                    batteryWhitelisted = isIgnoringBatteryOptimizations(context)
                    notificationGrantedForHome = hasNotificationPermission(context)
                    daysUnreachable = computeDaysUnreachable()
                    partialMedia = hasPartialMediaAccess(context)
                    heartbeat.start()
                    timeline.start()
                }
                Lifecycle.Event.ON_STOP -> {
                    heartbeat.stop()
                    timeline.stop()
                }
                else -> {}
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            heartbeat.stop()
            timeline.stop()
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }

    // MOB-03: 进相册选择页的完整权限链（Home「选择备份的相册」与配对
    // 成功→直接选相册共用）——未授权 → 系统权限请求（完整授权后进
    // 列表，这就是设计稿决策「只有选相册进 onboarding」里读取照片权限
    // 的唯一来源，不需要单独一屏）；部分授权 → Home 引导卡（MOB-02 §二，
    // 不显示假 0/0）；拒绝 → 人话对话框。备份主流程的入口，任何分支都
    // 不许白屏。
    fun enterBucketPicker(pairing: Pairing, firstTime: Boolean) {
        val needed = requiredMediaPermissions().filter {
            ContextCompat.checkSelfPermission(context, it) !=
                PackageManager.PERMISSION_GRANTED
        }
        when {
            needed.isNotEmpty() -> {
                pendingBucketsPairing = pairing
                pendingBucketsFirstTime = firstTime
                bucketMediaPermission.launch(needed.toTypedArray())
            }
            hasPartialMediaAccess(context) -> screen = Screen.Home(pairing)
            else -> screen = Screen.Buckets(
                pairing,
                BackupScopeStore(context).selectedBucketIds() ?: emptySet(),
                firstTime,
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
                when (outcome) {
                    is PairOutcome.Joined -> {
                        pairings.save(outcome.pairing)
                        scheduleAutoBackup(context)
                        // M4（全页面状态稿）：桌面点"允许"之后不再停一个要
                        // 点按钮的 Joined 中间页——直接进选相册（用户实机
                        // 反馈"扫完等 desktop 允许自己跳选择相册页面不行？"）；
                        // firstTime=true 标记这是 onboarding 首次选相册，
                        // 选完才过 M6 安心收尾页。
                        enterBucketPicker(outcome.pairing, firstTime = true)
                    }
                    is PairOutcome.Refused -> screen = Screen.Trouble(
                        R.string.pair_refused_title,
                        R.string.pair_refused_body,
                        // T-072: 具体拒绝原因走 diag 字典（msg_key → 双语人话）
                        // 渲染在通用文案下方；未知 key 显示空详情，绝不崩溃。
                        DiagText.resolve(context, outcome.msgKey) ?: "",
                    )
                    is PairOutcome.Failed -> screen = Screen.Trouble(
                        R.string.pair_failed_title, R.string.pair_failed_body,
                        "(${outcome.reason.take(160)})",
                    )
                }
            }
        }

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
            // M10（全页面状态稿）："备份失败时通知我"真实开关。
            val notifyOnFailurePrefs = remember {
                com.hawkeyexb.ppass.backup.NotifyOnFailurePrefs(context.filesDir)
            }
            var notifyOnFailure by remember { mutableStateOf(notifyOnFailurePrefs.enabled()) }
            // DEV-01b: 重装识别入口先隐藏（用户拍板）——设置页开关行已删；
            // device_hint 照发照存（pair.request 处直接读 pref，默认开，
            // 数据继续积累，未来打开入口即用）。
            // MOB-02 §三: 「需要 Wi-Fi」关闭需二次确认（移动网络消耗流量）。
            var pendingWifiOff by remember { mutableStateOf(false) }
            // SYNC-06: TimelineLoader 由 timeline holder 按配对创建/重建
            // （PhotoScreen 用户交互共用 holder.loader）——这里不再各自建。
            var tab by remember { mutableStateOf(0) } // 0=Photos 1=Backup
            // 2026-08-17 大图查看页导航修复：正在全屏看大图/视频时，
            // 主 [照片]/[设置] tab 栏根本不进组合树（不是盖住看不见）。
            var photoViewerOpen by remember { mutableStateOf(false) }
            // UX-06: 暂停态持久化——重开 App 保持用户选择；恢复时重新排周期任务。
            val prefs = remember { AutoBackupPrefs(context.filesDir) }
            var autoBackupPaused by remember { mutableStateOf(prefs.paused()) }
            val scope = rememberCoroutineScope()
            LaunchedEffect(Unit) { client.bind(identity.secretKey()) }
            val mediaPermission = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestMultiplePermissions()
            ) { grants -> if (grants.values.any { it }) holder.backupNow() }
            // 存储端移除/吊销本设备后：本地照清（无需 unpair，daemon 端
            // 本就不认本设备），回 Welcome 扫码，新 token 走 rejoin 门
            // 重建——备份页、照片页的失联红卡按同一个动作走。
            val onRepairPairing = {
                clearLocalPairing(context, pairings, s.pairing)
                screen = Screen.Welcome
            }
            TwoTabs(
                tab = tab,
                onTab = { tab = it },
                showTabBar = !photoViewerOpen,
                // M13 哨兵态：长期失联时设置图标角标红点，跟照片页的失联
                // 红卡同一个信号源（holder.pairingLost），不额外判天数。
                settingsAlert = holder.pairingLost.value,
                photos = {
                    PhotosScreen(
                        timeline,
                        onViewerOpenChange = { photoViewerOpen = it },
                        pairingLost = holder.pairingLost.value,
                        onReconnect = onRepairPairing,
                        daysUnreachable = daysUnreachable,
                    )
                },
                backup = {
                    HomeScreen(
                        storageName = s.pairing.storageDeviceName,
                        state = holder.state.value,
                        triplet = holder.triplet.value,
                        batteryWhitelisted = batteryWhitelisted,
                        onOpenBatterySettings = {
                            openBatteryOptimizationSettings(context)
                        },
                        notificationSkipped = !notificationGrantedForHome,
                        onOpenNotificationSettings = { openAppDetailsSettings(context) },
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
                        notifyOnFailure = notifyOnFailure,
                        onNotifyOnFailureChange = {
                            notifyOnFailure = it
                            notifyOnFailurePrefs.setEnabled(it)
                        },
                        pairedAt = s.pairing.pairedAt,
                        autoBackupPaused = autoBackupPaused,
                        onToggleAutoBackup = { paused ->
                            autoBackupPaused = paused
                            if (paused) pauseAutoBackup(context)
                            else resumeAutoBackup(context)
                        },
                        // UX-06 单方停止：本地断开不依赖 daemon 回应。确认
                        // 交互（三层防误触）在 StorageComputerDetail 内部
                        // 完成（红色描边按钮→展开确认卡→「确认断开」），
                        // 这里不再弹第二层 AlertDialog——onDisconnect 就是
                        // 真正执行断开。unpair 只是尽力通知 daemon 撤销本
                        // 设备——设备已被存储端移除/吊销时 authz 只给未配对/
                        // 已吊销设备留 pair.request 一扇门，unpair 必被拒，
                        // 此时 daemon 端本就不认本设备，无需再撤销；daemon
                        // 不可达同理。unpair 失败不再阻塞断开，否则本地
                        // pairing 永远清不掉，重新扫码入口（Welcome）永久
                        // 消失（存储端移除设备后的死锁）。
                        onDisconnect = {
                            scope.launch {
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
                        },
                        // 存储端移除/吊销本设备后：主按钮变「重新扫码连接」——
                        // 本地照清（无需 unpair，daemon 端本就不认本设备），
                        // 回 Welcome 扫码，新 token 走 rejoin 门重建。
                        pairingLost = holder.pairingLost.value,
                        onRepair = onRepairPairing,
                        // T6: 备份范围——「选择相册」与「发起备份」两个动作。
                        selectedBucketCount = remember {
                            BackupScopeStore(context).selectedBucketIds()?.size
                        },
                        // MOB-03: 相册选择入口走完整权限链——MOB-02 删首页手动
                        // 备份按钮时把挂在它身上的权限申请链一起删没了，
                        // 无权限直接进列表 = MediaStore 空查询 = 全白。
                        onOpenBucketPicker = { enterBucketPicker(s.pairing, firstTime = false) },
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
                        // M6 完成页（全页面状态稿，用户实机反馈"只有首次
                        // onboarding 才需要"）：只有 firstTime（配对成功后
                        // 第一次选相册）才过这页；设置页重选直接回 Home，
                        // 不重复打扰。重建时重新读范围，三元组/扫描随之生效。
                        if (s.firstTime) {
                            val selectedCount = list.filter { it.id in sel }.sumOf { it.count }
                            screen = Screen.Started(s.pairing, selectedCount)
                        } else {
                            screen = Screen.Home(s.pairing)
                        }
                    },
                    onCancel = { screen = Screen.Home(s.pairing) },
                )
            }
        }

        is Screen.Started -> BackupStartedScreen(
            photoCount = s.photoCount,
            onEnter = { screen = Screen.Home(s.pairing) },
        )
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

/** 通知权限现状（API<33 恒真——那些版本装完就有，没有运行时权限这
 *  一说）；只喂 HomeScreen 的不堵路引导卡，不参与任何 onboarding 流程。 */
private fun hasNotificationPermission(context: Context): Boolean =
    if (Build.VERSION.SDK_INT >= 33) {
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    } else {
        true
    }

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
