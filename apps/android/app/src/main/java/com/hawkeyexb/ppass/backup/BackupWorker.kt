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
import com.hawkeyexb.ppass.backup.flow.runFlowReconcile
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
 * MOB-87：这一次唤醒顺便跑一轮远端对账（去问桌面「我以为传成功的那些，
 * 你还在吗」）。
 *
 * **只有 5 小时的周期兜底那条挂这个标。** 别的唤醒（内容监听、回前台补捞、
 * 手动备份）一拍一个，挂上去等于每拍一张照片就朝桌面发一页 500 个 hash
 * 的查询——对账是收敛手段，不需要那个频率。重新授权那条更即时的触发走
 * `requestFlowWakeAfterRepair`，不走 worker。
 */
private const val KEY_RECONCILE_REMOTE = "reconcile_remote"

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
): OneTimeWorkRequest =
    OneTimeWorkRequestBuilder<BackupWorker>()
        .setConstraints(constraintsOf(spec))
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
        .setInputData(androidx.work.workDataOf(KEY_AUTOMATIC_WAKE to automatic))
        .build()

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
)

fun triggerManualBackup(context: Context) = enqueueFlowWake(
    context, MANUAL_BACKUP_WORK_NAME, BackupTier.MANUAL, ExistingWorkPolicy.KEEP,
)

fun cancelManualBackup(context: Context) {
    WorkManager.getInstance(context).cancelUniqueWork(MANUAL_BACKUP_WORK_NAME)
}

fun triggerProcessStartCatchup(context: Context) = enqueueFlowWake(
    context, PROCESS_CATCHUP_WORK_NAME, BackupTier.BACKGROUND, ExistingWorkPolicy.KEEP,
)

private fun enqueueFlowWake(
    context: Context,
    name: String,
    tier: BackupTier,
    policy: ExistingWorkPolicy,
    automatic: Boolean = true,
) {
    if (automatic && !AutoBackupPrefs(context.filesDir).enabled()) return
    val settings = BackupSettings(context.filesDir).load()
    WorkManager.getInstance(context).enqueueUniqueWork(
        name,
        policy,
        backupWorkRequest(constraintsFor(tier, settings), automatic),
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
                // MOB-87: 兜底那一轮才对账，见 KEY_RECONCILE_REMOTE。
                KEY_RECONCILE_REMOTE to true,
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
 * This worker is deliberately only an OS wake adapter. It may request and drive
 * Flow, but it never scans media, hashes files, or performs transport itself.
 */
class BackupWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = try {
        val automatic = inputData.getBoolean(KEY_AUTOMATIC_WAKE, true)
        if (!automatic || AutoBackupPrefs(applicationContext.filesDir).enabled()) {
            // MOB-76: 「WorkManager 把 job 放行了」≠「Wi-Fi 闸门满足」——
            // MANUAL 档的 worker 约束是零，旧代码在这里把调度放行直接当
            // 交付闸门，等于给所有手动路径开了后门。交付闸门一律实时算。
            runFlowWake(applicationContext)
            // MOB-87: 兜底轮顺带核对一次桌面。放在 wake 之后——先把已知的活
            // 干了，再去问"还有什么是我不知道的"。桌面离线时这一轮自己会
            // 安静退出，不影响上面的 wake 结果。
            if (inputData.getBoolean(KEY_RECONCILE_REMOTE, false)) {
                // **挂起版，不是 fire-and-forget 版。** doWork 是 suspend，
                // 必须等对账跑完再返回：否则 Result.success() 当场落地、
                // wakelock 放掉，那个还在等桌面网络往返的协程随时被掐。
                runFlowReconcile(applicationContext)
            }
        }
        Result.success()
    } catch (t: Throwable) {
        android.util.Log.w("PPassFlowWake", "Flow wake failed", t)
        Result.retry()
    }
}
