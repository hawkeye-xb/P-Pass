// UPD-02: 更新状态机——「检查 → 决策 → 下载 → 校验 → 安装 → 回执」全链
// 状态在这一个类里汇合，UI（UpdateDialog / 设置行 / Snackbar）只渲染
// [state]，不各自猜现在进行到哪一步。
//
// 触发时机（用户拍板：只挂节点 1+2，不做后台预检）：
//  1. 冷启动（onColdStart）
//  2. ON_RESUME（onResume）——两者过同一个 6h 节流门（shouldAutoCheck），
//     GitHub 匿名限流下这是硬约束；手动「检查更新」不受门限。
package com.hawkeyexb.ppass.update

import android.content.Context
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.hawkeyexb.ppass.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** 更新 UI 的互斥状态——任一时刻只会是其中一个。 */
sealed interface UpdateUiState {
    data object Idle : UpdateUiState

    /** 手动「检查更新」进行中（设置行内反馈，不弹窗）。 */
    data object Checking : UpdateUiState

    data class Available(val info: UpdateInfo, val manual: Boolean) : UpdateUiState
    data class Downloading(val received: Long, val total: Long, val version: String) : UpdateUiState
    data class Verifying(val version: String) : UpdateUiState
    data class Failed(val kind: UpdateFailureKind, val version: String) : UpdateUiState
    data class ReadyToInstall(val version: String) : UpdateUiState
    data class Installing(val version: String) : UpdateUiState
}

/** Snackbar 级的一过性反馈（res + 可选格式化参数）。 */
data class UpdateNotice(val textRes: Int, val arg: String? = null)

/** WorkManager 状态 → 归约输入（提纯出来，JVM 可测，不依赖 WorkInfo）。 */
internal enum class WorkSignal { None, Enqueued, Running, Succeeded, Failed, Cancelled }

/**
 * worker 信号 + 进度 + 待办 → UI 状态（纯函数，UpdateWorkReduceTest 锁真值表）。
 * None/Cancelled 不归约出结果（null）——调用方按「无事发生」处理，避免
 * 「pending 已写、work 还没入队可见」的竞态把进行中的状态打回 Idle。
 */
internal fun reduceWorkSignal(
    signal: WorkSignal,
    received: Long,
    total: Long,
    verifying: Boolean,
    failureKind: UpdateFailureKind?,
    pending: PendingUpdate,
): UpdateUiState? = when (signal) {
    WorkSignal.Enqueued, WorkSignal.Running ->
        if (verifying) {
            UpdateUiState.Verifying(pending.version)
        } else {
            UpdateUiState.Downloading(received, total, pending.version)
        }
    WorkSignal.Succeeded -> UpdateUiState.ReadyToInstall(pending.version)
    WorkSignal.Failed ->
        UpdateUiState.Failed(failureKind ?: UpdateFailureKind.Unexpected, pending.version)
    WorkSignal.None, WorkSignal.Cancelled -> null
}

/** 自动检查遇到落盘待办时该怎么走（[pendingAutoCheckAction] 的结果）。 */
internal enum class PendingAutoCheckAction {
    /** 没有待办：照常检查。 */
    Check,

    /** 待办在、work 记录也在：更新线还活着，交给 observeWorker 驱动，不再查。 */
    Skip,

    /** 待办在、work 记录已没了：待办是孤儿，清掉后照常检查。 */
    ClearStaleThenCheck,
}

/**
 * UPD-21: 自动检查前对落盘待办的判定（纯函数，UpdateWorkReduceTest 锁真值表）。
 * WorkManager 在每次打开内部库时剪掉「终态且入队已满 1 天」的记录
 * （CleanupCallback，PRUNE_THRESHOLD_MILLIS = 1 天；我们没设 keepResultsForAtLeast）。
 * 用户对「待安装 / 下载失败」点了稍后或直接划掉进程、隔天再冷启动，记录就没了，
 * 而 pending 只在安装回执 / 失败关闭 / 取消时清——只看 pending 就会永久跳过。
 * 记录不在（None）或已取消（Cancelled）= 这条更新线已没有人驱动，按孤儿处理。
 */
internal fun pendingAutoCheckAction(
    pending: PendingUpdate?,
    signal: WorkSignal,
): PendingAutoCheckAction = when {
    pending == null -> PendingAutoCheckAction.Check
    signal == WorkSignal.None || signal == WorkSignal.Cancelled ->
        PendingAutoCheckAction.ClearStaleThenCheck
    else -> PendingAutoCheckAction.Skip
}

/**
 * 自动检查的完整门序（UPD-21 抽出，JVM 可测——controller 只注入 work 记录读取
 * 与真正的检查动作）：6h 节流门 → 非空闲不查 → 待办判定 → [check] → 记账。
 * 返回是否真的发起了检查。
 */
internal suspend fun runAutoCheck(
    prefs: UpdatePrefs,
    now: () -> Long,
    isIdle: () -> Boolean,
    readWorkSignal: suspend () -> WorkSignal,
    check: suspend () -> Unit,
    onOrphanCleared: (version: String) -> Unit = {},
): Boolean {
    if (!shouldAutoCheck(prefs.lastCheckAt(), now())) return false
    if (!isIdle()) return false
    val pending = prefs.pendingUpdate()
    if (pending != null) {
        // 已有一条更新线在走（下载中/待安装/待用户决策）就别再查——但要以
        // work 记录为准，而不是只看 pending：记录被 WorkManager 剪掉后
        // pending 成了孤儿，只看它会让自动检查永久停摆。
        when (pendingAutoCheckAction(pending, readWorkSignal())) {
            PendingAutoCheckAction.Skip -> return false
            PendingAutoCheckAction.ClearStaleThenCheck -> {
                // 只清待办、回到可检查状态，不按 pending 重新入队：pending 记的
                // 可能是旧版本（隔了至少一天，新版可能已发），也可能是用户已
                // 放着不管的失败线；重新检查拿最新 manifest，让用户再决定。
                // cache 里的已验包不删：同一份更新再次确认下载时，Worker 按
                // 产物身份（UPD-19）直接复用，不重下；不同的会被认领时清掉。
                if (!isIdle()) return false
                prefs.clearPending()
                onOrphanCleared(pending.version)
            }
            PendingAutoCheckAction.Check -> Unit
        }
    }
    check()
    // 无论成败都记账——限流环境下失败也是一次检查，不能每次 resume 都打。
    prefs.markChecked(now())
    return true
}

class UpdateUiController(
    private val context: Context,
    private val scope: CoroutineScope,
    private val versionName: String,
    private val prefs: UpdatePrefs = UpdatePrefs(context.filesDir),
    private val source: UpdateSource = defaultUpdateSource(),
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val _state = MutableStateFlow<UpdateUiState>(UpdateUiState.Idle)
    val state: StateFlow<UpdateUiState> = _state.asStateFlow()

    /** 一过性反馈（已是最新 / 检查失败 / 已更新到 vX）——Snackbar 渲染。 */
    val notices = MutableSharedFlow<UpdateNotice>(extraBufferCapacity = 4)

    private val workManager = WorkManager.getInstance(context)

    /** 用户点了「稍后」的待安装版本——本次会话内不再自动顶出来，冷启动复位。 */
    private var suppressedReadyVersion: String? = null
    private var lastSignal: WorkSignal = WorkSignal.None

    /**
     * 下载中「后台下载」的对话框压制：状态照样推进（worker 信号不停），
     * 只是对话框不顶在用户面前；设置行点击可重新打开。失败/待安装
     * 出现时必须解除压制——结果要诚实送到用户面前。
     */
    val dialogSuppressed = MutableStateFlow(false)

    init {
        receiptCheck()
        observeWorker()
    }

    /**
     * 升级回执：上次退出前的版本 ≠ 当前版本 = APK 真的换上来了——
     * 给用户一句确认，并清掉上个版本留下的下载产物与待办。
     */
    private fun receiptCheck() {
        val seen = prefs.lastSeenVersion()
        if (seen == null) {
            prefs.markSeenVersion(versionName) // 这版第一次跑：只记基线
        } else if (seen != versionName) {
            prefs.markSeenVersion(versionName)
            prefs.clearPending()
            UpdateDownloadWorker.cancel(context)
            updateApkFile(context.cacheDir).delete()
            completeMarkerFile(context.cacheDir).delete()
            notices.tryEmit(UpdateNotice(R.string.update_installed_snackbar, versionName))
        }
    }

    private fun observeWorker() {
        scope.launch {
            workManager.getWorkInfosForUniqueWorkFlow(UpdateDownloadWorker.UNIQUE_WORK_NAME)
                .collect { infos ->
                    val pending = prefs.pendingUpdate() ?: return@collect
                    val info = infos.firstOrNull()
                    val signal = signalOf(info)
                    lastSignal = signal
                    if (signal == WorkSignal.Cancelled) {
                        // 取消 = 这条更新线作废（含升级回执里的清理），落盘一起清。
                        prefs.clearPending()
                        if (_state.value !is UpdateUiState.Idle) {
                            _state.value = UpdateUiState.Idle
                        }
                        return@collect
                    }
                    // 「稍后」压住的待安装：本次会话内不再自动顶出。
                    if (signal == WorkSignal.Succeeded &&
                        suppressedReadyVersion == pending.version
                    ) {
                        return@collect
                    }
                    val reduced = reduceWorkSignal(
                        signal = signal,
                        received = info?.progress?.getLong(UpdateDownloadWorker.PROGRESS_RECEIVED, 0L) ?: 0L,
                        total = info?.progress?.getLong(UpdateDownloadWorker.PROGRESS_TOTAL, -1L) ?: -1L,
                        verifying = info?.progress?.getBoolean(UpdateDownloadWorker.PROGRESS_VERIFYING, false) ?: false,
                        failureKind = info?.outputData?.getString(UpdateDownloadWorker.KEY_FAILURE_KIND)
                            ?.let { runCatching { UpdateFailureKind.valueOf(it) }.getOrNull() },
                        pending = pending,
                    ) ?: return@collect
                    // 安装交互进行中（用户在系统确认页上）不许被 worker 信号覆盖。
                    if (_state.value is UpdateUiState.Installing) return@collect
                    _state.value = reduced
                    // 终态（失败/待安装）必须顶到用户面前，解除「后台下载」压制。
                    if (reduced is UpdateUiState.Failed || reduced is UpdateUiState.ReadyToInstall) {
                        dialogSuppressed.value = false
                    }
                }
        }
    }

    // ── 触发节点 1+2：冷启动 / ON_RESUME，共用 6h 节流门 ──

    fun onColdStart() = autoCheck()

    fun onResume() = autoCheck()

    private fun autoCheck() {
        scope.launch {
            runAutoCheck(
                prefs = prefs,
                now = now,
                isIdle = { _state.value is UpdateUiState.Idle },
                // 直接读库而不用 lastSignal：冷启动时 observeWorker 可能还没收到
                // 第一帧，lastSignal 的默认 None 会把活着的更新线误判成孤儿。
                readWorkSignal = {
                    signalOf(
                        workManager
                            .getWorkInfosForUniqueWorkFlow(UpdateDownloadWorker.UNIQUE_WORK_NAME)
                            .first()
                            .firstOrNull(),
                    )
                },
                onOrphanCleared = { version ->
                    android.util.Log.i(UPDATE_LOG_TAG, "orphan pending $version cleared: work record gone")
                },
                check = {
                    val outcome = checkUpdate(versionName, channelFromVersion(versionName), source)
                    if (outcome is UpdateCheckOutcome.Available &&
                        _state.value is UpdateUiState.Idle
                    ) {
                        dialogSuppressed.value = false
                        _state.value = UpdateUiState.Available(outcome.info, manual = false)
                    }
                },
            )
        }
    }

    // ── 设置行「检查更新」 ──

    /**
     * 行点击：有正在进行/被压住的更新线就把对话框重新打开；否则手动
     * 检查（不受 6h 门限，用户的意思表示）。
     */
    fun onCheckRowClick() {
        val s = _state.value
        if (dialogSuppressed.value &&
            (s is UpdateUiState.Downloading || s is UpdateUiState.Verifying)
        ) {
            dialogSuppressed.value = false
            return
        }
        val pending = prefs.pendingUpdate()
        if (pending != null && lastSignal == WorkSignal.Succeeded) {
            suppressedReadyVersion = null
            dialogSuppressed.value = false
            _state.value = UpdateUiState.ReadyToInstall(pending.version)
            return
        }
        checkNow()
    }

    fun checkNow() {
        if (_state.value is UpdateUiState.Checking) return
        scope.launch {
            _state.value = UpdateUiState.Checking
            when (val outcome = checkUpdate(versionName, channelFromVersion(versionName), source)) {
                is UpdateCheckOutcome.Available -> {
                    prefs.markChecked(now())
                    dialogSuppressed.value = false
                    _state.value = UpdateUiState.Available(outcome.info, manual = true)
                }
                UpdateCheckOutcome.UpToDate -> {
                    prefs.markChecked(now())
                    _state.value = UpdateUiState.Idle
                    notices.tryEmit(UpdateNotice(R.string.update_up_to_date))
                }
                UpdateCheckOutcome.Failed -> {
                    // 手动检查失败必须如实说「失败了」，不许装成「已是最新」（REL-07 抬到 UI）。
                    prefs.markChecked(now())
                    _state.value = UpdateUiState.Idle
                    notices.tryEmit(UpdateNotice(R.string.update_check_failed))
                }
            }
        }
    }

    // ── 对话框动作 ──

    /** 「下载安装」：落盘待办 + 入队后台下载，状态由 worker 信号接管。 */
    fun onUserConfirmDownload() {
        val s = _state.value as? UpdateUiState.Available ?: return
        prefs.markPending(
            PendingUpdate(
                version = s.info.version,
                notes = s.info.notes,
                url = s.info.url,
                sha256 = s.info.sha256,
                signature = s.info.signature,
            )
        )
        UpdateDownloadWorker.enqueue(context, s.info)
        dialogSuppressed.value = false
        _state.value = UpdateUiState.Downloading(0L, -1L, s.info.version)
    }

    /**
     * 「稍后」：Available 关掉本次；ReadyToInstall 压住本次会话（不清待办）；
     * Downloading/Verifying = 「后台下载」——只收对话框，worker 照跑。
     */
    fun onUserLater() {
        when (val s = _state.value) {
            is UpdateUiState.Available -> _state.value = UpdateUiState.Idle
            is UpdateUiState.ReadyToInstall -> {
                suppressedReadyVersion = s.version
                _state.value = UpdateUiState.Idle
            }
            is UpdateUiState.Downloading, is UpdateUiState.Verifying ->
                dialogSuppressed.value = true
            else -> Unit
        }
    }

    /** 「重试」（下载类失败）：按落盘的待办重新入队。 */
    fun onUserRetry() {
        val s = _state.value as? UpdateUiState.Failed ?: return
        val pending = prefs.pendingUpdate() ?: run {
            _state.value = UpdateUiState.Idle
            return
        }
        if (s.kind == UpdateFailureKind.Install) {
            // 安装失败：包还在、已验过——直接退回待安装，不重新下载。
            _state.value = UpdateUiState.ReadyToInstall(pending.version)
            return
        }
        UpdateDownloadWorker.enqueue(
            context,
            UpdateInfo(
                version = pending.version,
                notes = pending.notes,
                url = pending.url,
                sha256 = pending.sha256,
                signature = pending.signature,
            ),
        )
        _state.value = UpdateUiState.Downloading(0L, -1L, pending.version)
    }

    /** 失败框的「关闭」= 放弃这条更新线：清待办、清残包。 */
    fun onUserDismissFailed() {
        dialogSuppressed.value = false
        prefs.clearPending()
        UpdateDownloadWorker.cancel(context)
        updateApkFile(context.cacheDir).delete()
        completeMarkerFile(context.cacheDir).delete()
        _state.value = UpdateUiState.Idle
    }

    /** 「立即安装」：把已校验的包交给系统安装器，等待真实回执。 */
    fun onUserInstall() {
        val s = _state.value as? UpdateUiState.ReadyToInstall ?: return
        scope.launch {
            _state.value = UpdateUiState.Installing(s.version)
            when (UpdateInstaller.install(context, updateApkFile(context.cacheDir))) {
                UpdateInstaller.Outcome.Success -> {
                    // 真升级时进程随即被替换，多半走不到这里；同版本重装等
                    // 边缘情形就把现场收拾干净。
                    prefs.clearPending()
                    updateApkFile(context.cacheDir).delete()
                    completeMarkerFile(context.cacheDir).delete()
                    _state.value = UpdateUiState.Idle
                }
                UpdateInstaller.Outcome.AbortedByUser ->
                    _state.value = UpdateUiState.ReadyToInstall(s.version)
                is UpdateInstaller.Outcome.Failed, is UpdateInstaller.Outcome.Error ->
                    _state.value = UpdateUiState.Failed(UpdateFailureKind.Install, s.version)
            }
        }
    }
}

private fun signalOf(info: WorkInfo?): WorkSignal = when (info?.state) {
    null -> WorkSignal.None
    WorkInfo.State.ENQUEUED, WorkInfo.State.BLOCKED -> WorkSignal.Enqueued
    WorkInfo.State.RUNNING -> WorkSignal.Running
    WorkInfo.State.SUCCEEDED -> WorkSignal.Succeeded
    WorkInfo.State.FAILED -> WorkSignal.Failed
    WorkInfo.State.CANCELLED -> WorkSignal.Cancelled
}
