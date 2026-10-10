// REBUILD-04: framework wake adapter. Durable backup behavior lives in backup/flow.
package com.hawkeyexb.ppass.backup

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.hawkeyexb.ppass.backup.flow.TriggerReason
import com.hawkeyexb.ppass.backup.flow.WaitReason
import com.hawkeyexb.ppass.backup.flow.WakeScheduler
import com.hawkeyexb.ppass.backup.flow.runFlowWake
import java.util.concurrent.TimeUnit

const val BACKUP_WORK_NAME = "ppass-auto-backup"
const val CATCHUP_WORK_NAME = "ppass-catchup-backup"
const val PROCESS_CATCHUP_WORK_NAME = "ppass-process-catchup"
const val MANUAL_BACKUP_WORK_NAME = "ppass-manual-backup"
const val PERIODIC_FALLBACK_HOURS = 5L
const val CONTENT_UPDATE_DELAY_MS = 1_000L
const val CONTENT_MAX_DELAY_MS = 30_000L
private const val KEY_AUTOMATIC_WAKE = "automatic_wake"

/**
 * #417：这次唤醒的 [TriggerReason]。决定这一轮要不要对账（5h 兜底 = PERIODIC 对账，含问桌面「还在吗」；
 * 内容监听一拍一个，只做发现）、要不要查后台开关与电量（人在场的不查）。
 */
private const val KEY_REASON = "trigger_reason"

/** 0.9.10 及更早：探测梯是 3 条各自独立的 unique work（前缀 + 1..3）。只为撤掉升级前留下的而保留。 */
const val UNREACHABLE_PROBE_WORK_PREFIX = "ppass-unreachable-probe-"
private const val LEGACY_UNREACHABLE_PROBE_COUNT = 3

/**
 * #409 / #652：探测梯 = **一条** unique work 链，KEEP。链上还有没跑完的就不重排——包括正在跑的那一拍自己登记的时候。
 * 旧的三条独立 KEEP 会在某一拍跑完后被下一拍重新插入，梯子自我续期、不会停。
 * #762：退避——4 拍，每拍在前一拍结束后 10 / 20 / 40 / 80 分钟跑（累计约 2.5h），之后由 5h 周期兜底与事件接力。
 * 「一次故障只排一组」不靠 KEEP（拿到 FGS 后出错时梯子已走完或已被撤），靠引擎的持久化标记。
 */
const val UNREACHABLE_PROBE_LADDER_WORK_NAME = "ppass-unreachable-probe-ladder"
const val CONSTRAINT_WAKE_WORK_NAME = "ppass-constraint-wake"

/** #522：额度复位唤醒的唯一名。独立的一次性任务——不复用周期任务（WorkManager 会推迟提前强跑的周期任务）。 */
const val BUDGET_RESET_WAKE_WORK_NAME = "ppass-fgs-budget-reset-wake"
val UNREACHABLE_PROBE_DELAYS_MINUTES = listOf(10L, 20L, 40L, 80L)

/** The switch owns these producers, and deliberately does not own Manual. */
internal fun autoBackupWorkNames(): List<String> = listOf(
    BACKUP_WORK_NAME,
    CATCHUP_WORK_NAME,
    PROCESS_CATCHUP_WORK_NAME,
    MEDIA_WATCH_BACKUP_WORK_NAME,
)

private fun constraintsOf(spec: BackupConstraintsSpec): Constraints =
    Constraints.Builder()
        .setRequiredNetworkType(if (spec.requiresUnmetered) NetworkType.UNMETERED else NetworkType.CONNECTED)
        .setRequiresBatteryNotLow(spec.requiresBatteryNotLow)
        .build()

internal fun backupWorkRequest(
    spec: BackupConstraintsSpec,
    automatic: Boolean = true,
    reason: TriggerReason = TriggerReason.MEDIA_CHANGE,
    initialDelayMinutes: Long = 0L,
    initialDelayMs: Long = TimeUnit.MINUTES.toMillis(initialDelayMinutes),
): OneTimeWorkRequest =
    OneTimeWorkRequestBuilder<BackupWorker>()
        .setConstraints(constraintsOf(spec))
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
        .setInitialDelay(initialDelayMs, TimeUnit.MILLISECONDS)
        .setInputData(androidx.work.workDataOf(KEY_AUTOMATIC_WAKE to automatic, KEY_REASON to reason.name))
        .build()

/**
 * #417 的唤醒登记：
 * - 探测梯（桌面不可达；#409 / #652 起也用于桌面不健康、FGS 申请被拒；#762 起也用于手机侧意外错误）：一条 unique 链，
 *   4 个一次性任务，间隔见 [UNREACHABLE_PROBE_DELAYS_MINUTES]。KEEP：梯子没走完就不重排，反复失败既不会把探测往后推，
 *   也不会让梯子自我续期（见 [UNREACHABLE_PROBE_LADDER_WORK_NAME]）。登记与否由引擎的 `wakePlanOf` 与「退避已用」标记决定。
 * - 条件不满足：一个带相应约束的一次性任务（Wi‑Fi → UNMETERED，电量 → batteryNotLow）。
 */
class WorkManagerWakeScheduler(private val context: Context) : WakeScheduler {
    override fun scheduleUnreachableProbes() {
        val settings = BackupSettings(context.filesDir).load()
        val probes = UNREACHABLE_PROBE_DELAYS_MINUTES.map { delayMinutes ->
            backupWorkRequest(
                constraintsFor(BackupTier.USER_PRESENT, settings),
                automatic = false,
                reason = TriggerReason.UNREACHABLE_PROBE,
                initialDelayMinutes = delayMinutes,
            )
        }
        WorkManager.getInstance(context)
            .beginUniqueWork(UNREACHABLE_PROBE_LADDER_WORK_NAME, ExistingWorkPolicy.KEEP, probes.first())
            .let { chain -> probes.drop(1).fold(chain) { c, next -> c.then(next) } }
            .enqueue()
    }

    override fun cancelUnreachableProbes() {
        val wm = WorkManager.getInstance(context)
        wm.cancelUniqueWork(UNREACHABLE_PROBE_LADDER_WORK_NAME)
        for (i in 1..LEGACY_UNREACHABLE_PROBE_COUNT) wm.cancelUniqueWork("$UNREACHABLE_PROBE_WORK_PREFIX$i")
    }

    override fun scheduleWhenConditionsMet(reason: WaitReason) {
        val spec = when (reason) {
            WaitReason.WIFI -> BackupConstraintsSpec(requiresBatteryNotLow = false, requiresUnmetered = true)
            WaitReason.BATTERY -> BackupConstraintsSpec(
                requiresBatteryNotLow = true,
                requiresUnmetered = BackupSettings(context.filesDir).load().wifiOnly,
            )
            else -> return
        }
        WorkManager.getInstance(context).enqueueUniqueWork(
            CONSTRAINT_WAKE_WORK_NAME,
            ExistingWorkPolicy.REPLACE,
            backupWorkRequest(spec, automatic = false, reason = TriggerReason.CONSTRAINTS_MET),
        )
    }

    // #522：后台触发（automatic = true：后台备份关着就不跑），约束与其他后台生产者相同。REPLACE：见接口注释。
    override fun scheduleBudgetResetWake(delayMs: Long) {
        val settings = BackupSettings(context.filesDir).load()
        WorkManager.getInstance(context).enqueueUniqueWork(
            BUDGET_RESET_WAKE_WORK_NAME,
            ExistingWorkPolicy.REPLACE,
            backupWorkRequest(
                constraintsFor(BackupTier.BACKGROUND, settings),
                automatic = true,
                reason = TriggerReason.BUDGET_RESET,
                initialDelayMs = delayMs,
            ),
        )
    }

    override fun cancelBudgetResetWake() {
        WorkManager.getInstance(context).cancelUniqueWork(BUDGET_RESET_WAKE_WORK_NAME)
    }
}

// NET-06: this fires only when the user is looking at the screen right
// now (scope confirm / app foreground) — it must run regardless of the
// *background* auto-backup switch. `automatic=true` (the default) means
// "skip if the user turned auto-backup off", which is the correct guard
// for the periodic/process-catchup producers but wrongly silenced this
// one too: confirming a scope while "后台备份" was off left the picker
// screen with no visible reaction at all (found during NET-06 real-device
// regression, 2026-09-15). `automatic=false` here means what it means for
// triggerManualBackup below — "the user is the direct cause", not
// "auto-backup enabled".
fun triggerUserPresentBackup(context: Context) = enqueueFlowWake(
    context, CATCHUP_WORK_NAME, BackupTier.USER_PRESENT, ExistingWorkPolicy.KEEP, automatic = false,
    reason = TriggerReason.APP_FOREGROUND,
)

fun triggerManualBackup(context: Context) = enqueueFlowWake(
    context, MANUAL_BACKUP_WORK_NAME, BackupTier.MANUAL, ExistingWorkPolicy.KEEP, automatic = false,
    reason = TriggerReason.MANUAL,
)

fun cancelManualBackup(context: Context) {
    WorkManager.getInstance(context).cancelUniqueWork(MANUAL_BACKUP_WORK_NAME)
}

fun triggerProcessStartCatchup(context: Context) = enqueueFlowWake(
    context, PROCESS_CATCHUP_WORK_NAME, BackupTier.BACKGROUND, ExistingWorkPolicy.KEEP,
    reason = TriggerReason.PROCESS_START,
)

private fun enqueueFlowWake(
    context: Context,
    name: String,
    tier: BackupTier,
    policy: ExistingWorkPolicy,
    automatic: Boolean = true,
    reason: TriggerReason,
) {
    if (automatic && !AutoBackupPrefs(context.filesDir).enabled()) return
    val settings = BackupSettings(context.filesDir).load()
    WorkManager.getInstance(context).enqueueUniqueWork(
        name,
        policy,
        backupWorkRequest(constraintsFor(tier, settings), automatic, reason),
    )
}

fun scheduleAutoBackup(context: Context) {
    if (!AutoBackupPrefs(context.filesDir).enabled()) return
    val settings = BackupSettings(context.filesDir).load()
    val request = PeriodicWorkRequestBuilder<BackupWorker>(PERIODIC_FALLBACK_HOURS, TimeUnit.HOURS)
        .setConstraints(constraintsOf(constraintsFor(BackupTier.BACKGROUND, settings)))
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
        .setInputData(
            androidx.work.workDataOf(
                KEY_AUTOMATIC_WAKE to true,
                // 5h 兜底：这一轮对账（问桌面「还在吗」+ FAILED 兜底重试一次）。
                KEY_REASON to TriggerReason.PERIODIC.name,
            ),
        )
        .build()
    WorkManager.getInstance(context).enqueueUniquePeriodicWork(
        BACKUP_WORK_NAME,
        ExistingPeriodicWorkPolicy.UPDATE,
        request,
    )
    cancelLegacyContentTriggerWork(context)
    ensureMediaWatch(context)
}

fun rescheduleAutoBackup(context: Context) {
    scheduleAutoBackup(context)
}

/**
 * MOB-93: 重连回一台**以前连过的**电脑时，自动备份该怎么恢复。
 *
 * 纯判定，不碰 IO——`suspendAutoBackupForPairingChange` 把用户意图留下来了，
 * 这里只回答"按它该做什么"。
 */
enum class AutoBackupResume {
    /** 意图还在，授权也还在——把生产者重新排上。 */
    ENABLE,

    /** 意图还在，但后台授权没了——记着意图，先不排（与授权丢失时同一处置）。 */
    SUSPEND,

    /** 用户本来就没要后台备份——不许替他打开。 */
    LEAVE_OFF,
}

fun autoBackupResumeDecision(
    userRequested: Boolean,
    backgroundAuthorized: Boolean,
): AutoBackupResume = when {
    !userRequested -> AutoBackupResume.LEAVE_OFF
    backgroundAuthorized -> AutoBackupResume.ENABLE
    else -> AutoBackupResume.SUSPEND
}

/**
 * MOB-93: 断开配对时对自动备份策略的处置——**停生产者，留意图**。
 *
 * 旧写法把 `userRequested` 一起清成 false，理由写在注释里：「下一轮
 * onboarding 会重新问」。#257 加了快速重连（连回以前连过的电脑直接回
 * 首页、跳过 onboarding）之后，那个"重新问"不再必然发生，于是意图有去
 * 无回：5 小时周期（兜底对账的唯一载体）、前台补捞、相册变更监听三条
 * 链全部静默留在关闭态。
 *
 * `setRequested(requested())` 不是废话：老文件里 `userRequested` 可能是
 * null，取值回退到当时的 `autoEnabled`。先把它固化下来，再把 autoEnabled
 * 置 false，否则这一步自己就会把意图抹掉。
 */
fun suspendAutoBackupForPairingChange(dir: java.io.File) {
    AutoBackupPrefs(dir).apply {
        setRequested(requested())
        setEnabled(false)
    }
}

/**
 * MOB-93: 快速重连路径上按留下来的意图恢复自动备份。
 * 换一台**新**电脑不走这里——那是新的信任关系，由 onboarding 重新问。
 */
fun restoreAutoBackupAfterRepair(context: Context, backgroundAuthorized: Boolean) {
    val requested = AutoBackupPrefs(context.filesDir).requested()
    when (autoBackupResumeDecision(requested, backgroundAuthorized)) {
        AutoBackupResume.ENABLE -> enableAutoBackup(context)
        AutoBackupResume.SUSPEND -> suspendAutoBackupUntilAuthorized(context)
        AutoBackupResume.LEAVE_OFF -> Unit
    }
}

/**
 * #540：授权回来之后，按留下来的意图把生产者重新排上。
 *
 * [suspendAutoBackupUntilAuthorized] 停生产者、留意图；白名单是**前提**，不是意图。前提在 App 外
 * （系统设置）重新满足时，没有任何用户动作会经过「开关」——旧代码里也就没有人把 `autoEnabled`
 * 置回 true：前台只在白名单为 false 时挂起，进程启动对账见 `!enabled()` 直接返回。结果是意图还在、
 * 界面说「自动进行」、JobScheduler 里 0 个任务。
 */
enum class AuthorizationRestore {
    /** 条件不满足（未配对 / 没有意图 / 生产者本来就开着 / 授权仍缺）——什么都不做。 */
    NONE,

    /** 意图在、授权回来了——走 [enableAutoBackup] 同一条路重新排上。 */
    RESUMED,

    /**
     * 意图在、授权回来了，但 MOB-28 的「监听被清、等用户点恢复」还没确认：只把生产者开关置回，
     * **不重挂**——重挂的唯一入口仍是 [resumeAfterInterruption]。
     */
    RESUMED_AWAITING_CONSENT,
}

/** 测试口：把 [enableAutoBackup] 里碰 WorkManager 的那一半隔出来，JVM 下能把文件 IO 真走一遍。 */
internal fun interface AutoBackupScheduler {
    fun schedule()
}

internal fun restoreAutoBackupIfAuthorized(
    dir: java.io.File,
    paired: Boolean,
    backgroundAuthorized: Boolean,
    awaitingUserConsent: Boolean,
    scheduler: AutoBackupScheduler,
): AuthorizationRestore {
    if (!paired) return AuthorizationRestore.NONE
    val prefs = AutoBackupPrefs(dir)
    if (prefs.enabled()) return AuthorizationRestore.NONE
    if (autoBackupResumeDecision(prefs.requested(), backgroundAuthorized) != AutoBackupResume.ENABLE) {
        return AuthorizationRestore.NONE
    }
    if (awaitingUserConsent) {
        prefs.setEnabled(true)
        return AuthorizationRestore.RESUMED_AWAITING_CONSENT
    }
    markAutoBackupEnabled(dir)
    scheduler.schedule()
    return AuthorizationRestore.RESUMED
}

/**
 * #540：前台（`ON_RESUME`）与进程启动（`reconcileWatchOnProcessStart`）共用的入口。
 * [source] 只进日志——取证时靠它分辨是哪条路径恢复的。
 */
fun restoreAutoBackupAfterAuthorizationReturned(
    context: Context,
    backgroundAuthorized: Boolean,
    source: String,
): AuthorizationRestore {
    val outcome = restoreAutoBackupIfAuthorized(
        dir = context.filesDir,
        paired = com.hawkeyexb.ppass.transport.PairingStore(context.filesDir).load() != null,
        backgroundAuthorized = backgroundAuthorized,
        awaitingUserConsent = BackupHealthPrefs(context.filesDir).load().interruptedUnacknowledged,
    ) { scheduleAutoBackup(context) }
    when (outcome) {
        AuthorizationRestore.RESUMED -> android.util.Log.i(
            "PPassAutoBackup",
            "background backup resumed source=$source: battery optimization exemption is back and the " +
                "user still wants background backup; periodic work and media watch rescheduled",
        )
        AuthorizationRestore.RESUMED_AWAITING_CONSENT -> android.util.Log.i(
            "PPassAutoBackup",
            "background backup re-enabled source=$source: exemption is back, but the watcher was " +
                "stopped earlier and the user has not tapped resume yet; not rescheduling (MOB-28)",
        )
        AuthorizationRestore.NONE -> Unit
    }
    return outcome
}

/** Disables future automatic producers; it never mutates the current Flow round. */
fun disableAutoBackup(context: Context) {
    AutoBackupPrefs(context.filesDir).apply {
        setRequested(false)
        setEnabled(false)
    }
    val workManager = WorkManager.getInstance(context)
    autoBackupWorkNames().forEach(workManager::cancelUniqueWork)
    cancelMediaWatch(context)
}

/** Re-enables normal automatic producers; it never means "continue this round". */
fun enableAutoBackup(context: Context) {
    markAutoBackupEnabled(context.filesDir)
    scheduleAutoBackup(context)
}

/** [enableAutoBackup] 的落盘一半（#540 抽出，供 [restoreAutoBackupIfAuthorized] 复用同一份写法）。 */
internal fun markAutoBackupEnabled(dir: java.io.File) {
    AutoBackupPrefs(dir).apply {
        setRequested(true)
        setEnabled(true)
    }
}

/** Keep the user's choice, but stop automatic producers until authorization returns. */
fun suspendAutoBackupUntilAuthorized(context: Context) {
    markAutoBackupSuspended(context.filesDir)
    val workManager = WorkManager.getInstance(context)
    autoBackupWorkNames().forEach(workManager::cancelUniqueWork)
    cancelMediaWatch(context)
}

/** [suspendAutoBackupUntilAuthorized] 的落盘一半：留意图、停生产者（#540 抽出，测试走同一份写法）。 */
internal fun markAutoBackupSuspended(dir: java.io.File) {
    AutoBackupPrefs(dir).apply {
        setRequested(true)
        setEnabled(false)
    }
}

/**
 * This worker is deliberately only an OS wake adapter: it hands a [TriggerReason] to the loop and waits
 * only for the loop's **checks** (pause, switch, Wi-Fi, battery, budget, desktop reachable). The
 * transfer itself runs in the process-level loop under its own FGS + wakelock (#413), so WorkManager's
 * ~10-minute execution cap never bounds a transfer.
 */
class BackupWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = try {
        val automatic = inputData.getBoolean(KEY_AUTOMATIC_WAKE, true)
        val reason = inputData.getString(KEY_REASON)
            ?.let { name -> TriggerReason.entries.firstOrNull { it.name == name } }
            ?: TriggerReason.MEDIA_CHANGE
        // #130 第 1 层：每次 Worker 唤醒都查一次确定事件——放在后台开关的闸门之前（电池优化被打开后
        // 意图还在、生产者可能已被挂起，这一次唤醒可能就是发现它的唯一机会）。
        evaluateDefinitiveEvents(applicationContext)
        if (!automatic || AutoBackupPrefs(applicationContext.filesDir).enabled()) {
            runFlowWake(applicationContext, reason)
        }
        Result.success()
    } catch (t: Throwable) {
        android.util.Log.w("PPassFlowWake", "Flow wake failed", t)
        Result.retry()
    }
}
