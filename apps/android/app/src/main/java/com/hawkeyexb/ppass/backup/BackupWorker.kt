// T-054b: unattended backup — a periodic WorkManager job, constrained
// to charging + unmetered network, promoted to a dataSync foreground
// service while a batch runs (S-04: FGS segmented sessions survive
// Doze). The pipeline itself is the same idempotent BackupRunner the
// button uses; this class only decides WHEN.
package com.hawkeyexb.ppass.backup

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.PairingStore
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import java.util.concurrent.TimeUnit

const val BACKUP_WORK_NAME = "ppass-auto-backup"
private const val CHANNEL_ID = "ppass.backup"
private const val NOTIFICATION_ID = 2026

/** One catch-up run right now (no constraints): app-open and
 *  post-pairing moments — the user is looking, back up what's new. */
fun backupOnceNow(context: Context) {
    val request = androidx.work.OneTimeWorkRequestBuilder<BackupWorker>().build()
    WorkManager.getInstance(context).enqueueUniqueWork(
        "ppass-catchup-backup",
        androidx.work.ExistingWorkPolicy.KEEP,
        request,
    )
}

/** Schedule (or keep) the periodic backup. Call after pairing and on
 *  every app start — idempotent. */
fun scheduleAutoBackup(context: Context) {
    val constraints = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.UNMETERED) // family WiFi
        .setRequiresCharging(true)                     // 充电时才跑
        .build()
    val request = PeriodicWorkRequestBuilder<BackupWorker>(4, TimeUnit.HOURS)
        .setConstraints(constraints)
        .build()
    WorkManager.getInstance(context).enqueueUniquePeriodicWork(
        BACKUP_WORK_NAME,
        ExistingPeriodicWorkPolicy.KEEP,
        request,
    )
}

// UX-06: 全局暂停开关——取消周期任务并落盘暂停态；恢复时重新调度。
// scheduleAutoBackup 在暂停态下不排（重开 App 不自动恢复）。
fun pauseAutoBackup(context: Context) {
    WorkManager.getInstance(context).cancelUniqueWork(BACKUP_WORK_NAME)
    AutoBackupPrefs(context.filesDir).setPaused(true)
}

fun resumeAutoBackup(context: Context) {
    AutoBackupPrefs(context.filesDir).setPaused(false)
    scheduleAutoBackup(context)
}

class BackupWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val ctx = applicationContext
        val pairing = PairingStore(ctx.filesDir).load()
            ?: return Result.success() // not paired yet — nothing to do

        // FGS promotion: the OS lets a dataSync foreground job finish
        // its segment even if the user leaves.
        setForeground(foregroundInfo())

        val watermarks = WatermarkStore(ctx.filesDir)
        val scan = MediaScanner(ctx.contentResolver).scanSince(watermarks.load())
        if (scan.items.isEmpty()) return Result.success()

        val client = DaemonClient()
        return try {
            client.bind(IdentityStore(ctx.filesDir).secretKey())
            val candidates = scan.items.map { item ->
                val open = {
                    ctx.contentResolver.openInputStream(item.uri)
                        ?: error("cannot open ${item.displayName}")
                }
                Candidate(
                    hash = open().use { blake3Hex(it) },
                    fileName = item.displayName,
                    mediaType = item.mimeType,
                    bytes = item.bytes,
                    open = open,
                )
            }
            val report = BackupRunner(client).run(
                parsePeerAddrToken(pairing.daemonAddrToken),
                candidates,
                scan.nextWatermark,
            )
            watermarks.save(scan.nextWatermark)
            android.util.Log.i(
                "PPassBackup",
                "auto backup: offered=${report.offered} pushed=${report.pushed} ingested=${report.ingested}",
            )
            Result.success()
        } catch (t: Throwable) {
            android.util.Log.w("PPassBackup", "auto backup failed, will retry", t)
            Result.retry() // idempotent — next attempt converges
        } finally {
            client.close()
        }
    }

    private fun foregroundInfo(): ForegroundInfo {
        val nm = applicationContext.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "照片备份 Backup",
                    NotificationManager.IMPORTANCE_LOW, // silent
                )
            )
        }
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setContentTitle("P-Pass 正在备份照片")
            .setContentText("Backing up to your home computer…")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .build()
        return if (Build.VERSION.SDK_INT >= 29) {
            ForegroundInfo(
                NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
    }
}
