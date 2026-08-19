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
import android.os.SystemClock
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
import androidx.work.WorkInfo
import androidx.work.WorkerParameters
import com.hawkeyexb.ppass.MainActivity
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.battery.isIgnoringBatteryOptimizations
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.PairingStore
import com.hawkeyexb.ppass.transport.PeerAddrParts
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

const val BACKUP_WORK_NAME = "ppass-auto-backup"
// MOB-02: 三个 unique work 通道（互不覆盖，各管一个触发族）。
const val CONTENT_TRIGGER_WORK_NAME = "ppass-content-trigger"
const val CATCHUP_WORK_NAME = "ppass-catchup-backup"
// MOB-08: content trigger 重挂中转通道——见 ContentTriggerRearmWorker。
const val CONTENT_REARM_WORK_NAME = "ppass-content-trigger-rearm"
private const val CHANNEL_ID = "ppass.backup"
private const val NOTIFICATION_ID = 2026
// UX-02: 失败通知（成功保持沉默——产品档案 §二.6）。
private const val FAIL_CHANNEL_ID = "ppass.backup.failed"
private const val FAIL_NOTIFICATION_ID = 2027
// SENT-01: 手机侧哨兵通知（同 UX-02 通道，独立 notification id）。
private const val SENTINEL_NOTIFICATION_ID = 2028
// DOG-02b: 契机式白名单提醒通知（同通道独立 id）。
private const val WHITELIST_NUDGE_NOTIFICATION_ID = 2029

// MOB-02 §四事件②：连拍聚合——update delay（安静窗口）内连续变化只
// 触发一次；超过 max delay 强制跑（变化持续不断时不被饿死）。
//
// MOB-11（2026-08-18 用户定稿）把节奏从「省电优先」改成「尽快送达」：
// 原来 2min/15min 的组合意味着拍完一张要干等两分钟，用户实测两次都是
// 2 分 03 秒——体感上就是"没反应"。
//
// `setTriggerContentUpdateDelay` 是**尾沿防抖**（AOSP: "If there are
// more changes during that time, the delay will be reset to start at the
// time of the most recent change"）：连拍期间计时不断重置，连拍结束后
// 1s 只发**一次**。所以 1s 能聚合任意长度的连拍——防的是事件爆炸
// （20 张跑 20 轮备份），不是推迟触发。有限连拍的实际时间线是
// 「连拍时长 + 1s + 调度」，**永远到不了 max delay**。
//
// max delay 15min → 30s 是另一件事，别把它的理由记成"防连拍"：
// 触发器挂在整个 images/video 集合上，截图、IM 收图、任何 App 写图都会
// 重置计时。真有进程在持续写 MediaStore 时，1s 的静默窗口永远等不到，
// max delay 是从**第一次变化**起算的强制触发闸，防的是这种 churn 把
// 备份饿死。15min 对"尽快送达"来说太长，收到 30s。
const val CONTENT_UPDATE_DELAY_MS = 1L * 1000           // 1s（防连拍抖动）
const val CONTENT_MAX_DELAY_MS = 30L * 1000             // 30s（连拍封顶）
// MOB-02: content trigger 用 REPLACE 去重——同一波变化只跑一次。
val CONTENT_TRIGGER_POLICY: ExistingWorkPolicy = ExistingWorkPolicy.REPLACE

private fun constraintsOf(spec: BackupConstraintsSpec): Constraints =
    Constraints.Builder()
        .setRequiredNetworkType(
            if (spec.requiresUnmetered) NetworkType.UNMETERED else NetworkType.CONNECTED
        )
        // MOB-10: 原来是 setRequiresCharging——在开着电池保护的设备上
        // （充到上限即 NOT_CHARGING）等于「永不备份」。见 TriggerPolicy。
        .setRequiresBatteryNotLow(spec.requiresBatteryNotLow)
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
        // MOB-10: 同 constraintsOf——充电要求换成「电量不低」。
        .setRequiresBatteryNotLow(spec.requiresBatteryNotLow)
        // MOB-08: forDescendants 必须为 true。MediaProvider 在 insert 后
        // notifyChange 发的是带行 id 的 item URI（.../images/media/1000000299），
        // 不是集合 URI——精确匹配（false）永远收不到通知，content trigger
        // 从此不触发。AOSP 官方 MediaContentJob 示例用的正是
        // FLAG_NOTIFY_FOR_DESCENDANTS；真机 dumpsys 里系统自家的 MediaStore
        // 观察者也全是 0x1（descendants），只有我们是 0x0。
        .apply { triggerUris.forEach { addContentUriTrigger(it, true) } }
        .setTriggerContentUpdateDelay(CONTENT_UPDATE_DELAY_MS, TimeUnit.MILLISECONDS)
        .setTriggerContentMaxDelay(CONTENT_MAX_DELAY_MS, TimeUnit.MILLISECONDS)
        .build()
    return OneTimeWorkRequestBuilder<BackupWorker>()
        .setConstraints(constraints)
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
        .build()
}

/** [policy] 默认 REPLACE（约束立即生效）；**App 启动路径必须传 KEEP**，
 *  见 [scheduleAutoBackup]。 */
fun scheduleContentTriggerBackup(
    context: Context,
    policy: ExistingWorkPolicy = CONTENT_TRIGGER_POLICY,
) {
    val settings = BackupSettings(context.filesDir).load()
    WorkManager.getInstance(context).enqueueUniqueWork(
        CONTENT_TRIGGER_WORK_NAME,
        policy,
        buildContentTriggerRequest(settings),
    )
}

// MOB-08: 重挂中转的延迟与等待参数。延迟让本轮 BackupWorker 先落终态；
// 等待轮询是防御——超长批次（首次全量备份）可能还没跑完。
const val REARM_INITIAL_DELAY_SECONDS = 15L
const val REARM_WAIT_TICKS = 30
const val REARM_WAIT_TICK_MS = 2_000L

/** MOB-08: content trigger 是 OneTimeWork——被 MediaStore 变化触发、跑完
 *  一轮之后监听就没了。旧实现只在 App 启动（scheduleAutoBackup）和改设置
 *  （rescheduleAutoBackup）时挂，于是「后台自动同步」实际只在开过 App 的
 *  那一次有效，第二张照片再也不会触发——用户看到的就是「不主动同步」。
 *
 *  为什么要中转一层而不是在 doWork 里直接重挂：CONTENT_TRIGGER_WORK_NAME
 *  是 unique work + REPLACE，在自己的 doWork 里 REPLACE 同名 work 会取消
 *  正在跑的自己，亲手制造 JobCancellationException（正是本卡现象 2 的形状）。
 *  所以交给一个独立 name 的无约束 work：等上一轮落终态后再 REPLACE。 */
class ContentTriggerRearmWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val ctx = applicationContext
        // UX-06: 暂停态下不重挂（否则「暂停自动备份」被 rearm 悄悄复活）。
        if (AutoBackupPrefs(ctx.filesDir).paused()) return@withContext Result.success()
        // 未配对时无事可做（与 doWork 同口径）。
        if (PairingStore(ctx.filesDir).load() == null) return@withContext Result.success()
        val wm = WorkManager.getInstance(ctx)
        repeat(REARM_WAIT_TICKS) {
            // 空列表也算「已终态」——没有活跃 work，直接挂新的。
            if (wm.getWorkInfosForUniqueWork(CONTENT_TRIGGER_WORK_NAME).get()
                    .all { it.state.isFinished }
            ) {
                scheduleContentTriggerBackup(ctx)
                return@withContext Result.success()
            }
            delay(REARM_WAIT_TICK_MS)
        }
        // 上一轮还在跑（超长批次）——它跑完自己也会排一次 rearm，这里放手，
        // 不强行 REPLACE 掉一个正在传照片的 worker。
        Result.success()
    }
}

/** MOB-08: 每轮备份结束后排一次重挂（unique + REPLACE：一轮里多次调用
 *  只留最后一个）。无约束，不占用 charging/unmetered 条件。 */
fun enqueueContentTriggerRearm(context: Context) {
    WorkManager.getInstance(context).enqueueUniqueWork(
        CONTENT_REARM_WORK_NAME,
        ExistingWorkPolicy.REPLACE,
        OneTimeWorkRequestBuilder<ContentTriggerRearmWorker>()
            .setInitialDelay(REARM_INITIAL_DELAY_SECONDS, TimeUnit.SECONDS)
            .build(),
    )
}

/** Schedule the periodic backup + content trigger. Call after pairing and
 *  on every app start — idempotent. Constraints come from [BackupSettings].
 *
 *  MOB-12: 周期任务用 **UPDATE** 而不是 KEEP。KEEP 的语义是"已存在就完全
 *  不动"，包括**不更新约束**——于是任何一次约束变更（改设置、或版本升级
 *  改了默认约束）都进不了已经排好的周期任务，它会一直带着创建当天的约束
 *  运行下去。真机实测到的后果：MOB-10 把 `requiresCharging` 删掉、重装
 *  App 之后，content trigger（走 REPLACE）已经是新约束，周期任务却还是
 *  `charging=true batteryNotLow=false`，继续每 6 小时报一次
 *  `stopReason=CONSTRAINT_CHARGING(6)`。
 *
 *  UPDATE（work-runtime 2.8+）更新约束但**保留下次执行时间**，所以不像
 *  REPLACE 那样重置 6h 计时——这正是这里要的语义。 */
fun scheduleAutoBackup(context: Context) {
    enqueueAutoBackup(context, ExistingPeriodicWorkPolicy.UPDATE)
    // MOB-14: content trigger 在 App 启动路径上必须 KEEP，不能 REPLACE。
    // REPLACE 会把**正在等待触发**的那个 job 取消掉重挂，它已经收到的
    // MediaStore 变化通知随之丢失，CONTENT_TRIGGER 从零开始重新计时。
    // 用户拍完照顺手打开 App 看"传了没"——正好踩中 1s 防抖窗口，那张
    // 照片就再也不会触发，只能等 6h 周期兜底。
    // 约束变更不靠这条路径生效：改设置走 rescheduleAutoBackup（REPLACE），
    // 每轮备份结束走 ContentTriggerRearmWorker（也是 REPLACE，且它只在
    // 上一轮落终态后才动手，那时不存在待处理通知）。
    scheduleContentTriggerBackup(context, ExistingWorkPolicy.KEEP)
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
    // MOB-08: 重挂中转也要取消——否则暂停后还有一个 rearm 在路上把监听
    // 装回去（rearm 内部另有暂停态判断，这里是第二道闸）。
    WorkManager.getInstance(context).cancelUniqueWork(CONTENT_REARM_WORK_NAME)
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
        // MOB-08: 被系统取消时要能区分「几秒内就被打断」（FGS 提升被拒/
        // 约束抖动）和「跑满执行时限」（10min JobScheduler 上限）——两者
        // 的修法完全不同，光看异常类型分不出来。
        val startedAt = SystemClock.elapsedRealtime()
        val pairing = PairingStore(ctx.filesDir).load()
            ?: return Result.success() // not paired yet — nothing to do

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
        // DOG-02b: 契机式白名单提醒——同套路独立 store，不耦合。
        val nudge = WhitelistNudgeStore(ctx.filesDir)
        return try {
            // FGS promotion: the OS lets a dataSync foreground job finish
            // its segment even if the user leaves.
            // MOB-08: 必须在 try 内——WorkManager 自查约束不满足时会在
            // 提升的同一瞬间 stopWork，setForeground 直接抛取消异常；放在
            // try 外面等于这条最常见的失败路径连日志都没有。
            setForeground(foregroundInfo())
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
                nudge.recordSuccess() // DOG-02b: 成功一轮状态清零
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
            nudge.recordSuccess() // DOG-02b: 成功一轮状态清零
            Result.success()
        } catch (t: CancellationException) {
            // MOB-08: 系统 stop（配额耗尽/约束丢失/FGS 被收回/执行超时）
            // 不是业务失败——旧实现把它吞进下面的 Throwable 分支，记成一次
            // 失败尝试 + 走短退避重试，既污染连续失败计数又可能误发失败
            // 通知。正确做法是原样抛出让协程正常终结，重排交给 WorkManager
            // 按 stopReason 决定。
            android.util.Log.w(
                "PPassBackup",
                "auto backup cancelled by system after " +
                    "${SystemClock.elapsedRealtime() - startedAt}ms, " +
                    "stopReason=${stopReasonText()}",
                t,
            )
            throw t
        } catch (t: Throwable) {
            android.util.Log.w("PPassBackup", "auto backup failed, will retry", t)
            // MOB-02 §五：本轮最多短退避重试 2 次（扛网络瞬断），之后
            // 放弃本轮——捞回责任交给下一个触发事件（②③④天然就是重试）。
            // UX-02: 只在放弃本轮时发失败通知（成功保持沉默；扫描前就
            // 失败没有批次数，静默放弃不发「0 张」）；重试中间不打扰。
            // 失败尝试也记给 DOG-02b（近 2 天连续没跑成才提醒）。
            nudge.recordFailure()
            val failures = attempts.recordFailure()
            if (shouldRetryAfter(failures)) {
                Result.retry() // idempotent — next attempt converges
            } else {
                attempts.reset() // 下一触发事件从 0 开始新一轮
                // M10（全页面状态稿）："备份失败时通知我"开关——设置页里
                // 真实生效的偏好，不是摆设（默认开，跟 OS 通知权限是两层）。
                if (batchSize > 0 && NotifyOnFailurePrefs(ctx.filesDir).enabled()) {
                    postFailureNotification(ctx, batchSize)
                }
                Result.failure()
            }
        } finally {
            // MOB-08: client.close() 是 suspend——协程已被取消时直接抛
            // CancellationException，清理根本跑不到（连接泄漏）。
            // NonCancellable 保证取消路径上的收尾照样执行。
            withContext(NonCancellable) {
                client.close()
                // MOB-08: content trigger 跑完就失效了，每轮结束重挂一次
                // （周期/catchup 通道跑完也顺手挂——幂等，KEEP 语义在
                // rearm 内部靠终态判断保证）。
                enqueueContentTriggerRearm(ctx)
                // SENT-01: 搭便车检查——每次后台任务结束（成败都算）看
                // 一次哨兵判定；该发则发（内部去重，发过 markNotified）。
                maybeNotifySentinel(ctx)
                // DOG-02b: 契机式白名单提醒（同 finally 时机，各自判定）。
                maybeNudgeWhitelist(ctx)
            }
        }
    }

    /** MOB-08: stopReason 数值转可读——排障时要一眼看出是配额、约束
     *  丢失还是执行超时。API<31 拿不到真实值（返回 UNKNOWN）。 */
    private fun stopReasonText(): String {
        // getStopReason 是 API 31+ 才有的读数（minSdk 26，低版本直接调用会崩）。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return "N/A(API<31)"
        return stopReasonTextApi31()
    }

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.S)
    private fun stopReasonTextApi31(): String = when (val r = stopReason) {
        WorkInfo.STOP_REASON_NOT_STOPPED -> "NOT_STOPPED($r)"
        WorkInfo.STOP_REASON_UNKNOWN -> "UNKNOWN($r)"
        WorkInfo.STOP_REASON_CANCELLED_BY_APP -> "CANCELLED_BY_APP($r)"
        WorkInfo.STOP_REASON_PREEMPT -> "PREEMPT($r)"
        WorkInfo.STOP_REASON_TIMEOUT -> "TIMEOUT($r)"
        WorkInfo.STOP_REASON_DEVICE_STATE -> "DEVICE_STATE($r)"
        WorkInfo.STOP_REASON_CONSTRAINT_BATTERY_NOT_LOW -> "CONSTRAINT_BATTERY_NOT_LOW($r)"
        WorkInfo.STOP_REASON_CONSTRAINT_CHARGING -> "CONSTRAINT_CHARGING($r)"
        WorkInfo.STOP_REASON_CONSTRAINT_CONNECTIVITY -> "CONSTRAINT_CONNECTIVITY($r)"
        WorkInfo.STOP_REASON_CONSTRAINT_DEVICE_IDLE -> "CONSTRAINT_DEVICE_IDLE($r)"
        WorkInfo.STOP_REASON_CONSTRAINT_STORAGE_NOT_LOW -> "CONSTRAINT_STORAGE_NOT_LOW($r)"
        WorkInfo.STOP_REASON_QUOTA -> "QUOTA($r)"
        WorkInfo.STOP_REASON_BACKGROUND_RESTRICTION -> "BACKGROUND_RESTRICTION($r)"
        WorkInfo.STOP_REASON_APP_STANDBY -> "APP_STANDBY($r)"
        WorkInfo.STOP_REASON_USER -> "USER($r)"
        WorkInfo.STOP_REASON_SYSTEM_PROCESSING -> "SYSTEM_PROCESSING($r)"
        WorkInfo.STOP_REASON_ESTIMATED_APP_LAUNCH_TIME_CHANGED -> "APP_LAUNCH_TIME_CHANGED($r)"
        else -> "OTHER($r)"
    }

    /** DOG-02b: 白名单提醒判定 + 发送（UX-02 通道；去重 ≥72h）。
     *  纯判定在 shouldNudgeWhitelist（JVM 可测），这里只做接线。 */
    private fun maybeNudgeWhitelist(context: Context) {
        val store = WhitelistNudgeStore(context.filesDir)
        if (!shouldNudgeWhitelist(
                store.load(),
                isWhitelisted = isIgnoringBatteryOptimizations(context),
            )
        ) return
        postWhitelistNudgeNotification(context)
        store.markNudged()
    }

    /** DOG-02b: 「昨晚没备份成」通知——点开落白名单引导（DOG-02 现有
     *  回退链在 App 内 Home 引导条，通知进 App 即见）。 */
    private fun postWhitelistNudgeNotification(context: Context) {
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
            context, 2, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, FAIL_CHANNEL_ID)
            .setContentTitle(context.getString(R.string.notif_whitelist_title))
            .setContentText(context.getString(R.string.notif_whitelist_body))
            .setSmallIcon(R.drawable.ic_notification)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build()
        nm.notify(WHITELIST_NUDGE_NOTIFICATION_ID, notification)
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
