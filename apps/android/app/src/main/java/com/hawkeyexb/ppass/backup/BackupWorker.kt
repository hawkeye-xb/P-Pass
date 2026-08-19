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
import android.os.Build
import android.os.SystemClock
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
import kotlinx.coroutines.withContext

const val BACKUP_WORK_NAME = "ppass-auto-backup"
// MOB-02/27: unique work 通道（互不覆盖，各管一个触发族）。事件②的
// 监听不在这里——它是 JobScheduler 上的看门 job，见 MediaWatchJob.kt。
const val CATCHUP_WORK_NAME = "ppass-catchup-backup"
// MOB-15: 进程启动补捞通道——见 PPassApp 与 triggerProcessStartCatchup。
const val PROCESS_CATCHUP_WORK_NAME = "ppass-process-catchup"
// MOB-17: 周期兜底间隔。刻意不做高频——见 enqueueAutoBackup 注释。
const val PERIODIC_FALLBACK_HOURS = 5L
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
private fun constraintsOf(spec: BackupConstraintsSpec): Constraints =
    Constraints.Builder()
        .setRequiredNetworkType(
            if (spec.requiresUnmetered) NetworkType.UNMETERED else NetworkType.CONNECTED
        )
        // MOB-10: 原来是 setRequiresCharging——在开着电池保护的设备上
        // （充到上限即 NOT_CHARGING）等于「永不备份」。见 TriggerPolicy。
        .setRequiresBatteryNotLow(spec.requiresBatteryNotLow)
        .build()

internal fun backupWorkRequest(spec: BackupConstraintsSpec): OneTimeWorkRequest =
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

/** MOB-15 事件⑤：进程启动补捞——进程因**任何**原因被拉起时检查一次。
 *
 *  专治「通知丢失后无人补捞」：MediaStore 的变化通知落在「进程被杀 →
 *  job 重排」的窗口里就没人接得住，重排后的 job 只监听**之后**的变化，
 *  那批照片只能干等下一个触发事件（实测等了 4 分钟）。而进程被系统拉起
 *  执行任何 work 时，本就有机会顺手扫一遍——这条就是把那次机会用上。
 *
 *  用**后台档**约束：进程被系统拉起不等于人在操作，不该享受用户在场档的
 *  豁免。独立 unique name（不与 CATCHUP_WORK_NAME 抢）+ KEEP：同一进程
 *  生命周期内重复调用不叠加，扫描无新照片时 doWork 立刻早退。 */
fun triggerProcessStartCatchup(context: Context) {
    val settings = BackupSettings(context.filesDir).load()
    val spec = constraintsFor(BackupTier.BACKGROUND, settings)
    WorkManager.getInstance(context).enqueueUniqueWork(
        PROCESS_CATCHUP_WORK_NAME,
        ExistingWorkPolicy.KEEP,
        backupWorkRequest(spec),
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
    // MOB-27: 事件②的监听是 JobScheduler 上的看门 job，不再是 work。
    // ensureMediaWatch 是 guard-then-schedule（已挂着就不动）——MOB-14 的
    // 老坑原样适用：覆盖一个**正在 pending** 的 trigger job 会丢掉它已经
    // 积累的变更并重置 1s 防抖。用户拍完照顺手打开 App 看"传了没"，正好
    // 踩中防抖窗口，那张照片就再也不会触发。
    //
    // 这条路径同时是**重启后的复活链路**：trigger URI 与 setPersisted 互斥
    // （javadoc 明文），看门 job 每次重启必死；重启后 WorkManager 拉起进程
    // 跑周期任务 → PPassApplication.onCreate → 这里重挂。
    ensureMediaWatch(context)
}

/** UX-03: 设置变更后按新约束重建周期任务——KEEP 不会更新既有任务的
 *  约束，必须 REPLACE（周期计时重置，但这是用户主动改设置的代价）。
 *  MOB-27: 监听**不再随设置重建**——约束已经不挂在监听上了（监听是裸的、
 *  永远在线，Wi-Fi/电量的要求在派出去的备份 work 上，每次派活现读设置）。
 *  这里只做一次幂等的存在性确认。 */
fun rescheduleAutoBackup(context: Context) {
    enqueueAutoBackup(context, ExistingPeriodicWorkPolicy.REPLACE)
    ensureMediaWatch(context)
}

private fun enqueueAutoBackup(context: Context, policy: ExistingPeriodicWorkPolicy) {
    val settings = BackupSettings(context.filesDir).load()
    // MOB-02 §四事件③：周期兜底 4h → ~6h（事件②已接管新照片即时触发，
    // 周期任务退居兜底位——跑不到的照片、错过的触发、后台档条件补跑）。
    // MOB-17（2026-08-19 用户定稿）：6h → 5h。**刻意不做得更频繁**——
    // 用户原话："不用这么频繁地兜底，因为我觉得如果它需要很着急的同步，
    // 它自己会打开。兜底太频繁会在系统的 log 里面被检测得到，反而没那么
    // 好，因为我们有别的触发的事件。"即：主路径（事件②content trigger）
    // 才是常态，兜底只管捞极少数漏网的，不该把自己搞成高频轮询、进 OEM
    // 省电系统的黑名单。
    val request = PeriodicWorkRequestBuilder<BackupWorker>(PERIODIC_FALLBACK_HOURS, TimeUnit.HOURS)
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
// MOB-02/27: 事件②同属自动备份通道，暂停要连**监听**和**它派活的通道**
// 一起停（否则「暂停自动备份」对事件②形同虚设）。
fun pauseAutoBackup(context: Context) {
    WorkManager.getInstance(context).cancelUniqueWork(BACKUP_WORK_NAME)
    // MOB-27: 看门 job 在 JobScheduler 上，不是 work——cancelUniqueWork 管不着。
    cancelMediaWatch(context)
    WorkManager.getInstance(context).cancelUniqueWork(MEDIA_WATCH_BACKUP_WORK_NAME)
    // MOB-15: 进程启动补捞通道同样要停（PPassApp 里另有一道 paused 判断）。
    WorkManager.getInstance(context).cancelUniqueWork(PROCESS_CATCHUP_WORK_NAME)
    AutoBackupPrefs(context.filesDir).setPaused(true)
}

fun resumeAutoBackup(context: Context) {
    AutoBackupPrefs(context.filesDir).setPaused(false)
    scheduleAutoBackup(context)
}

/** MOB-09: 候选构建的结果——能读的候选 + 被跳过的原始条目（坏 MediaStore 行）。
 *  跳过的条目留原始类型，调用方自己决定怎么记日志（这里不碰 android.util.Log，
 *  纯函数才能在 JVM 单测里跑）。
 *
 *  [kept] 是**产出候选的那些原始条目**，与 [candidates] 严格 1:1 同序。
 *  它存在的唯一理由是 MOB-13 的 `fileEntriesOf`：那里靠「文件列表与候选
 *  列表同序等长」把 fileKey 配到 hash 上，长度对不上就整体降级成空 map
 *  （K 又归不了零）。跳过坏记录天然破坏了「候选 == 扫描结果」这个等式，
 *  所以调用方必须喂 [kept] 而不是原始扫描列表——两张卡的不变量都保住。 */
internal data class CandidateBuild<T>(
    val candidates: List<Candidate>,
    val kept: List<T>,
    val skipped: List<T>,
)

/**
 * MOB-09: 逐条隔离的候选构建——一条打不开的 MediaStore 记录不许炸掉整批。
 *
 * 现场（2026-08-18 真机）：MediaStore 里存在「有行、没实体文件」的记录时，
 * 旧实现的 `scan.items.map { … hashWithCache(…) }` 让 `FileNotFoundException`
 * 冒泡到 doWork 的外层 catch，**整批**记失败走重试，重试再撞同一条，
 * watermark 永不推进——一条坏记录永久卡死这台设备的所有后续备份。
 * 成因不止 adb 造数据：文件管理器删文件但 MediaStore 行没同步、云相册
 * 占位文件、外部存储卸载、第三方 App 写坏的行。
 *
 * [build] 抛任何异常 = 这一条读不了 → 跳过并记进 [CandidateBuild.skipped]，
 * 其余条目照常成候选。唯一例外是 [CancellationException]：那是系统 stop
 * （配额/约束/FGS 回收/执行超时，见 MOB-08），不是坏记录，必须原样上抛，
 * 否则会把一次系统取消伪装成「全部跳过」的成功批次。
 */
internal fun <T> buildCandidates(
    items: List<T>,
    build: (T) -> Candidate,
): CandidateBuild<T> {
    val candidates = mutableListOf<Candidate>()
    val kept = mutableListOf<T>()
    val skipped = mutableListOf<T>()
    for (item in items) {
        val candidate = try {
            build(item)
        } catch (t: CancellationException) {
            throw t
        } catch (_: Throwable) {
            skipped.add(item)
            continue
        }
        candidates.add(candidate)
        kept.add(item)
    }
    return CandidateBuild(candidates, kept, skipped)
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
        // MOB-15: 暂停态下任何通道都不跑（进程启动补捞会在 App 冷启时
        // enqueue，这里是第二道闸——UX-06 的「暂停」必须真的停住）。
        if (AutoBackupPrefs(ctx.filesDir).paused()) return Result.success()

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
            // MOB-09: 逐条隔离——打不开的记录跳过，其余照常传（见 buildCandidates）。
            val built = buildCandidates(scan.items) { item ->
                val open = {
                    ctx.contentResolver.openInputStream(item.uri)
                        ?: error("cannot open ${item.displayName}")
                }
                // MOB-09: 先探一次流能不能开。PERF-01 的 hashWithCache 命中
                // 缓存时**不调 open**，于是「上一轮哈希过、之后文件被删」的
                // 记录会带着旧 hash 溜进候选，直到 BackupRunner.pushFile 才抛
                // FileNotFoundException——同样炸掉整批。探针只开关一次流不读
                // 内容，相对读流哈希+上传的代价可以忽略。
                open().use { }
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
            }
            hashCache.flush()
            val candidates = built.candidates
            // MOB-09 决策：坏记录只打日志、不发通知——用户对「相册里有几行
            // 脏数据」无能为力，弹窗只会制造焦虑；日志给排查用（别静默吞）。
            if (built.skipped.isNotEmpty()) {
                android.util.Log.w(
                    "PPassBackup",
                    "auto backup: skipped ${built.skipped.size}/${scan.items.size} " +
                        "unreadable media record(s): " +
                        built.skipped.take(5).joinToString { it.displayName },
                )
            }
            if (candidates.isEmpty()) {
                // MOB-09: 整批都读不了（一批空记录、权限被撤、外部存储卸载）
                // ——不 commit、不推进水位就返回。推进水位等于把这些行永久
                // 跳过；万一是「暂时读不到」（卡没挂载/权限稍后恢复），那批
                // 照片就再也不会被扫到。反过来只要还有一条能读，水位照常推进，
                // 坏行随之被永久跳过——这正是本卡要的：一条脏数据不许挡住其余。
                attempts.reset()
                nudge.recordSuccess()
                return Result.success()
            }
            val report = BackupRunner(client).run(daemon, candidates, scan.nextWatermark)
            watermarks.save(scan.nextWatermark)
            // SENT-01: run 成功 = 确认 daemon 可达（即使校准阶段缓存空
            // 没交互，这里才是硬证据）。
            sentinel.recordReachable()
            // DOG-01c: commit 成功后本次候选全部确认——report.missing 是
            // 上传前集合，不参与减项（回归：旧实现把刚上传成功的照片从
            // 缓存删掉，首次全量备份后 M=0）；漂移校准走独立 exist-check。
            // MOB-13: 顺带记文件级确认（M 与 N 同单位 = 文件数，否则内容
            // 重复的照片让 K 永远归不了零）。**依赖「文件列表与候选列表
            // 1:1 同序」**——见下面 files= 与 fileEntriesOf 的注释。
            confirmedStore.recordRun(
                confirmed = confirmedAfterCommit(candidates, report),
                lastSuccessAt = System.currentTimeMillis(),
                bucketOf = hashToBucket,
                // MOB-09: 喂 built.kept 而不是 scan.items——跳过坏记录后
                // 候选比扫描结果短，喂原始列表会让 fileEntriesOf 长度对不上
                // 整体降级成空 map（MOB-13 的 K 又归不了零）。kept 与
                // candidates 严格 1:1 同序，1:1 前提原样成立。
                files = fileEntriesOf(
                    built.kept.map { it.uri.toString() to it.bucketId },
                    candidates,
                ),
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
                // MOB-27: 监听的重挂**不再是这里的责任**——看门 job 自己
                // 在毫秒级派完活就重挂了（MediaWatchJob），备份跑多久都跟
                // 监听无关。这里留一句幂等的存在性确认，是为了覆盖看门 job
                // 因外力消失的场景（重启：trigger URI 与 setPersisted 互斥，
                // 每次重启必死；OEM 清理；schedule 被系统拒绝）。已挂着就
                // 是 no-op，代价为零；换来"每 5h 至少自检一次监听在不在"。
                //
                // ⚠️ 这里绝不能再做基于时间/批次大小的补捞判断。旧实现
                // （catchUp = batchSize > 0）是在系统之外自己造队列，用户
                // 定调："你强行用时间来做判断的话，是不太合适的。"
                ensureMediaWatch(ctx)
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
