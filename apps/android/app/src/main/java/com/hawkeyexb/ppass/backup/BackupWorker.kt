// T-054b: unattended backup — a periodic WorkManager job, constrained
// to charging + unmetered network, promoted to a dataSync foreground
// service while a batch runs (S-04: FGS segmented sessions survive
// Doze). The pipeline itself is the same idempotent BackupRunner the
// button uses; this class only decides WHEN.
//
// MOB-02（2026-08-11 用户定稿）触发模型重构：备份的发起权从「用户点按钮」
// 改为「事件驱动」——四个触发事件（①选完/改完范围返回 ②新照片落库
// ③周期兜底 ~6h ④App 进前台且距上次成功 >24h），两档条件（用户在场档
// 只查 Wi-Fi / 后台档全查），本轮最多短退避重试 2 次后放弃，捞回交给
// 下一个触发事件。首页「现在备份」主按钮删除（设置页保留低调立即备份
// 作测试/狗粮入口）。
package com.hawkeyexb.ppass.backup

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.core.app.NotificationCompat
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OneTimeWorkRequestBuilder
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
// MOB-02: 三个 unique work 通道（互不覆盖，各管一个触发族）。
const val CONTENT_TRIGGER_WORK_NAME = "ppass-content-trigger"
const val CATCHUP_WORK_NAME = "ppass-catchup-backup"
private const val CHANNEL_ID = "ppass.backup"
private const val NOTIFICATION_ID = 2026
// UX-02: 失败通知（成功保持沉默——产品档案 §二.6）。
private const val FAIL_CHANNEL_ID = "ppass.backup.failed"
private const val FAIL_NOTIFICATION_ID = 2027
// SENT-01: 手机侧哨兵通知（同 UX-02 通道，独立 notification id）。
private const val SENTINEL_NOTIFICATION_ID = 2028

// MOB-02 §四事件②：连拍聚合——update delay（安静窗口）内连续变化只
// 触发一次；超过 max delay 强制跑（变化持续不断时不被饿死）。
const val CONTENT_UPDATE_DELAY_MS = 2L * 60 * 1000      // ~2min
const val CONTENT_MAX_DELAY_MS = 15L * 60 * 1000        // ~15min
// MOB-02: content trigger 用 REPLACE 去重——同一波变化只跑一次。
val CONTENT_TRIGGER_POLICY: ExistingWorkPolicy = ExistingWorkPolicy.REPLACE

private fun constraintsOf(spec: BackupConstraintsSpec): Constraints =
    Constraints.Builder()
        .setRequiredNetworkType(
            if (spec.requiresUnmetered) NetworkType.UNMETERED else NetworkType.CONNECTED
        )
        .setRequiresCharging(spec.requiresCharging)
        .build()

private fun backupWorkRequest(spec: BackupConstraintsSpec): OneTimeWorkRequest =
    OneTimeWorkRequestBuilder<BackupWorker>()
        .setConstraints(constraintsOf(spec))
        // MOB-02 §五：短退避重试（扛网络瞬断；次数上限在 doWork 内裁决）。
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
        .build()

/** MOB-02 事件①④（用户在场档）：现在跑一次（无充电要求，只查 Wi-Fi）。
 *  unique work KEEP——已有排队/运行中的同族任务不重复入队（幂等收敛）。 */
fun triggerUserPresentBackup(context: Context) {
    val settings = BackupSettings(context.filesDir).load()
    val spec = constraintsFor(BackupTier.USER_PRESENT, settings)
    WorkManager.getInstance(context).enqueueUniqueWork(
        CATCHUP_WORK_NAME,
        ExistingWorkPolicy.KEEP,
        backupWorkRequest(spec),
    )
}

/** MOB-02 事件②（后台档）：新照片落库 → content trigger。
 *  ContentUriTrigger 监听 MediaStore 变化，update delay 安静窗口内连拍
 *  聚合成一次，max delay 兜底；unique work REPLACE 去重。零常驻监听、
 *  零轮询（WorkManager 系统级调度）。
 *  ⚠️ work-runtime 2.10 的 content trigger API 在 Constraints.Builder
 *  （addContentUriTrigger / setTriggerContentUpdateDelay / MaxDelay），
 *  不在 WorkRequest.Builder 上。
 *  [triggerUris] 可注入（测试用——mockable android.jar 下 MediaStore
 *  静态字段为 null，JVM 单测无法构造 Uri；生产恒用默认 MediaStore 两
 *  集合）。 */
fun buildContentTriggerRequest(
    settings: BackupSettingsState,
    triggerUris: List<Uri> = listOf(
        MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
        MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
    ),
): OneTimeWorkRequest {
    val spec = constraintsFor(BackupTier.BACKGROUND, settings)
    val constraints = Constraints.Builder()
        .setRequiredNetworkType(
            if (spec.requiresUnmetered) NetworkType.UNMETERED else NetworkType.CONNECTED
        )
        .setRequiresCharging(spec.requiresCharging)
        .apply { triggerUris.forEach { addContentUriTrigger(it, false) } }
        .setTriggerContentUpdateDelay(CONTENT_UPDATE_DELAY_MS, TimeUnit.MILLISECONDS)
        .setTriggerContentMaxDelay(CONTENT_MAX_DELAY_MS, TimeUnit.MILLISECONDS)
        .build()
    return OneTimeWorkRequestBuilder<BackupWorker>()
        .setConstraints(constraints)
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
        .build()
}

fun scheduleContentTriggerBackup(context: Context) {
    val settings = BackupSettings(context.filesDir).load()
    WorkManager.getInstance(context).enqueueUniqueWork(
        CONTENT_TRIGGER_WORK_NAME,
        CONTENT_TRIGGER_POLICY,
        buildContentTriggerRequest(settings),
    )
}

/** Schedule (or keep) the periodic backup + content trigger. Call after
 *  pairing and on every app start — idempotent (KEEP: existing work keeps
 *  its timing). Constraints come from [BackupSettings] (UX-03). */
fun scheduleAutoBackup(context: Context) {
    enqueueAutoBackup(context, ExistingPeriodicWorkPolicy.KEEP)
    scheduleContentTriggerBackup(context)
}

/** UX-03: 设置变更后按新约束重建周期任务——KEEP 不会更新既有任务的
 *  约束，必须 REPLACE（周期计时重置，但这是用户主动改设置的代价）。
 *  MOB-02: content trigger 同步重建（约束随设置走）。 */
fun rescheduleAutoBackup(context: Context) {
    enqueueAutoBackup(context, ExistingPeriodicWorkPolicy.REPLACE)
    scheduleContentTriggerBackup(context)
}

private fun enqueueAutoBackup(context: Context, policy: ExistingPeriodicWorkPolicy) {
    val settings = BackupSettings(context.filesDir).load()
    // MOB-02 §四事件③：周期兜底 4h → ~6h（事件②已接管新照片即时触发，
    // 周期任务退居兜底位——跑不到的照片、错过的触发、后台档条件补跑）。
    val request = PeriodicWorkRequestBuilder<BackupWorker>(6, TimeUnit.HOURS)
        .setConstraints(constraintsOf(constraintsFor(BackupTier.BACKGROUND, settings)))
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
        .build()
    WorkManager.getInstance(context).enqueueUniquePeriodicWork(
        BACKUP_WORK_NAME,
        policy,
        request,
    )
}

// UX-06: 全局暂停开关——取消周期任务并落盘暂停态；恢复时重新调度。
// scheduleAutoBackup 在暂停态下不排（重开 App 不自动恢复）。
// MOB-02: content trigger 同属自动备份通道，暂停一并取消（否则
// 「暂停自动备份」对事件②形同虚设）。
fun pauseAutoBackup(context: Context) {
    WorkManager.getInstance(context).cancelUniqueWork(BACKUP_WORK_NAME)
    WorkManager.getInstance(context).cancelUniqueWork(CONTENT_TRIGGER_WORK_NAME)
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
        // MOB-02 §五：连续失败计数——成功或放弃本轮时清零，下一个触发
        // 事件（②③④）天然就是新一轮重试。
        val attempts = BackupAttemptStore(ctx.filesDir)
        // SENT-01: 手机盯电脑哨兵——搭便车，每次后台任务执行顺记一笔
        // daemon 可达性结果（非心跳）。判定与通知在 finally 统一检查。
        val sentinel = SentinelStore(ctx.filesDir)
        return try {
            client.bind(IdentityStore(ctx.filesDir).secretKey())
            val daemon = parsePeerAddrToken(pairing.daemonAddrToken)

            // DOG-01c: 备份前漂移校准（只查不传；daemon 不可达则跳过）。
            // SENT-01: 校准返回是否确认可达——false（含无交互/失败）也
            // 是一次失败尝试（否则连续 3 天「scan 空早退」会漏记）。
            val reachable = calibrateIfReachable(client, daemon, confirmedStore)
            if (reachable) sentinel.recordReachable() else sentinel.recordUnreachable()

            val watermarks = WatermarkStore(ctx.filesDir)
            // T6: 自动备份同样只扫选中相册（范围与手动一致）。
            val scan = MediaScanner(ctx.contentResolver)
                .scanSince(watermarks.load(), BackupScopeStore(ctx).selectedBucketIds())
            if (scan.items.isEmpty()) {
                attempts.reset() // 无新照片也算成功一轮——连续失败清零
                return Result.success()
            }
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
            // SENT-01: run 成功 = 确认 daemon 可达（即使校准阶段缓存空
            // 没交互，这里才是硬证据）。
            sentinel.recordReachable()
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
            attempts.reset() // 成功——连续失败清零
            Result.success()
        } catch (t: Throwable) {
            android.util.Log.w("PPassBackup", "auto backup failed, will retry", t)
            // MOB-02 §五：本轮最多短退避重试 2 次（扛网络瞬断），之后
            // 放弃本轮——捞回责任交给下一个触发事件（②③④天然就是重试）。
            // UX-02: 只在放弃本轮时发失败通知（成功保持沉默；扫描前就
            // 失败没有批次数，静默放弃不发「0 张」）；重试中间不打扰。
            val failures = attempts.recordFailure()
            if (shouldRetryAfter(failures)) {
                Result.retry() // idempotent — next attempt converges
            } else {
                attempts.reset() // 下一触发事件从 0 开始新一轮
                if (batchSize > 0) postFailureNotification(ctx, batchSize)
                Result.failure()
            }
        } finally {
            client.close()
            // SENT-01: 搭便车检查——每次后台任务结束（成败都算）看
            // 一次哨兵判定；该发则发（内部去重，发过 markNotified）。
            maybeNotifySentinel(ctx)
        }
    }

    /** SENT-01: 哨兵通知判定 + 发送（UX-02 通道；发过 72h 内不重复）。
     *  纯判定在 shouldNotifySentinel（JVM 可测），这里只做接线。 */
    private fun maybeNotifySentinel(context: Context) {
        val store = SentinelStore(context.filesDir)
        if (!shouldNotifySentinel(store.load())) return
        postSentinelNotification(context)
        store.markNotified()
    }

    /** SENT-01: 「3 天没连上电脑了」通知——文案先说照片没丢。 */
    private fun postSentinelNotification(context: Context) {
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
            context, 1, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, FAIL_CHANNEL_ID)
            .setContentTitle(context.getString(R.string.notif_sentinel_title))
            .setContentText(context.getString(R.string.notif_sentinel_body))
            .setSmallIcon(R.drawable.ic_notification)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build()
        nm.notify(SENTINEL_NOTIFICATION_ID, notification)
    }

    /** DOG-01c: 漂移校准——对缓存 hash 集做只查不传的 exist-check，
     *  daemon 已无的（电脑端库被删/换库）从缓存移除。daemon 不可达
     *  则静默跳过（三元组显示缓存值，下次再校准）。
     *  SENT-01: 返回是否确认可达（成功交互=true；不可达/无缓存可查
     *  =false——调用方据此记哨兵可达性）。 */
    private suspend fun calibrateIfReachable(
        client: DaemonClient,
        daemon: PeerAddrParts,
        store: ConfirmedStore,
    ): Boolean {
        return try {
            // PERF-01: 校准时刻顺手清 hash-cache 孤儿（跟随 MediaStore
            // 现存 _ID 集合；查询失败内部跳过，不影响校准）。
            pruneHashCache(applicationContext)
            val cached = store.load().confirmed
            if (cached.isEmpty()) return false // 无缓存可查——无结论
            val missing = BackupRunner(client).existCheck(daemon, cached)
            if (missing.isNotEmpty()) store.removeMissing(missing)
            true // 交互成功 = 确认可达
        } catch (_: Throwable) {
            // 不可达/未配对/超时——保留缓存值。
            false
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
            .setSmallIcon(R.drawable.ic_notification)
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
            .setSmallIcon(R.drawable.ic_notification)
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
