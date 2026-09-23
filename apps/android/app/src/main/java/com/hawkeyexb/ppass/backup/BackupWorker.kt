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
 * #417：这次唤醒的 [TriggerReason]。决定要不要跑慢路径（5h 兜底 = PERIODIC 跑，含问桌面「还在吗」；
 * 内容监听一拍一个，不跑）、要不要查后台开关与电量（人在场的不查）。
 */
private const val KEY_REASON = "trigger_reason"

const val UNREACHABLE_PROBE_WORK_PREFIX = "ppass-unreachable-probe-"
const val CONSTRAINT_WAKE_WORK_NAME = "ppass-constraint-wake"
const val UNREACHABLE_PROBE_COUNT = 3
const val UNREACHABLE_PROBE_INTERVAL_MINUTES = 10L

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
): OneTimeWorkRequest =
    OneTimeWorkRequestBuilder<BackupWorker>()
        .setConstraints(constraintsOf(spec))
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
        .setInitialDelay(initialDelayMinutes, TimeUnit.MINUTES)
        .setInputData(androidx.work.workDataOf(KEY_AUTOMATIC_WAKE to automatic, KEY_REASON to reason.name))
        .build()

/**
 * #417 的唤醒登记：
 * - 桌面不可达：3 个一次性任务，间隔 10 分钟（10 / 20 / 30 分钟后各探测一次）。已经排着的不重排（KEEP），
 *   所以反复失败不会把探测一直往后推。
 * - 条件不满足：一个带相应约束的一次性任务（Wi‑Fi → UNMETERED，电量 → batteryNotLow）。
 */
class WorkManagerWakeScheduler(private val context: Context) : WakeScheduler {
    override fun scheduleUnreachableProbes() {
        val wm = WorkManager.getInstance(context)
        val settings = BackupSettings(context.filesDir).load()
        for (i in 1..UNREACHABLE_PROBE_COUNT) {
            wm.enqueueUniqueWork(
                "$UNREACHABLE_PROBE_WORK_PREFIX$i",
                ExistingWorkPolicy.KEEP,
                backupWorkRequest(
                    constraintsFor(BackupTier.USER_PRESENT, settings),
                    automatic = false,
                    reason = TriggerReason.UNREACHABLE_PROBE,
                    initialDelayMinutes = UNREACHABLE_PROBE_INTERVAL_MINUTES * i,
                ),
            )
        }
    }

    override fun cancelUnreachableProbes() {
        val wm = WorkManager.getInstance(context)
        for (i in 1..UNREACHABLE_PROBE_COUNT) wm.cancelUniqueWork("$UNREACHABLE_PROBE_WORK_PREFIX$i")
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
                // 5h 兜底：这一轮跑慢路径（手机完整性检查 + 问桌面「还在吗」+ FAILED 重试一次）。
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
    AutoBackupPrefs(context.filesDir).apply {
        setRequested(true)
        setEnabled(true)
    }
    scheduleAutoBackup(context)
}

/** Keep the user's choice, but stop automatic producers until authorization returns. */
fun suspendAutoBackupUntilAuthorized(context: Context) {
    AutoBackupPrefs(context.filesDir).apply {
        setRequested(true)
        setEnabled(false)
    }
    val workManager = WorkManager.getInstance(context)
    autoBackupWorkNames().forEach(workManager::cancelUniqueWork)
    cancelMediaWatch(context)
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
        if (!automatic || AutoBackupPrefs(applicationContext.filesDir).enabled()) {
            runFlowWake(applicationContext, reason)
        }
        Result.success()
    } catch (t: Throwable) {
        android.util.Log.w("PPassFlowWake", "Flow wake failed", t)
        Result.retry()
    }
}
