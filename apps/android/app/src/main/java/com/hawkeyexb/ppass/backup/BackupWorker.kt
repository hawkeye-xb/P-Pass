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

fun triggerUserPresentBackup(context: Context) = enqueueFlowWake(
    context, CATCHUP_WORK_NAME, BackupTier.USER_PRESENT, ExistingWorkPolicy.KEEP,
)

fun triggerManualBackup(context: Context) = enqueueFlowWake(
    context, MANUAL_BACKUP_WORK_NAME, BackupTier.MANUAL, ExistingWorkPolicy.KEEP, automatic = false,
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
        .setInputData(androidx.work.workDataOf(KEY_AUTOMATIC_WAKE to true))
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

/** Disables future automatic producers; it never mutates the current Flow round. */
fun disableAutoBackup(context: Context) {
    AutoBackupPrefs(context.filesDir).setEnabled(false)
    val workManager = WorkManager.getInstance(context)
    autoBackupWorkNames().forEach(workManager::cancelUniqueWork)
    cancelMediaWatch(context)
}

/** Re-enables normal automatic producers; it never means "continue this round". */
fun enableAutoBackup(context: Context) {
    AutoBackupPrefs(context.filesDir).setEnabled(true)
    scheduleAutoBackup(context)
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
        }
        Result.success()
    } catch (t: Throwable) {
        android.util.Log.w("PPassFlowWake", "Flow wake failed", t)
        Result.retry()
    }
}
