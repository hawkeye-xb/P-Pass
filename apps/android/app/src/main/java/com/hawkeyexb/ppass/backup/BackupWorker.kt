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
import com.hawkeyexb.ppass.backup.flow.continueFlow
import com.hawkeyexb.ppass.backup.flow.pauseFlow
import com.hawkeyexb.ppass.backup.flow.runFlowWake
import java.util.concurrent.TimeUnit

const val BACKUP_WORK_NAME = "ppass-auto-backup"
const val CATCHUP_WORK_NAME = "ppass-catchup-backup"
const val PROCESS_CATCHUP_WORK_NAME = "ppass-process-catchup"
const val MANUAL_BACKUP_WORK_NAME = "ppass-manual-backup"
const val PERIODIC_FALLBACK_HOURS = 5L
const val CONTENT_UPDATE_DELAY_MS = 1_000L
const val CONTENT_MAX_DELAY_MS = 30_000L

private fun constraintsOf(spec: BackupConstraintsSpec): Constraints =
    Constraints.Builder()
        .setRequiredNetworkType(if (spec.requiresUnmetered) NetworkType.UNMETERED else NetworkType.CONNECTED)
        .setRequiresBatteryNotLow(spec.requiresBatteryNotLow)
        .build()

internal fun backupWorkRequest(spec: BackupConstraintsSpec): OneTimeWorkRequest =
    OneTimeWorkRequestBuilder<BackupWorker>()
        .setConstraints(constraintsOf(spec))
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
        .build()

fun triggerUserPresentBackup(context: Context) = enqueueFlowWake(
    context, CATCHUP_WORK_NAME, BackupTier.USER_PRESENT, ExistingWorkPolicy.KEEP,
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
) {
    val settings = BackupSettings(context.filesDir).load()
    WorkManager.getInstance(context).enqueueUniqueWork(
        name,
        policy,
        backupWorkRequest(constraintsFor(tier, settings)),
    )
}

fun scheduleAutoBackup(context: Context) {
    val settings = BackupSettings(context.filesDir).load()
    val request = PeriodicWorkRequestBuilder<BackupWorker>(PERIODIC_FALLBACK_HOURS, TimeUnit.HOURS)
        .setConstraints(constraintsOf(constraintsFor(BackupTier.BACKGROUND, settings)))
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
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

/** Global pause persists in the Flow ledger; WorkManager is only prevented from waking it. */
fun pauseAutoBackup(context: Context) {
    pauseFlow(context)
    AutoBackupPrefs(context.filesDir).setPaused(true)
    WorkManager.getInstance(context).cancelUniqueWork(BACKUP_WORK_NAME)
    WorkManager.getInstance(context).cancelUniqueWork(CATCHUP_WORK_NAME)
    WorkManager.getInstance(context).cancelUniqueWork(PROCESS_CATCHUP_WORK_NAME)
    WorkManager.getInstance(context).cancelUniqueWork(MANUAL_BACKUP_WORK_NAME)
    WorkManager.getInstance(context).cancelUniqueWork(MEDIA_WATCH_BACKUP_WORK_NAME)
    cancelMediaWatch(context)
}

fun resumeAutoBackup(context: Context) {
    AutoBackupPrefs(context.filesDir).setPaused(false)
    continueFlow(context)
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
        if (!AutoBackupPrefs(applicationContext.filesDir).paused()) {
            runFlowWake(applicationContext, constraintsSatisfied = true)
        }
        Result.success()
    } catch (t: Throwable) {
        android.util.Log.w("PPassFlowWake", "Flow wake failed", t)
        Result.retry()
    }
}
