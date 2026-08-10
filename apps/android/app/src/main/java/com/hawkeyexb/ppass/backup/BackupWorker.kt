// T-054b: unattended backup — a periodic WorkManager job, constrained
// to charging + unmetered network, promoted to a dataSync foreground
// service while a batch runs (S-04: FGS segmented sessions survive
// Doze). The pipeline itself is the same idempotent BackupRunner the
// button uses; this class only decides WHEN.
package com.hawkeyexb.ppass.backup

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
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
import com.hawkeyexb.ppass.MainActivity
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.PairingStore
import com.hawkeyexb.ppass.transport.PeerAddrParts
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import java.io.File
import java.util.concurrent.TimeUnit

const val BACKUP_WORK_NAME = "ppass-auto-backup"
private const val CHANNEL_ID = "ppass.backup"
private const val NOTIFICATION_ID = 2026
// UX-02: 失败通知（成功保持沉默——产品档案 §二.6）。
private const val FAIL_CHANNEL_ID = "ppass.backup.failed"
private const val FAIL_NOTIFICATION_ID = 2027

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
 *  every app start — idempotent (KEEP: existing work keeps its timing).
 *  Constraints come from [BackupSettings] (UX-03). */
fun scheduleAutoBackup(context: Context) {
    enqueueAutoBackup(context, ExistingPeriodicWorkPolicy.KEEP)
}

/** UX-03: 设置变更后按新约束重建周期任务——KEEP 不会更新既有任务的
 *  约束，必须 REPLACE（周期计时重置，但这是用户主动改设置的代价）。 */
fun rescheduleAutoBackup(context: Context) {
    enqueueAutoBackup(context, ExistingPeriodicWorkPolicy.REPLACE)
}

private fun enqueueAutoBackup(context: Context, policy: ExistingPeriodicWorkPolicy) {
    val settings = BackupSettings(context.filesDir).load()
    val constraints = Constraints.Builder()
        .setRequiredNetworkType(
            if (settings.wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED
        )
        .setRequiresCharging(settings.chargeOnly)
        .build()
    val request = PeriodicWorkRequestBuilder<BackupWorker>(4, TimeUnit.HOURS)
        .setConstraints(constraints)
        .build()
    WorkManager.getInstance(context).enqueueUniquePeriodicWork(
        BACKUP_WORK_NAME,
        policy,
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

        // DOG-01c: 自动备份也走同一确认缓存（M 口径一致，不能只靠手动备份）。
        val confirmedStore = ConfirmedStore(
            File(ctx.filesDir, "backup-state/${pairing.daemonNodeId}")
        )

        val client = DaemonClient()
        // UX-02: 失败通知的批次数——scan 在 try 内（DOG-01c 时序），catch
        // 里读不到局部 val，用这个变量带出去（0 = 还没扫到就失败）。
        var batchSize = 0
        return try {
            client.bind(IdentityStore(ctx.filesDir).secretKey())
            val daemon = parsePeerAddrToken(pairing.daemonAddrToken)

            // DOG-01c: 备份前漂移校准（只查不传；daemon 不可达则跳过）。
            calibrateIfReachable(client, daemon, confirmedStore)

            val watermarks = WatermarkStore(ctx.filesDir)
            // T6: 自动备份同样只扫选中相册（范围与手动一致）。
            val scan = MediaScanner(ctx.contentResolver)
                .scanSince(watermarks.load(), BackupScopeStore(ctx).selectedBucketIds())
            if (scan.items.isEmpty()) return Result.success()
            batchSize = scan.items.size

            // PERF-01: 自动备份同样走哈希缓存——增量扫描 mostly 命中，
            // hash 阶段不再全量读流（千张库从分钟级降到秒级）。
            val hashCache = HashCache(hashCacheFile(ctx))
            // FIX-T6: 记录每个候选 hash 的所属相册（自动备份同口径）。
            val hashToBucket = mutableMapOf<String, Long>()
            val candidates = scan.items.map { item ->
                val open = {
                    ctx.contentResolver.openInputStream(item.uri)
                        ?: error("cannot open ${item.displayName}")
                }
                val key = hashCacheKey(
                    item.uri.toString(), item.generation, item.dateModified,
                    item.bytes, Build.VERSION.SDK_INT >= 30,
                )
                val hash = hashWithCache(hashCache, key, open)
                item.bucketId?.let { hashToBucket[hash] = it }
                Candidate(
                    hash = hash,
                    fileName = item.displayName,
                    mediaType = item.mimeType,
                    bytes = item.bytes,
                    open = open,
                )
            }.also { hashCache.flush() }
            val report = BackupRunner(client).run(daemon, candidates, scan.nextWatermark)
            watermarks.save(scan.nextWatermark)
            // DOG-01c: commit 成功后本次候选全部确认——report.missing 是
            // 上传前集合，不参与减项（回归：旧实现把刚上传成功的照片从
            // 缓存删掉，首次全量备份后 M=0）；漂移校准走独立 exist-check。
            confirmedStore.recordRun(
                confirmed = confirmedAfterCommit(candidates, report),
                lastSuccessAt = System.currentTimeMillis(),
                bucketOf = hashToBucket,
            )
            android.util.Log.i(
                "PPassBackup",
                "auto backup: offered=${report.offered} pushed=${report.pushed} ingested=${report.ingested}",
            )
            Result.success()
        } catch (t: Throwable) {
            android.util.Log.w("PPassBackup", "auto backup failed, will retry", t)
            // UX-02: 批次失败才发系统通知（成功保持沉默）。批次 = 本次
            // scan 的候选数；点开落回主界面（失败清单区为后续卡）。
            // 扫描前就失败（bind/解析）没有批次数，静默重试不发"0 张"。
            if (batchSize > 0) postFailureNotification(ctx, batchSize)
            Result.retry() // idempotent — next attempt converges
        } finally {
            client.close()
        }
    }

    /** DOG-01c: 漂移校准——对缓存 hash 集做只查不传的 exist-check，
     *  daemon 已无的（电脑端库被删/换库）从缓存移除。daemon 不可达
     *  则静默跳过（三元组显示缓存值，下次再校准）。 */
    private suspend fun calibrateIfReachable(
        client: DaemonClient,
        daemon: PeerAddrParts,
        store: ConfirmedStore,
    ) {
        try {
            // PERF-01: 校准时刻顺手清 hash-cache 孤儿（跟随 MediaStore
            // 现存 _ID 集合；查询失败内部跳过，不影响校准）。
            pruneHashCache(applicationContext)
            val cached = store.load().confirmed
            if (cached.isEmpty()) return
            val missing = BackupRunner(client).existCheck(daemon, cached)
            if (missing.isNotEmpty()) store.removeMissing(missing)
        } catch (_: Throwable) {
            // 不可达/未配对/超时——保留缓存值。
        }
    }

    /** UX-02: 失败通知——「N 张照片没备份成功，打开看看」，点开进 App。 */
    private fun postFailureNotification(context: Context, failedCount: Int) {
        val nm = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(
                    FAIL_CHANNEL_ID, "照片备份失败 Backup failed",
                    NotificationManager.IMPORTANCE_DEFAULT,
                )
            )
        }
        val open = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            context, 0, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, FAIL_CHANNEL_ID)
            .setContentTitle(context.getString(R.string.notif_backup_failed_title))
            .setContentText(context.getString(R.string.notif_backup_failed_body, failedCount))
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build()
        nm.notify(FAIL_NOTIFICATION_ID, notification)
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
