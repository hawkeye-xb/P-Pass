// T-052: pairing flow — welcome → camera scan → waiting for Allow →
// joined. Paired phones land on a minimal home (T-055 builds it out).
package com.hawkeyexb.ppass

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
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
import com.hawkeyexb.ppass.log.PLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.work.WorkManager
import com.hawkeyexb.ppass.battery.AndroidBackgroundAuthorizationAdapter
import com.hawkeyexb.ppass.i18n.DiagText
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.ForegroundHeartbeat
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.PairOutcome
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PairingStore
import com.hawkeyexb.ppass.transport.bindThenPair
import com.hawkeyexb.ppass.transport.pairWithQr
import com.hawkeyexb.ppass.backup.BackupRunner
import com.hawkeyexb.ppass.backup.BackupScopeStore
import com.hawkeyexb.ppass.backup.OnboardedDesktopsStore
import com.hawkeyexb.ppass.backup.backfillOnboardedOnHome
import com.hawkeyexb.ppass.backup.isKnownDesktop
import com.hawkeyexb.ppass.backup.BackupSettings
import com.hawkeyexb.ppass.backup.MediaScanner
import com.hawkeyexb.ppass.backup.AutoBackupPrefs
import com.hawkeyexb.ppass.backup.BackupHealthPrefs
import com.hawkeyexb.ppass.backup.isPartialMediaAccess
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.mediaAccessOf
import com.hawkeyexb.ppass.backup.resumeAfterInterruption
import com.hawkeyexb.ppass.backup.rescheduleAutoBackup
import com.hawkeyexb.ppass.backup.scheduleAutoBackup
import com.hawkeyexb.ppass.backup.disableAutoBackup
import com.hawkeyexb.ppass.backup.enableAutoBackup
import com.hawkeyexb.ppass.backup.suspendAutoBackupUntilAuthorized
import com.hawkeyexb.ppass.backup.restoreAutoBackupAfterRepair
import com.hawkeyexb.ppass.backup.restoreAutoBackupAfterAuthorizationReturned
import com.hawkeyexb.ppass.backup.BackgroundBackupState
import com.hawkeyexb.ppass.backup.backgroundBackupStateOf
import com.hawkeyexb.ppass.backup.triggerUserPresentBackup
import com.hawkeyexb.ppass.backup.DisconnectRuntime
import com.hawkeyexb.ppass.backup.applyDisconnectManifest
import com.hawkeyexb.ppass.backup.unregisteredStatePaths
import com.hawkeyexb.ppass.backup.BackupUiStateHolder
import com.hawkeyexb.ppass.backup.flow.requestFlowScopeBackfillAndWake
import com.hawkeyexb.ppass.backup.flow.requestFlowWakeAfterRepair
import com.hawkeyexb.ppass.backup.flow.requestFlowWake
import com.hawkeyexb.ppass.backup.flow.TriggerReason
import com.hawkeyexb.ppass.backup.flow.isOnUnmetered
import com.hawkeyexb.ppass.backup.flow.clearFlowRuntime
import com.hawkeyexb.ppass.ui.BackupStartedScreen
import com.hawkeyexb.ppass.ui.BackupUiState
import com.hawkeyexb.ppass.ui.HomeScreen
import com.hawkeyexb.ppass.ui.NoticeHost
import com.hawkeyexb.ppass.ui.LoaderTimelineChannel
import com.hawkeyexb.ppass.ui.PhotosScreen
import com.hawkeyexb.ppass.ui.TimelineLoader
import com.hawkeyexb.ppass.ui.TimelineSubscriptionHolder
import com.hawkeyexb.ppass.ui.TwoTabs
import com.hawkeyexb.ppass.transport.UnpairNotice
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import com.hawkeyexb.ppass.ui.PairStatusScreen
import com.hawkeyexb.ppass.ui.BucketScreen
import com.hawkeyexb.ppass.ui.PPColor
import com.hawkeyexb.ppass.ui.PPSize
import com.hawkeyexb.ppass.ui.ScanScreen
import com.hawkeyexb.ppass.ui.WelcomeScreen
import com.hawkeyexb.ppass.ui.UpdateDialog
import com.hawkeyexb.ppass.update.UpdateUiController
import com.hawkeyexb.ppass.update.UpdateUiState

internal sealed class Screen {
    data object Welcome : Screen()
    data object Scan : Screen()
    // #421：手动输入配对串（不开相机）。拒绝摄像头权限、或欢迎页直接点
    // 「无法扫码？」都落到这里；返回回 Welcome，不经过会再弹权限的路径。
    data object ManualPair : Screen()
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

/**
 * UI-18（#355）：配对失效红卡「重新扫码连接」的落点——直达扫码，中间零多余屏。
 * 相机权限被系统收回时先垫 Welcome（系统授权框盖在上面，授权回调落到 Scan；
 * 拒绝则落到手动输入配对串，见 [cameraPermissionResultTarget]）。
 */
internal fun repairScanTarget(cameraGranted: Boolean): Screen =
    if (cameraGranted) Screen.Scan else Screen.Welcome

/**
 * #421：摄像头权限请求的落点。拒绝（含「不再询问」后 launch 立即回 false）
 * 直接进手动输入配对串——那条退路本来就是给扫不了码的人的，不能被摄像头
 * 权限挡在后面；也不再追弹一次权限。
 */
internal fun cameraPermissionResultTarget(granted: Boolean): Screen =
    if (granted) Screen.Scan else Screen.ManualPair

/** System back for secondary app screens; null leaves the root gesture to Android. */
internal fun systemBackTarget(screen: Screen): Screen? = when (screen) {
    Screen.Welcome, is Screen.Home -> null
    Screen.Scan, Screen.ManualPair -> Screen.Welcome
    is Screen.Waiting, is Screen.Trouble -> Screen.Scan
    is Screen.Buckets -> Screen.Home(screen.pairing)
    is Screen.Started -> Screen.Home(screen.pairing)
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
    // UI-12 追加（2026-09-15，用户拍板）：后台备份"去处理"的短暂反馈用
    // Snackbar——这是本代码库第一个"转瞬即逝、非持久"的反馈机制（此前
    // 所有反馈都是改一个持久状态、界面自己重组合）。只覆盖两条真实存在
    // 的信号：①点击发起重挂监听的确认（"正在重新连接…"，无失败态——
    // WorkManager 入队不会抛错，真失败已由 Trouble 状态/系统通知覆盖）；
    // ②系统授权弹窗的结果回调（同意/拒绝，各一句文案）。不做"报错"
    // Snackbar：点击这个动作本身没有可诚实上报的失败信号，编一个是假的。
    val snackbarHostState = remember { SnackbarHostState() }
    val identity = remember { IdentityStore(context.filesDir) }
    val pairings = remember { PairingStore(context.filesDir) }
    val app = context.applicationContext as PPassApplication
    val client = remember { app.daemonClient }

    var screen by remember {
        mutableStateOf<Screen>(pairings.load()?.let { Screen.Home(it) } ?: Screen.Welcome)
    }
    // #130：onboarding 只问一次通知权限。第一次运行这一版时定下是不是老用户（已有配对 / 走完过
    // onboarding）——老用户升级不问；靠落盘标记，不靠版本号。
    val notificationAsk = remember {
        com.hawkeyexb.ppass.backup.OnboardingNotificationAsk(context.filesDir).also {
            it.initIfAbsent(
                existingUser = pairings.load() != null || OnboardedDesktopsStore(context.filesDir).anyOnboarded(),
            )
        }
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
    // MOB-94: 三档，不是布尔。全拒那一档此前落进了「正常」分支，
    // 首页因此显示「0 / 0 张已回家 · 照片都存好了」。
    var mediaAccess by remember { mutableStateOf(mediaAccess(context)) }
    // #413：「将在连上 Wi-Fi 后进行」由引擎的等待原因（WIFI）给出，这里不再另存一份排队状态。
    // Home 内 Photos/设置 tab——提到顶层是因为 Screen.Buckets 是独立的
    // 顶层 Screen，从相册选择页返回时 `is Screen.Home ->` 分支会整个
    // 重新进入组合，若这个变量还留在分支内部的 remember 里就会被重置回
    // 0（Photos），导致「从选相册页回退后莫名跳去照片 tab」（用户实机
    // 反馈的 history stack 错乱）。提到这里后跨 Screen 切换也不丢。
    var tab by remember { mutableStateOf(0) } // 0=Photos 1=Backup
    // Paired phones: periodic backup + content trigger stay scheduled
    // (idempotent KEEP) and every app-open runs one catch-up — BUT only
    // if the last success is older than 24h (MOB-02 事件④, user-present
    // tier). UX-06: 全局暂停态下两者都不跑（重开 App 不自动恢复，
    // 直到用户恢复开关）。
    // MOB-14: 打开 App 无条件补跑一次（原来卡 24h 门槛，导致通知丢失只能
    // 干等周期兜底，而用户开 App 的意图正是"看照片到家没有"）。
    //
    // MOB-18 已撤（2026-08-19 用户拍板 pending）：这里曾先查一次调度是否
    // 被 force-stop 清空、清空则只提示不恢复。撤掉的原因是那个语义做不到
    // ——WorkManager 的 ForceStopRunnable 跑在 androidx.startup 的
    // ContentProvider 里，**比 Application.onCreate 还早**，它自己就把所有
    // work 重排了，应用层拦不住。留着只会显示一条"点了才恢复"却其实早已
    // 自愈的假提示。详见 .claude/cards/backlog/MOB-18-*。
    // MOB-28: 检测到监听被外力清过、用户还没点「恢复」时，**这里不许重挂**。
    // 这条路径是"打开 App 就悄悄恢复"的那个漏子——用户实测原话："还是没有
    // 提示，强行停止立即就恢复了。" 闸门必须同时立在 Application 的对账
    // 和这里，缺一处就等于没有。
    var backupInterrupted by remember {
        mutableStateOf(BackupHealthPrefs(context.filesDir).load().interruptedUnacknowledged)
    }
    // MOB-35（2026-08-25 真机）：`backupInterrupted` 只该挡**重挂后台监听**，
    // 不该挡**用户在前台的补捞**。原来一个 `return` 把两件事一起挡了，于是
    // force-stop 之后即使 App 摆在眼前也一张不传（实测：停止期间拍照 → 重开
    // App 放前台 → 轮询 90 秒零上传）。
    //
    // 用户定调（2026-08-25）："重新启动之后，我依旧没有启动后台是合理的，但是
    // 前台情况下，都无法上传，是不是不合理呢？" 给的状态模型是：**前台 = 人在
    // 场 = 该传**。用户打开 App 本身就是意思表示，而且他看得见进度——不存在
    // MOB-28 要防的那种"自作主张"。MOB-28 防的是"背着用户把后台监听装回去"。
    // MOB-38: 「回到前台该做什么」只写一份——`LaunchedEffect`（首次进入组合）
    // 与 `ON_RESUME`（每次切回来）都调它。
    //
    // ⚠️ 提成函数不是为了少打字，是为了**让「漏接一处」变得不可能**。两处各写
    // 一遍门控的话，下次改其中一条（比如再加一个「暂停中不补」的条件）就又会
    // 漏——MOB-33/34/35/38 四个 bug 全是这个形状。
    val foregroundCatchup = {
        if (pairings.load() != null && AutoBackupPrefs(context.filesDir).enabled()) {
            // 后台监听：中断待确认时不许重挂（MOB-28 红线，唯一入口是
            // resumeAfterInterruption）。
            if (!backupInterrupted) scheduleAutoBackup(context)
            // 前台补捞：无条件跑。人在场就该传（MOB-35 的定调）。
            triggerUserPresentBackup(context)
        }
    }
    LaunchedEffect(backupInterrupted) { foregroundCatchup() }

    val cameraPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted -> screen = cameraPermissionResultTarget(granted) }

    // MOB-03: 相册选择页权限链——未授权先弹系统权限，完整授权后才进列表；
    // 部分授权 → Home 引导卡（MOB-02 §二，不显示假 0/0）；拒绝 → 人话对话框。
    val bucketMediaPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { _ ->
        val pairing = pendingBucketsPairing
        if (pairing != null) {
            pendingBucketsPairing = null
            // 系统弹窗关闭后状态已落定，直接重读（比 ON_RESUME 刷新更及时）。
            mediaAccess = mediaAccess(context)
            val stillNeeded = requiredMediaPermissions().filter {
                ContextCompat.checkSelfPermission(context, it) !=
                    PackageManager.PERMISSION_GRANTED
            }
            when {
                stillNeeded.isEmpty() && mediaAccess == MediaAccess.FULL -> screen = Screen.Buckets(
                    pairing,
                    BackupScopeStore(context).selectedBucketIds() ?: emptySet(),
                    pendingBucketsFirstTime,
                )
                mediaAccess == MediaAccess.PARTIAL -> screen = Screen.Home(pairing)
                else -> showMediaPermissionDialog = true
            }
        }
    }


    // UPD-02: 更新状态机——检查/下载/校验/安装/回执全链状态在
    // UpdateUiController 一处汇合，这里只接线：触发节点 1（冷启动，下方
    // LaunchedEffect）+ 节点 2（ON_RESUME，挂进既有生命周期观察器），
    // 两个节点共用 6h 节流门（GitHub 匿名限流下的硬约束）；手动检查走
    // 设置行「检查更新」（onCheckRowClick），不受门限。
    val updateController = remember {
        UpdateUiController(context, scope, BuildConfig.VERSION_NAME)
    }
    val updateState by updateController.state.collectAsState()
    val updateDialogSuppressed by updateController.dialogSuppressed.collectAsState()
    LaunchedEffect(Unit) { updateController.onColdStart() }
    // Snackbar 级一过性反馈（已是最新 / 检查失败 / 已更新到 vX）——
    // 与 UI-12 的「只报能诚实上报的信号」同一条规矩。
    LaunchedEffect(Unit) {
        updateController.notices.collect { notice ->
            snackbarHostState.showSnackbar(
                if (notice.arg != null) {
                    context.getString(notice.textRes, notice.arg)
                } else {
                    context.getString(notice.textRes)
                },
            )
        }
    }
    // 首次选完相册后的两项系统授权必须串行独占屏幕；更新可以等用户完成
    // onboarding 后再说，绝不压在系统权限框上。「后台下载」收起的对话框
    // （dialogSuppressed）不渲染，设置行点击可重新打开。
    if (screen !is Screen.Started && !updateDialogSuppressed) {
        UpdateDialog(
            state = updateState,
            onConfirmDownload = updateController::onUserConfirmDownload,
            onLater = updateController::onUserLater,
            onRetry = updateController::onUserRetry,
            onDismissFailed = updateController::onUserDismissFailed,
            onInstall = updateController::onUserInstall,
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
    val backgroundAuthorization = remember { AndroidBackgroundAuthorizationAdapter(context) }
    var batteryWhitelisted by remember { mutableStateOf(backgroundAuthorization.isGranted()) }

    // 设计稿"失联多少天"——复用 SENT-01 既有的 SentinelStore（不是新
    // 造的判定），距上次确认可达的天数；从未确认可达过（lastReachableAt
    // <= 0）时为 null，调用方（PhotosScreen）走不编造天数的兜底文案。
    fun computeDaysUnreachable(): Int? {
        val last = com.hawkeyexb.ppass.backup.SentinelStore(context.filesDir).load().lastReachableAt
        if (last <= 0) return null
        return ((System.currentTimeMillis() - last) / (24 * 60 * 60 * 1000L)).toInt()
    }
    var daysUnreachable by remember { mutableStateOf(computeDaysUnreachable()) }
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
            log = { PLog.i("PPassTimeline", it) },
        )
    }
    // PRES-01: 前台轻心跳——ON_RESUME 起、ON_STOP 停（退后台绝不心跳，
    // 耗电红线）；app 在前台时 daemon 每 ~30s 收到一次 hello，桌面设备行
    // 才显示「在线」而不是「离线」（锁屏 ≠ 离开）。
    val heartbeat = remember {
        ForegroundHeartbeat(
            client, pairings, scope, com.hawkeyexb.ppass.backup.SentinelStore(context.filesDir),
            // #439: 桌面回来了，人就在 App 里——不等 10 分钟的探测。
            // #474: 同一个信号也交给照片 tab 的订阅——退避耗尽后桌面回来了，不用手点「重试」。
            onReachable = {
                com.hawkeyexb.ppass.backup.flow.onFlowDesktopReachable(context)
                timeline.onDesktopReachable()
            },
            // #466: 打开 App 就能发现「电脑端已移除这台手机」，不用等下一张新照片。
            onPairingLost = { epoch, failure ->
                com.hawkeyexb.ppass.backup.flow.flowDeliveryPairingLoss.record(
                    com.hawkeyexb.ppass.backup.flow.PairingEpoch(epoch), failure,
                )
            },
        )
    }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> {
                    batteryWhitelisted = backgroundAuthorization.isGranted()
                    // #540：白名单是前提、意图是真相源。用户在系统设置里把白名单加回来，回到 App 时
                    // 没有任何开关动作会经过这里——前提重新满足就按意图把生产者排回去。必须同步跑、
                    // 排在 foregroundCatchup() 之前：它门控在 enabled() 上，晚一拍这次补捞就白跳过了。
                    if (batteryWhitelisted) {
                        restoreAutoBackupAfterAuthorizationReturned(context, backgroundAuthorized = true, source = "resume")
                    }

                    daysUnreachable = computeDaysUnreachable()
                    mediaAccess = mediaAccess(context)
                    heartbeat.start()
                    timeline.start()
                    // MOB-38（2026-08-26 真机）：**每次回到前台都补捞一次。**
                    //
                    // 在此之前补捞只挂在 `LaunchedEffect(backupInterrupted)` 上，
                    // 那个键只有一个 → composition 存活期间只跑一次。Activity 走
                    // STOPPED → RESUMED（从 App 切去相机、拍照、再切回来）**不会**
                    // 让它重跑，composition 本身没被销毁。于是用户人就在 App 里
                    // 看着、期待它传，而那一刻没有任何补捞被发起——如果内容监听
                    // 那次也没接住（被 OEM 清过、防抖窗口边界、force-stop 之后
                    // 还没恢复），这张照片只能等 5h 周期兜底。
                    //
                    // 验收人原话：「在前台，一张照片很久也没有同步。……从我们
                    // app 切换到相机，这样就不算前台了吗？我记得咱们针对不同的
                    // app 状态有过讨论的啊。」——讨论过、也做了，上面那四行刷新
                    // 就是；**唯独备份补捞漏了**。
                    //
                    // 为什么放心「每次 resume 都补」：MOB-33 的 `backupInFlight`
                    // 互斥门在管线入口，重复触发的代价降到一次 CAS（抢不到就
                    // 早退）。在 MOB-33 之前这么做会造出一串并行备份——那正是
                    // MOB-33 的原症状。
                    foregroundCatchup()
                    // UPD-02 节点 2：回到前台顺手查一次更新（6h 节流门在
                    // controller 内，未过门直接早退，成本一次时间比较）。
                    updateController.onResume()
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
    /**
     * 这台电脑以前连过吗——**在这台手机上走完过 onboarding，且这台桌面的
     * 相册范围还在，就算连过。**
     *
     * MOB-114（#455）：原判据是 `flow-state/<id>/discovery-ledger.json` 在不在；
     * #413 的迁移删了整个 `flow-state/` 且之后没人再写，判据恒为 false，连回
     * 同一台电脑被当成新电脑。新判据用 [OnboardedDesktopsStore]——断开、配对
     * 失效、换台再换回都不清它（为什么不用 order 表 / pairing.json 等见该类）。
     *
     * MOB-92：范围也必须按**这台**桌面问。此前读的是全局那一份，于是
     * 「macOS → Windows → 回 macOS」时它非空（是给 Windows 选的那 2 个），
     * 直接回首页、用着错的范围开始备份，用户连重选的机会都没有。
     */
    fun hasExistingLedgerFor(pairing: Pairing): Boolean =
        isKnownDesktop(OnboardedDesktopsStore(context.filesDir), pairing.daemonNodeId) {
            BackupScopeStore(context, pairing.daemonNodeId).selectedBucketIds()?.isNotEmpty() == true
        }

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

    systemBackTarget(screen)?.let { target ->
        BackHandler { screen = target }
    }

    Box(Modifier.fillMaxSize()) {
    when (val s = screen) {
        is Screen.Welcome -> WelcomeScreen(
            onScan = {
                if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
                    == PackageManager.PERMISSION_GRANTED
                ) {
                    screen = Screen.Scan
                } else {
                    cameraPermission.launch(Manifest.permission.CAMERA)
                }
            },
            onManual = { screen = Screen.ManualPair },
        )

        // #421：Waiting / Trouble 返回或「重新扫码」都回 Scan；没有摄像头权限
        // （走手动串过来的）就以手动页起步，不开相机、也不弹权限。
        is Screen.Scan -> ScanScreen(
            onQr = { qr -> screen = Screen.Waiting(qr) },
            onCancel = { screen = Screen.Welcome },
            startManual = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED,
        )

        is Screen.ManualPair -> ScanScreen(
            onQr = { qr -> screen = Screen.Waiting(qr) },
            onCancel = { screen = Screen.Welcome },
            startManual = true,
        )

        is Screen.Waiting -> {
            PairStatusScreen(
                title = androidx.compose.ui.res.stringResource(R.string.pair_waiting_title),
                body = androidx.compose.ui.res.stringResource(R.string.pair_waiting_body),
                action = androidx.compose.ui.res.stringResource(R.string.cancel) to
                    { screen = Screen.Welcome },
            )
            LaunchedEffect(s.qr) {
                // Every throw (missing native lib, NET-28 bind timeout, …)
                // becomes Failed inside bindThenPair — never a crash, never
                // an endless wait (bind is bounded inside DaemonClient).
                val outcome = bindThenPair(
                    bind = { client.bind(identity.secretKey()) },
                    pair = {
                        pairWithQr(
                            client,
                            s.qr,
                            deviceName(),
                            invalidCodeMessage = context.getString(R.string.not_a_code),
                            unparseableCodeMessage = context.getString(R.string.pair_unparseable_code),
                            storageDeviceNameFallback = context.getString(R.string.storage_device_default),
                        )
                    },
                )
                // The user may have cancelled while we waited — a stale
                // result must not yank them out of another screen.
                if (screen != s) return@LaunchedEffect
                when (outcome) {
                    is PairOutcome.Joined -> {
                        pairings.save(outcome.pairing)
                        // #565：重新配上这台电脑——之前断开时还没送到的旧通知不必再发
                        // （daemon 按纪元判，送到也不会吊销新配对；这里是不再白跑）。
                        UnpairNotice.cancel(context, outcome.pairing.daemonNodeId)
                        // MOB-87: 配对成功这个状态跃迁，此前**没有任何人接**。
                        // 补捞只挂在 `LaunchedEffect(backupInterrupted)`（键里
                        // 没有配对状态）和 `ON_RESUME`（会话内重新扫码用户一直
                        // 在 App 里，不走 STOPPED→RESUMED）——两个都接不住，
                        // 于是"配对完成了却毫无动静"，必须杀 App 重开。
                        //
                        // 顺带跑一轮远端对账：断开期间桌面那边什么都可能发生过，
                        // 这是最该核对一次的时刻，也是真机验收这条链最快的触发点
                        // （不必等 5 小时兜底）。
                        requestFlowWakeAfterRepair(context)
                        // M4（全页面状态稿）：桌面点"允许"之后不再停一个要
                        // 点按钮的 Joined 中间页——直接进选相册（用户实机
                        // 反馈"扫完等 desktop 允许自己跳选择相册页面不行？"）；
                        // firstTime=true 标记这是 onboarding 首次选相册，
                        // 选完才过 M6 安心收尾页。
                        //
                        // MOB-87（2026-09-20 验收人定调）：**这是"第一次"才该
                        // 走的路。** 重新连回一台**以前连过的**电脑，账本还在，
                        // 相册选择也还在——再让人把 onboarding 重走一遍是白让
                        // 他干一遍活。识别出来就直接回首页，让对账去把差异补上。
                        if (hasExistingLedgerFor(outcome.pairing)) {
                            // MOB-93: 这条路跳过 onboarding，所以恢复自动
                            // 备份这件事没有别人会做——断开时留下的意图在
                            // 这里兑现。不做的话，重连之后手机上一个自动
                            // 生产者都没有，而且不吭声。
                            restoreAutoBackupAfterRepair(
                                context,
                                backgroundAuthorization.isGranted(),
                            )
                            screen = Screen.Home(outcome.pairing)
                        } else {
                            // MOB-93: 换一台新电脑 = 新的信任关系，后台备份
                            // 要重新问一次。清意图放在这里（而不是断开时），
                            // 正是原注释所说的「the next onboarding」。
                            AutoBackupPrefs(context.filesDir).setRequested(false)
                            enterBucketPicker(outcome.pairing, firstTime = true)
                        }
                    }
                    is PairOutcome.Refused -> screen = Screen.Trouble(
                        // NET-10: expired / desktop restarted / desktop too old
                        // are not "the computer said no".
                        if (outcome.ownerSaidNo) R.string.pair_refused_title else R.string.pair_lapsed_title,
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
            // MOB-88: holder 改成订阅之后，它的监听器挂在进程级的账本总线上，
            // 不解订阅就会随每次重进首页累积。轮询时代没有这个问题（协程随
            // scope 死掉），所以这个 DisposableEffect 是新增的必需品。
            DisposableEffect(holder) {
                onDispose { holder.dispose() }
            }
            // #541：权限档位（ON_RESUME / 权限弹窗回调重读）变了要让 holder 重数 n——授权不会触发
            // MediaStore 的 ContentObserver，也不会杀进程，不接这一下英雄卡就停在无权限时数出来的 0 / 0。
            LaunchedEffect(holder, mediaAccess) { holder.onMediaAccess(mediaAccess) }
            // MOB-114（#455）：存量补记——本修复前走完 onboarding 的桌面没有标记。
            LaunchedEffect(s.pairing.daemonNodeId) {
                withContext(Dispatchers.IO) {
                    backfillOnboardedOnHome(OnboardedDesktopsStore(context.filesDir), s.pairing.daemonNodeId) {
                        BackupScopeStore(context, s.pairing.daemonNodeId).selectedBucketIds()?.isNotEmpty() == true
                    }
                }
            }
            // UX-03: 极简设置状态（仅充电/仅 WiFi）——改开关即落盘 +
            // 按新约束重建周期任务。MOB-02 起语义为「需要充电/需要 Wi-Fi」
            // 两档运行条件（默认都开），设置页有后果描述 + 合成句。
            val backupSettings = remember { BackupSettings(context.filesDir) }
            var wifiOnly by remember { mutableStateOf(backupSettings.load().wifiOnly) }
            // M10（全页面状态稿）：通知开关的真实偏好。#130 起它管的是「需要处理」的确定事件通知
            // （配对失效 / 相册权限收回 / 系统停止后台备份），见 DefinitiveEventNotices.kt。
            val notifyOnFailurePrefs = remember {
                com.hawkeyexb.ppass.backup.NotifyOnFailurePrefs(context.filesDir)
            }
            var notifyOnFailure by remember {
                mutableStateOf(notifyOnFailurePrefs.enabled() && hasNotificationPermission(context))
            }
            var notificationRequestInFlight by remember { mutableStateOf(false) }
            // Explicit user intent is separate from whether Android can currently run it.
            val prefs = remember { AutoBackupPrefs(context.filesDir) }
            var userRequestedBackgroundBackup by remember { mutableStateOf(prefs.requested()) }
            // #540：生产者此刻是否真的开着。任何线程落盘（含进程启动对账）都会推进 revision，这里跟着重读——
            // 不在各个回调里手动刷新，漏一处就是「开关开、写着自动进行、实际 0 个任务」。
            val autoPrefsRevision by AutoBackupPrefs.revision.collectAsState()
            val autoBackupProducing = remember(autoPrefsRevision) { prefs.enabled() }
            var batteryRequestInFlight by remember { mutableStateOf(false) }
            val notificationPermission = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestPermission(),
            ) { granted ->
                notificationRequestInFlight = false
                notifyOnFailure = granted
                notifyOnFailurePrefs.setEnabled(granted)
            }
            val batteryPermission = rememberLauncherForActivityResult(
                ActivityResultContracts.StartActivityForResult(),
            ) {
                batteryRequestInFlight = false
                batteryWhitelisted = backgroundAuthorization.isGranted()
                if (batteryWhitelisted) {
                    if (backupInterrupted) {
                        resumeAfterInterruption(context)
                        backupInterrupted = false
                    } else enableAutoBackup(context)
                    // UI-12: 系统授权弹窗的结果——这个 launcher 被「去处理」
                    // 和「首次开启开关」两条路径共用，两者都是同一个系统
                    // 权限请求，结果反馈理应一致，不用按入口拆分。
                    scope.launch {
                        snackbarHostState.showSnackbar(
                            context.getString(R.string.background_backup_authorized),
                        )
                    }
                } else {
                    suspendAutoBackupUntilAuthorized(context)
                    scope.launch {
                        snackbarHostState.showSnackbar(
                            context.getString(R.string.background_backup_authorization_denied),
                        )
                    }
                }
            }
            // MOB-02 §三: 「需要 Wi-Fi」关闭需二次确认（移动网络消耗流量）。
            var pendingWifiOff by remember { mutableStateOf(false) }
            // SYNC-06: TimelineLoader 由 timeline holder 按配对创建/重建
            // （PhotoScreen 用户交互共用 holder.loader）——这里不再各自建。
            // tab 状态已提到 PPassApp 顶层（见上方声明），这里不再重复
            // remember，否则从相册选择页返回时会被重置回 Photos。
            // 2026-08-17 大图查看页导航修复：正在全屏看大图/视频时，
            // 主 [照片]/[设置] tab 栏根本不进组合树（不是盖住看不见）。
            var photoViewerOpen by remember { mutableStateOf(false) }
            // 存储电脑详情是二级页——打开时跟大图查看页一样把底部 tab
            // 栏整体隐藏（用户实机反馈：进了二级页底部 tab 还杵在那）。
            var storageDetailOpen by remember { mutableStateOf(false) }
            LaunchedEffect(batteryWhitelisted) {
                userRequestedBackgroundBackup = prefs.requested()
                if (!batteryWhitelisted && userRequestedBackgroundBackup) {
                    suspendAutoBackupUntilAuthorized(context)
                }
            }
            val backgroundBackupState = backgroundBackupStateOf(
                userEnabled = userRequestedBackgroundBackup,
                systemWhitelisted = batteryWhitelisted,
                producerEnabled = autoBackupProducing,
                watcherScheduled = !backupInterrupted,
                watcherInterrupted = backupInterrupted,
            )
            // UI-12 追加修正（2026-09-15，用户判断成立）：开关必须绑定
            // 用户真实意图（userRequestedBackgroundBackup），不能绑 Armed——
            // 否则系统一撤白名单，开关会在 UI 上自己跳回关闭，用户会误以为
            // 是自己手滑关的，或者以为 App 把设置清空了。系统层面的失效
            // 只改状态提示（见 HomeScreen 的 RuleSwitchRow hint），不改
            // 开关本身显示值；唯一能让开关变灰的只有用户自己点关。
            // UI-12 二次修正（用户判断成立）：不再维护"知道了"这个独立的
            // 忽略状态——横幅和设置页 hint 说的是同一件事，两个入口不能给
            // 两个不同承诺。见 HomeNotices.kt 的 NoticeHost 文档。
            // UI-12: 唯一入口，NoticeHost 的横幅动作与设置页 RuleSwitchRow
            // hint 共用同一个 lambda——两处各写一遍就是 MOB-33/34/35/38
            // 那种「漏一处」的形状（AGENTS.md 提炼函数的理由同款）。
            val resolveBackgroundBackup = {
                if (batteryWhitelisted) {
                    resumeAfterInterruption(context)
                    backupInterrupted = false
                    // #540：中断确认之后，挂起留下的 autoEnabled=false 也要回来——否则 Worker 与
                    // foregroundCatchup 的 enabled() 闸门仍关着，点了「恢复」等于没点。
                    restoreAutoBackupAfterAuthorizationReturned(context, backgroundAuthorized = true, source = "resolve")
                    // UI-12: 本地重挂 WorkManager 监听，没有会失败的路径——
                    // 真正传不传得出去要等这轮 Flow 跑完，那是 Trouble 状态/
                    // SystemFailureNotifier 的地盘，这里只诚实说"已发起"。
                    scope.launch {
                        snackbarHostState.showSnackbar(
                            context.getString(R.string.background_backup_resuming),
                        )
                    }
                } else if (!batteryRequestInFlight) {
                    batteryRequestInFlight = true
                    batteryPermission.launch(backgroundAuthorization.requestIntent())
                }
                Unit
            }
            val scope = rememberCoroutineScope()
            // NET-28: bind can now throw (timeout) — an uncaught throw in a
            // LaunchedEffect would crash Home. This is only a warm-up; every
            // real use binds again and reports its own failure.
            LaunchedEffect(Unit) {
                runCatching { client.bind(identity.secretKey()) }
                    .onFailure { PLog.w("PPassBind", "home warm-up bind failed: $it") }
            }
            val mediaPermission = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestMultiplePermissions()
            ) { grants -> if (grants.values.any { it }) holder.backupNow() }
            // 存储端移除/吊销本设备后：本地照清（无需 unpair，daemon 端
            // 本就不认本设备），直达扫码，新 token 走 rejoin 门
            // 重建——备份页、照片页的失联红卡按同一个动作走。
            // UI-18（#355）：这是**恢复**路径，不是开场路径——直达扫码，不回
            // onboarding 第一页。相机权限已给过就不再问；只有被系统收回时
            // 才请求（授权回调本来就落到 Scan）。扫码成功后连回同一台电脑走
            // 快速重连回 Screen.Home，`tab` 是 PPassApp 顶层状态，回到点击前的那个。
            val onRepairPairing = {
                scope.launch {
                    withContext(Dispatchers.IO) { clearLocalPairing(context, s.pairing) }
                    val cameraGranted = ContextCompat.checkSelfPermission(
                        context, Manifest.permission.CAMERA,
                    ) == PackageManager.PERMISSION_GRANTED
                    screen = repairScanTarget(cameraGranted)
                    if (!cameraGranted) cameraPermission.launch(Manifest.permission.CAMERA)
                }
                Unit
            }
            TwoTabs(
                tab = tab,
                onTab = { tab = it },
                showTabBar = !photoViewerOpen && !storageDetailOpen,
                // M13 哨兵态：长期失联时设置图标角标红点，跟照片页的失联
                // 红卡同一个信号源（holder.pairingLost），不额外判天数。
                // 后台备份只在真出问题（待授权白名单 / 监听被系统清掉）时
                // 才亮红点——此前误写成 != OffByUser，导致正常 Armed（用户
                // 开着、白名单已过、监听健康）也常年亮红点，即使一切正常
                // 用户也永远看到红点，是个逻辑 bug（2026-09-15 用户反馈）。
                settingsAlert = holder.pairingLost.value ||
                    backgroundBackupState == BackgroundBackupState.NeedsSystemAuthorization ||
                    backgroundBackupState == BackgroundBackupState.SystemStoppedWatcher,
                // UI-04a/c: 全局唯一提示宿主——把五条提示的输入集中到
                // NoticeHost，只渲染最高优先级的一条，Photos/Backup 两页
                // 都可见（不再只有总览页）。
                notice = if (!photoViewerOpen && !storageDetailOpen) {
                    {
                        NoticeHost(
                            backgroundBackupState = backgroundBackupState,
                            onResolveBackgroundBackup = resolveBackgroundBackup,
                        )
                    }
                } else null,
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
                        // 2026-09-07 真机反馈：命令处理中禁用暂停/取消按钮。
                        commandPending = holder.commandPending.value,
                        // MOB-61: 缺源只读告知仍留在 HomeScreen（信息类，无动作）。
                        missingSourceNotice = holder.missingSourceNotice.value,
                        onAcknowledgeMissingSource = { holder.acknowledgeMissingSourceNotice() },
                        acknowledgedMissingSourceCount = holder.acknowledgedMissingSourceCount.value,
                        // #418：正在传的这一张的字节进度（与前台服务通知同一个函数）。
                        transferProgress = holder.transferProgress.value,
                        // #250 / #251：当前这一张——文件名（单行、中间省略）、「12.3 / 189 MB」、字节停滞时的「在等」。
                        transferRow = holder.transferRow.value,
                        // #418：「取消剩余 N 张」——设置卡一行 + 写明 N 的确认框。
                        cancelRemainingCount = holder.cancelRemainingCount.value,
                        onRequestCancelRemaining = { holder.requestCancelRemaining() },
                        cancelConfirmCount = holder.cancelConfirmCount.value,
                        // 「已跳过的照片 N 张 · 点击恢复」（SKIPPED_BY_USER）。
                        skippedCount = holder.skippedCount.value,
                        onRestoreSkipped = { holder.restoreSkipped() },
                        onConfirmCancelRemaining = { holder.confirmCancelRemaining() },
                        onDismissCancelRemaining = { holder.dismissCancelRemaining() },
                        // 规则 P（#418）：FGS 受阻而等待时的人话（null ⇒ 状态行一个字都不加）。
                        waitReasonRes = holder.waitReasonNotice.value,
                        // #413 §7：桌面剩余空间不足 5 GiB 的预警。
                        desktopLowSpace = holder.desktopLowSpace.value,
                        wifiOnly = wifiOnly,
                        onWifiOnlyChange = { enable ->
                            // MOB-02 §三: 关闭「需要 Wi-Fi」需二次确认
                            // （移动网络也会备份，可能消耗流量）。
                            if (!enable) pendingWifiOff = true
                            else {
                                wifiOnly = true
                                backupSettings.save(wifiOnly)
                                rescheduleAutoBackup(context)
                            }
                        },
                        notifyOnFailure = notifyOnFailure,
                        onNotifyOnFailureChange = { enabled ->
                            if (!enabled) {
                                notifyOnFailure = false
                                notifyOnFailurePrefs.setEnabled(false)
                            } else if (hasNotificationPermission(context)) {
                                notifyOnFailure = true
                                notifyOnFailurePrefs.setEnabled(true)
                            } else if (!notificationRequestInFlight) {
                                notificationRequestInFlight = true
                                notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                            }
                        },
                        pairedAt = s.pairing.pairedAt,
                        autoBackupEnabled = userRequestedBackgroundBackup,
                        backgroundBackupState = backgroundBackupState,
                        onResolveBackgroundBackup = resolveBackgroundBackup,
                        onToggleAutoBackup = { enabled ->
                            if (!enabled) {
                                batteryRequestInFlight = false
                                userRequestedBackgroundBackup = false
                                BackupHealthPrefs(context.filesDir).acknowledge()
                                backupInterrupted = false
                                disableAutoBackup(context)
                            } else if (batteryWhitelisted) {
                                userRequestedBackgroundBackup = true
                                if (backupInterrupted) {
                                    resumeAfterInterruption(context)
                                    backupInterrupted = false
                                } else enableAutoBackup(context)
                            } else if (!batteryRequestInFlight) {
                                batteryRequestInFlight = true
                                prefs.setRequested(true)
                                userRequestedBackgroundBackup = true
                                batteryPermission.launch(backgroundAuthorization.requestIntent())
                            }
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
                        // #565：通知电脑走发件箱——先把「我断开了这次配对」登记成持久任务
                        // （自带地址与纪元），再清本地；电脑此刻不在线也会在它回来后送到。
                        onDisconnect = {
                            scope.launch {
                                UnpairNotice.enqueue(context, s.pairing)
                                withContext(Dispatchers.IO) { clearLocalPairing(context, s.pairing) }
                                screen = Screen.Welcome
                            }
                            Unit
                        },
                        // 存储端移除/吊销本设备后：主按钮变「重新扫码连接」——
                        // 本地照清（无需 unpair，daemon 端本就不认本设备），
                        // 直达扫码（UI-18），新 token 走 rejoin 门重建。
                        pairingLost = holder.pairingLost.value,
                        onRepair = onRepairPairing,
                        onStorageDetailOpenChange = { storageDetailOpen = it },
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
                        // 失败红卡「再试一次」——不是常驻设置页入口，
                        // MOB-43（2026-08-27）已拍板不建那个入口。
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
                        mediaAccess = mediaAccess,
                        onOpenAppSettings = { openAppDetailsSettings(context) },
                        // UPD-02: 设置行「检查更新」——value 跟随状态机
                        // （下载中显示百分比 / 待安装显示「可安装」），
                        // 点击行为按当前状态分流（重新打开已收起的对话框 /
                        // 手动检查），全部在 controller 一处判定。
                        updateRowValue = when (val us = updateState) {
                            is UpdateUiState.Downloading ->
                                if (us.total > 0) {
                                    context.getString(
                                        R.string.update_row_downloading,
                                        (us.received * 100 / us.total).toInt(),
                                    )
                                } else {
                                    context.getString(R.string.update_downloading_unknown_total)
                                }
                            is UpdateUiState.Verifying ->
                                context.getString(R.string.update_verifying)
                            is UpdateUiState.ReadyToInstall ->
                                context.getString(R.string.update_row_ready)
                            else -> null
                        },
                        onCheckUpdate = { updateController.onCheckRowClick() },
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
                            backupSettings.save(false)
                            rescheduleAutoBackup(context)
                            // #413：引擎可能正因为 Wi‑Fi 在等——用户刚放开限制，人在场，立即重新检查一次，
                            // 等待原因随之更新（否则「将在连上 Wi-Fi 后进行」会挂到下一次触发）。
                            requestFlowWake(context, TriggerReason.MANUAL)
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
                        // MOB-20: 必须在 saveScope 覆盖旧集合**之前**算差集。
                        val prevScope = BackupScopeStore(context).selectedBucketIds()
                        // MOB-40: `prevScope == null` = **从未选过范围**。旧语义下
                        // 那意味着「已经全备过了」，所以差集算空；新语义下没选过
                        // = 一张都没备过，首次选择就是**全部新增**，按 MOB-20 的
                        // 规矩应当归零水位（否则得靠 MOB-36 的补齐兜底才收敛，
                        // 语义不自洽）。
                        val added = if (prevScope == null) sel else sel - prevScope

                        scopeStore.saveScope(
                            selected = sel,
                            allCurrent = list.map { it.id }.toSet(),
                        )
                        // REBUILD-05: 范围扩大不再重置 legacy watermark。
                        // 新 Flow 以当前 discovery cursor 为上界持久化历史补扫；
                        // 它不扰动当前严格队头，结果只会追加到后续队列。
                        // M6 完成页（全页面状态稿，用户实机反馈"只有首次
                        // onboarding 才需要"）。首次选择只保存范围：没有点
                        // 「进入 App」就绝不 discovery/传输。设置页重选不经过
                        // 收尾页，仍按用户在场操作立即补扫。
                        if (s.firstTime) {
                            val selectedCount = list.filter { it.id in sel }.sumOf { it.count }
                            screen = Screen.Started(s.pairing, selectedCount)
                        } else {
                            val settings = BackupSettings(context.filesDir).load()
                            val constraintsSatisfied = !settings.wifiOnly || isOnUnmetered(context)
                            if (added.isNotEmpty()) {
                                requestFlowScopeBackfillAndWake(context, constraintsSatisfied)
                            }
                            triggerUserPresentBackup(context)
                            screen = Screen.Home(s.pairing)
                        }
                    },
                    onCancel = { screen = Screen.Home(s.pairing) },
                )
            }
        }

        is Screen.Started -> {
            // 后台备份是用户可选能力，只在用户选「开启」时才申请。首次传输不依赖任何可选授权。
            // #130（用户拍板）：Android 13+ 在这里**只问一次**通知权限——完成页先一句话讲清用途，
            // 用户点任一按钮时先弹通知、再走原来的动作（两项系统授权串行，不叠框）。问过（含拒绝）
            // 就再也不问，之后只能从设置里的「通知」开关申请；老用户升级、Android 12 及以下不问。
            val finishOnboarding = {
                // MOB-114（#455）：「连过这台」的事实在这里落盘，快速重连只认它。
                OnboardedDesktopsStore(context.filesDir).markOnboarded(s.pairing.daemonNodeId)
                val settings = BackupSettings(context.filesDir).load()
                val constraintsSatisfied = !settings.wifiOnly || isOnUnmetered(context)
                requestFlowScopeBackfillAndWake(context, constraintsSatisfied)
                triggerUserPresentBackup(context)
                screen = Screen.Home(s.pairing)
            }
            val batteryPermission = rememberLauncherForActivityResult(
                ActivityResultContracts.StartActivityForResult(),
            ) {
                if (backgroundAuthorization.isGranted()) enableAutoBackup(context)
                else suspendAutoBackupUntilAuthorized(context)
                finishOnboarding()
            }
            val onEnableBackgroundBackup = {
                if (backgroundAuthorization.isGranted()) {
                    enableAutoBackup(context)
                    finishOnboarding()
                } else {
                    AutoBackupPrefs(context.filesDir).setRequested(true)
                    batteryPermission.launch(backgroundAuthorization.requestIntent())
                }
            }
            val askNotifications = remember {
                notificationAsk.shouldAsk(Build.VERSION.SDK_INT, hasNotificationPermission(context))
            }
            var afterNotificationAsk by remember { mutableStateOf<(() -> Unit)?>(null) }
            val onboardingNotificationPermission = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestPermission(),
            ) { granted ->
                notificationAsk.onResult(granted, com.hawkeyexb.ppass.backup.NotifyOnFailurePrefs(context.filesDir))
                afterNotificationAsk?.invoke()
                afterNotificationAsk = null
            }
            // 用户点了按钮：该问就先问（先落盘「问过」再弹），弹窗结果回来后继续原动作。
            val thenContinue = { next: () -> Unit ->
                if (askNotifications && notificationAsk.shouldAsk(Build.VERSION.SDK_INT, hasNotificationPermission(context))) {
                    notificationAsk.markAsked()
                    afterNotificationAsk = next
                    onboardingNotificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                } else {
                    next()
                }
            }
            BackupStartedScreen(
                photoCount = s.photoCount,
                onEnableBackgroundBackup = { thenContinue(onEnableBackgroundBackup) },
                onEnter = { thenContinue(finishOnboarding) },
                notificationAskNote = askNotifications,
            )
        }
    }
    // UI-12: 自定义 Snackbar 视觉——用 PPColor（墨底纸字），跟横幅/红卡
    // 同一套语义色系，不用 M3 默认的 surfaceInverse 配色。
    SnackbarHost(
        hostState = snackbarHostState,
        modifier = Modifier
            .align(Alignment.BottomCenter)
            .safeDrawingPadding()
            .padding(16.dp),
    ) { data ->
        Snackbar(
            containerColor = PPColor.Ink,
            contentColor = PPColor.Paper,
            shape = RoundedCornerShape(PPSize.RadiusControl),
        ) {
            Text(data.visuals.message, fontSize = 14.sp)
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

/** 通知权限现状（API<33 恒真——那些版本装完就有，没有运行时权限这
 *  一说）；只喂 HomeScreen 的不堵路引导卡，不参与任何 onboarding 流程。 */
private fun hasNotificationPermission(context: Context): Boolean =
    if (Build.VERSION.SDK_INT >= 33) {
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    } else {
        true
    }

/**
 * MOB-94: 相册权限三档的生产查询点。
 *
 * `imagesGranted` 取的是**主相册权限**——API 33+ 是 READ_MEDIA_IMAGES，
 * 更低版本是 READ_EXTERNAL_STORAGE（minSdk 26，那些机器上前者根本不存在，
 * 查它必然 DENIED，会把完整授权误判成全拒）。
 */
private fun mediaAccess(context: Context): MediaAccess =
    com.hawkeyexb.ppass.backup.currentMediaAccess(context) // #130：与确定事件通知共用同一个查询点

/** MOB-02 §二: 部分授权检测（走纯函数判定，权限查询为生产注入）。
 *  路由判据保持原样——「只给了部分」与「全拒」在这里不可混用。 */
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
 * 本地单方断开（UX-06/UX-06b 语义）。断开与「配对已失效重新扫码」共用此清理；
 * 不依赖 daemon 是否可达/是否已撤销本设备。
 *
 * MOB-95（#282）：留什么、清什么**只在** [DisconnectState] 里声明，这里只把
 * 清单里的运行时动作接到 Context 上，不另写任何处置。
 */
private fun clearLocalPairing(
    context: Context,
    pairing: Pairing,
) {
    val work = WorkManager.getInstance(context)
    applyDisconnectManifest(
        context.filesDir,
        object : DisconnectRuntime {
            override fun stopFlowRuntime() = clearFlowRuntime(context, pairing.daemonNodeId)
            override fun cancelUniqueWork(name: String) {
                work.cancelUniqueWork(name)
            }
            override fun cancelMediaWatch() = com.hawkeyexb.ppass.backup.cancelMediaWatch(context)
        },
    )
    // 登记门禁的真机一半：断开后私有目录里出现清单之外的东西，留一行日志（不拦断开）。
    context.filesDir.parentFile?.let { dataDir ->
        unregisteredStatePaths(dataDir).takeIf { it.isNotEmpty() }?.let {
            PLog.w("PPassDisconnect", "unregistered app state (register in DisconnectState): $it")
        }
    }
}
