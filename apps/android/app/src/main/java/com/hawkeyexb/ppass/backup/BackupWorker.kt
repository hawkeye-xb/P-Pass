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
import androidx.work.workDataOf
import com.hawkeyexb.ppass.MainActivity
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.battery.isIgnoringBatteryOptimizations
import com.hawkeyexb.ppass.i18n.DiagText
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PairingStore
import com.hawkeyexb.ppass.transport.PeerAddrParts
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

const val BACKUP_WORK_NAME = "ppass-auto-backup"
// MOB-02/27: unique work 通道（互不覆盖，各管一个触发族）。事件②的
// 监听不在这里——它是 JobScheduler 上的看门 job，见 MediaWatchJob.kt。
const val CATCHUP_WORK_NAME = "ppass-catchup-backup"
// MOB-15: 进程启动补捞通道——见 PPassApp 与 triggerProcessStartCatchup。
const val PROCESS_CATCHUP_WORK_NAME = "ppass-process-catchup"
// MOB-19 事件⑥：用户手点「立即备份」——见 triggerManualBackup。
const val MANUAL_BACKUP_WORK_NAME = "ppass-manual-backup"
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
// MOB-29: 「资源在客户端丢失，正在重传」提示（同通道独立 id）。
// **固定 id 是刻意的**：手动通道与周期通道是两条独立 unique work，可以
// 并发跑（各自校准），两轮都可能在对方 removeMissing 之前看到同一批
// missing。固定 id 让这种双发在系统层面折叠成同一条通知。
private const val REUPLOAD_NOTIFICATION_ID = 2030
// MOB-29: 收尾补校准的硬超时——挂死的 exist-check 绝不许拖长一个
// 已经结束（或已被系统取消）的 worker。
private const val CALIBRATE_TAIL_TIMEOUT_MS = 15_000L

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
// ── MOB-19（2026-08-20 用户定稿）：备份只有一条管线 ──
//
// 用户原话："不是说应该自动和手动触发的备份一样吗？一个就是机器自动去触发，
// 一个是我们主动去触发。触发的种类不一样……手动就相当于第 5 种触发方式。
// 你为什么这里弄了两条路径去做备份呢？"
//
// 在此之前手动备份是 BackupUiStateHolder 里**另一份**扫描+哈希实现，于是
// MOB-09 的「一条坏记录不许炸整批」只修了自动那一份，手动那份照旧永久卡死。
// 现在手动只是又一种触发方式：同一个 BackupWorker，只在 input data 上带两个
// 手动专属语义。

/** 手动触发专属：忽略水位、重扫选中相册的全部。
 *  「选相册」与「发起备份」是两个动作——用户主动点按钮时期望的是"把这些
 *  相册整个过一遍"，不是"接着上次的进度"。自动触发恒为增量。 */
const val KEY_FULL_RESCAN = "ppass.backup.full_rescan"

// 进度上报字段。手动备份的界面靠它跟住这条 work；自动备份顺带也有了实时
// 进度（在此之前后台跑完只刷三元组，状态行全程不动）。
const val KEY_PHASE = "ppass.backup.phase"
const val KEY_DONE = "ppass.backup.done"
const val KEY_TOTAL = "ppass.backup.total"

/**
 * MOB-31: 这次运行**结束的时刻**（`System.currentTimeMillis()`）。
 *
 * 存在的理由：备份有五条通道（auto / catchup / process-catchup / manual /
 * media-watch），各自独立 unique name，**终态记录会同时躺在 WorkManager 里
 * 最多五条**，而它们共用同一个 tag。`getWorkInfosByTagFlow` **不保证按时间
 * 排序**（Room 查询顺序，实际按 UUID），所以「拿列表最后一个」等于随机挑
 * 一条——用户 2026-08-21 真机撞到的正是这个：刚同步完 12 张，界面报
 * 「186 张」，那是 8/20 那次全量运行留下的旧记录。
 *
 * 有了这个时间戳，[uiStateOf] 才能挑出**真正最近**的那一条。
 */
const val KEY_FINISHED_AT = "ppass.backup.finishedAt"
const val KEY_FILE = "ppass.backup.file"
const val PHASE_SCANNING = "scanning"
const val PHASE_HASHING = "hashing"
const val PHASE_SENDING = "sending"
// 终态输出（成功/失败都要能让 UI 说人话）。
const val KEY_INGESTED = "ppass.backup.ingested"
const val KEY_DUPLICATES = "ppass.backup.duplicates"
const val KEY_NO_ALBUMS = "ppass.backup.no_albums"

/** MOB-33: 这一轮是**空转**——抢不到 [backupInFlight] 的门，活正在被别人干。
 *
 *  它是一个终态返回（所以按 MOB-31 的不变量要盖 [KEY_FINISHED_AT]），但**不是
 *  一个结果**：output 里没有 ingested/duplicates。所以 `uiStateOf` 必须把带这个
 *  标记的记录排除掉，否则——
 *
 *  用户点暂停 → 那条 work 变 CANCELLED（WorkManager 取消时**拿不到 outputData**
 *  → 无戳 → 被当成上古记录）→ 而空转那条有戳且更"新" → 界面选中它 → 显示
 *  「已备份 0 张」而不是 Idle。盖戳与「别被选中」这两件事必须分开表达。 */
const val KEY_SKIPPED = "ppass.backup.skipped"
const val KEY_ERROR = "ppass.backup.error"

/**
 * MOB-19: 进度上报节流。
 *
 * `setProgress` 每次是一条 IPC + 一次数据库写。千张库的哈希循环里逐张上报
 * 会把 WorkManager 写爆。但**第一次和最后一次必须发**——MOB-11 的教训是
 * "进度条像卡死然后突然全传完"（用户真机原话），节流不许把首尾吃掉。
 */
internal class ProgressThrottle(private val minIntervalMs: Long = 250L) {
    private var lastAt = 0L

    fun should(done: Int, total: Int, nowMs: Long): Boolean {
        if (done <= 1 || done >= total) { lastAt = nowMs; return true }
        if (nowMs - lastAt >= minIntervalMs) { lastAt = nowMs; return true }
        return false
    }
}

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

/** MOB-19 事件⑥：用户手点「立即备份」（设置页低调入口）。
 *
 *  **零约束**（[BackupTier.MANUAL]）——人已经在场、亲手点的，这是当场的
 *  明确指令，压过「仅 Wi-Fi 时备份」那条给自动备份定的规则。点了不动是
 *  反直觉的。用户定稿（2026-08-20）："手动能不能在检测-发起之间，直接
 *  人工点击-发起？"
 *
 *  **全量重扫**（[KEY_FULL_RESCAN]）——忽略水位，把选中相册整个过一遍。
 *
 *  KEEP 而不是 REPLACE：跑着的时候再点不打断正在传的那批（界面上进度条
 *  正在动，用户看得见）。要停走 [cancelManualBackup]。 */
fun triggerManualBackup(context: Context) {
    val settings = BackupSettings(context.filesDir).load()
    val spec = constraintsFor(BackupTier.MANUAL, settings)
    WorkManager.getInstance(context).enqueueUniqueWork(
        MANUAL_BACKUP_WORK_NAME,
        ExistingWorkPolicy.KEEP,
        OneTimeWorkRequestBuilder<BackupWorker>()
            .setConstraints(constraintsOf(spec))
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .setInputData(workDataOf(KEY_FULL_RESCAN to true))
            .build(),
    )
}

/** UX-01: 备份进行中再点 = 暂停。中断不 commit、水位不推进，已到家的
 *  blob 下次去重跳过；再点一次 = 续传（重新 offer 全部候选，收敛缺 0）。 */
fun cancelManualBackup(context: Context) {
    WorkManager.getInstance(context).cancelUniqueWork(MANUAL_BACKUP_WORK_NAME)
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
    // MOB-27 升级清理：老版本挂在 WorkManager 上的 content trigger 必须先
    // 干掉，否则升级窗口内新旧两个监听会被同一波变化同时唤醒，跑两轮并行
    // 备份（真机 dumpsys 实锤，见 cancelLegacyContentTriggerWork）。
    cancelLegacyContentTriggerWork(context)
    ensureMediaWatch(context)
}

/** UX-03: 设置变更后按新约束重建周期任务——KEEP 不会更新既有任务的
 *  约束，必须 REPLACE（周期计时重置，但这是用户主动改设置的代价）。
 *  MOB-27: 监听**不再随设置重建**——约束已经不挂在监听上了（监听是裸的、
 *  永远在线，Wi-Fi/电量的要求在派出去的备份 work 上，每次派活现读设置）。
 *  这里只做一次幂等的存在性确认。 */
fun rescheduleAutoBackup(context: Context) {
    enqueueAutoBackup(context, ExistingPeriodicWorkPolicy.REPLACE)
    if (mayRearmWatchIncidentally(context)) ensureMediaWatch(context)
}

/**
 * MOB-33: **一次只跑一轮备份。**
 *
 * 备份有五条触发通道（周期兜底 / content trigger / 用户在场 catchup /
 * 进程启动补捞 / 手动），每条一个独立的 unique name。`ExistingWorkPolicy.KEEP`
 * 只在**同一个 name 内部**去重，跨通道不管——于是「打开 App」撞上「周期任务
 * 到点」会让两个 [BackupWorker] 同时跑。
 *
 * 后果不只是「浪费」（这是原卡的错误定性）：
 * - 两条同时 RUNNING → `uiStateOf` 的 `firstOrNull { RUNNING }` 随机挑一条
 *   → 进度条在两轮之间来回跳（验收人：「正在读文件后有长时间 pending，
 *   然后又展示读文件，再上传」）
 * - 暂停按钮只能取消一条 → 另一条继续传
 *
 * 用同一进程内的 CAS 门：抢不到就早退 `Result.success()`（**不是 retry**
 * ——重排一轮没意义，那一轮的活正在被别人干）。WorkManager 的 worker 都在
 * 同一进程，所以进程级标志就够；进程被杀标志随之消失，不会留下卡死的锁。
 *
 * ⚠️ 早退必须是 success：返回 retry 会让 WorkManager 按退避重排，制造一串
 * 无意义的重试；返回 failure 会让界面报错。
 */
private val backupInFlight = AtomicBoolean(false)

/** MOB-35 + MOB-28：**「顺带」的监听重挂**在中断待确认时一律不许发生。
 *
 *  MOB-35 放行了「用户在前台时的补捞」，于是那趟 work 会跑到 `doWork` 的
 *  `finally`，而那里有一句幂等的 `ensureMediaWatch`——后果是：用户
 *  force-stop、提示还挂着、一次「恢复」都没点，**后台监听自己回来了**，
 *  MOB-28 的红线当场破。同款第二处是 [rescheduleAutoBackup]（改备份设置
 *  那条路径）。
 *
 *  这个门**只管顺带的重挂**。用户点「恢复备份」走的是
 *  `resumeAfterInterruption` → [scheduleAutoBackup]，不经过这里——它是
 *  MOB-28 定的唯一入口，必须无条件生效。
 *
 *  ⚠️ 发现经过：MOB-35 第一版只拆了 `MainActivity` 那个 `return` 就报绿，
 *  漏了这两处。单元测试也没抓到——它们断言的是那个 `LaunchedEffect` 块，
 *  而破线发生在下游 work 的 `finally` 里。**闸门必须立在每一条能重挂的
 *  路径上，缺一处就等于没有**（MOB-28 卡面原话，这次轮到我踩）。 */
internal fun mayRearmWatchIncidentally(context: Context): Boolean =
    !BackupHealthPrefs(context.filesDir).load().interruptedUnacknowledged

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
        // MOB-33: 抢门——同一时刻只允许一轮备份（见 [backupInFlight]）。
        if (!backupInFlight.compareAndSet(false, true)) {
            android.util.Log.i("PPassBackup", "another backup is in flight; skipping this run")
            // 走 successStamped 而不是裸 Result.success：MOB-31 的不变量是
            // 「每个终态都盖戳」（OneBackupPipelineTest 钉着）。同时打
            // KEY_SKIPPED，让 uiStateOf 把这条空转记录排除——见常量注释。
            return successStamped(KEY_SKIPPED to true)
        }
        try {
            return runBackup(ctx)
        } finally {
            backupInFlight.set(false)
        }
    }

    private suspend fun runBackup(ctx: android.content.Context): Result {
        // MOB-08: 被系统取消时要能区分「几秒内就被打断」（FGS 提升被拒/
        // 约束抖动）和「跑满执行时限」（10min JobScheduler 上限）——两者
        // 的修法完全不同，光看异常类型分不出来。
        val startedAt = SystemClock.elapsedRealtime()
        // MOB-19: 手动触发（事件⑥）带的两个专属语义之一——见 KEY_FULL_RESCAN。
        val fullRescan = inputData.getBoolean(KEY_FULL_RESCAN, false)
        val pairing = PairingStore(ctx.filesDir).load()
            ?: return successStamped() // not paired yet — nothing to do
        // MOB-15: 暂停态下任何通道都不跑（进程启动补捞会在 App 冷启时
        // enqueue，这里是第二道闸——UX-06 的「暂停」必须真的停住）。
        if (AutoBackupPrefs(ctx.filesDir).paused()) return successStamped()

        // DOG-01c: 自动备份也走同一确认缓存（M 口径一致，不能只靠手动备份）。
        val stateDir = File(ctx.filesDir, "backup-state/${pairing.daemonNodeId}")
        val confirmedStore = ConfirmedStore(stateDir)
        // MOB-34: 定向补偿队列——校准查出「确认过、库里却没了」的 hash 时，
        // 把它们对应的本地 MediaStore 条目登记在这里（水位之下的老照片
        // 永远不会被增量扫描重新扫到，不登记就永远传不回去）。同目录 =
        // 断开配对时随 clearConfirmedCacheForRemote 一起清掉。
        val reuploads = ReuploadQueue(stateDir)
        // MOB-37: 重传告知的落盘（同目录，随配对一起清）。通知只是提醒，
        // 载体是这条状态——发失败/没被看见时 App 内那条提示还在。
        val reuploadNotice = ReuploadNoticePrefs(stateDir)

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
        // MOB-29: 这一趟有没有真的校准过。false = 主路径压根没走到校准
        // （setForeground 被拒、bind 失败、地址解析炸），收尾补一次。
        var calibrated = false
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
            val reachable =
                calibrateIfReachable(client, daemon, confirmedStore, reuploads, reuploadNotice)
            calibrated = true
            if (reachable) sentinel.recordReachable() else sentinel.recordUnreachable()

            val watermarks = WatermarkStore(ctx.filesDir)
            val bucketIds = BackupScopeStore(ctx).selectedBucketIds()
            // FIX-T6: 空集 = 一个都不备（用户把相册全取消了）。必须显式
            // 反馈——静默 success 会让界面说「照片都存好了」，那是假话。
            if (bucketIds != null && bucketIds.isEmpty()) {
                attempts.reset()
                return successStamped(KEY_NO_ALBUMS to true)
            }
            // MOB-19 事件⑥：手动触发忽略水位、重扫选中相册全部（「选相册」
            // 与「发起备份」是两个动作）。自动触发恒为增量。
            val since = if (fullRescan) 0L else watermarks.load()
            // T6: 自动备份同样只扫选中相册（范围与手动一致）。
            val scanner = MediaScanner(ctx.contentResolver)
            val scan = scanner.scanSince(since, bucketIds)
            // MOB-34: 定向补偿——把队列里登记的老照片（水位之下，增量扫描
            // 永远扫不到）按 fileKey **定向**查回来，与本轮增量结果合并成
            // 一条列表往下走。查询只带队列里那几个 _ID，代价与队列长度成
            // 正比、与相册规模无关——卡面第 3 条：不许退化成每轮全量重扫。
            //
            // 队列为空（绝大多数轮次）时一次查询都不发（itemsByKeys 空集
            // 早退），这条路径对常态零成本。
            val pending = reuploads.load()
            val found = if (pending.isEmpty()) emptyList() else scanner.itemsByKeys(pending)
            val plan = planReuploads(
                pending = pending,
                found = found,
                scanned = scan.items,
                keyOf = { it.uri.toString() },
                // 范围外的不补（用户缩过备份范围，那些照片已不是我们的事）。
                inScope = { bucketIds == null || it.bucketId == null || it.bucketId in bucketIds },
            )
            // 查无此行 / 范围外 → 立刻丢，绝不每轮重试（MOB-09 的老坑）。
            reuploads.remove(plan.drop)
            // PERF-01 的哈希缓存。MOB-36 的补齐判定要靠它把成本压成零，所以
            // 提前到扫描阶段就构造（构造只是读一次盘，没有别的副作用）。
            val hashCache = HashCache(hashCacheFile(ctx))
            // MOB-36: 范围补齐——相册之间**移动**照片不改 _ID / date_added /
            // date_modified，只改 bucket_id，于是「移进已选相册的老照片」的
            // 水位值远在水位之下，增量扫描永远看不见它（真机现象：触发了、
            // 什么也没传）。这里把「已选相册里、水位之下」的行捞回来，靠
            // files / 哈希缓存两张现成的表筛掉已经备过的那些——**已确认的
            // 一律不开流不哈希**，稳态下这一步返回空集、零成本（卡面第 3 条
            // 与验收④）。范围为 null（全量模式）时一次查询都不发。
            val confirmedState = confirmedStore.load()
            val backfill = planScopeBackfill(
                below = scanner.scanScopeBelow(since, bucketIds),
                already = plan.items,
                keyOf = { it.uri.toString() },
                knownHashOf = { item ->
                    knownHashOfFile(
                        confirmedState,
                        hashCache,
                        item.uri.toString(),
                        hashCacheKey(
                            item.uri.toString(), item.generation, item.dateModified,
                            item.bytes, Build.VERSION.SDK_INT >= 30,
                        ),
                    )
                },
                isConfirmed = { it in confirmedState.confirmed },
            )
            if (backfill.isNotEmpty()) {
                android.util.Log.i(
                    "PPassBackup",
                    "scope backfill: ${backfill.size} in-scope item(s) below the watermark " +
                        "were never confirmed (moved into an album / newly selected album)",
                )
            }
            val items = plan.items + backfill
            reportProgress(PHASE_SCANNING, items.size, items.size)
            if (items.isEmpty()) {
                attempts.reset() // 无新照片也算成功一轮——连续失败清零
                nudge.recordSuccess() // DOG-02b: 成功一轮状态清零
                return successStamped(KEY_INGESTED to 0, KEY_DUPLICATES to 0)
            }
            batchSize = items.size

            // PERF-01: 自动备份同样走哈希缓存——增量扫描 mostly 命中，
            // hash 阶段不再全量读流（千张库从分钟级降到秒级）。缓存实例在
            // 上面（扫描阶段）就构造好了，MOB-36 的补齐判定要用它。
            // FIX-T6: 记录每个候选 hash 的所属相册（自动备份同口径）。
            val hashToBucket = mutableMapOf<String, Long>()
            // MOB-09: 逐条隔离——打不开的记录跳过，其余照常传（见 buildCandidates）。
            // MOB-19: 哈希阶段逐条上报（节流），手动备份的界面靠它显示
            // 「正在读取 x/y」。自动备份顺带也有了实时进度。
            val hashProgress = ProgressThrottle()
            var hashed = 0
            val built = buildCandidates(items) { item ->
                hashed += 1
                if (hashProgress.should(hashed, items.size, SystemClock.elapsedRealtime())) {
                    reportProgress(PHASE_HASHING, hashed, items.size)
                }
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
                    "auto backup: skipped ${built.skipped.size}/${items.size} " +
                        "unreadable media record(s): " +
                        built.skipped.take(5).joinToString { it.displayName },
                )
            }
            // MOB-34: 读不了的补偿条目**立刻**丢出队列（在下面那个早退之前
            // ——早退路径同样必须丢，否则一条打不开的老记录每轮都被查回来、
            // 每轮都读失败，正是 MOB-09 要防的「一条坏记录卡死整批」）。
            if (built.skipped.isNotEmpty() && pending.isNotEmpty()) {
                reuploads.remove(built.skipped.mapTo(mutableSetOf()) { it.uri.toString() })
            }
            if (candidates.isEmpty()) {
                // MOB-09: 整批都读不了（一批空记录、权限被撤、外部存储卸载）
                // ——不 commit、不推进水位就返回。推进水位等于把这些行永久
                // 跳过；万一是「暂时读不到」（卡没挂载/权限稍后恢复），那批
                // 照片就再也不会被扫到。反过来只要还有一条能读，水位照常推进，
                // 坏行随之被永久跳过——这正是本卡要的：一条脏数据不许挡住其余。
                attempts.reset()
                nudge.recordSuccess()
                return successStamped()
            }
            val sendProgress = ProgressThrottle()
            val report = BackupRunner(client).run(
                daemon, candidates, scan.nextWatermark,
            ) { sent, total, fileName ->
                if (sendProgress.should(sent, total, SystemClock.elapsedRealtime())) {
                    reportProgress(PHASE_SENDING, sent, total, fileName)
                }
            }
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
            // MOB-34: 传成功的补偿条目出队（confirmed/files 已经写回，K 归零）。
            // 放在 recordRun **之后**：run 抛错就走不到这里，队列原样保留、
            // 下一轮再试——网络瞬断不许把该补的照片悄悄丢掉。
            if (pending.isNotEmpty()) {
                reuploads.remove(built.kept.mapTo(mutableSetOf()) { it.uri.toString() })
            }
            android.util.Log.i(
                "PPassBackup",
                "auto backup: offered=${report.offered} pushed=${report.pushed} ingested=${report.ingested}",
            )
            attempts.reset() // 成功——连续失败清零
            nudge.recordSuccess() // DOG-02b: 成功一轮状态清零
            // MOB-19: 终态带上数字——界面要说「新增 N 张」，不能只说"好了"。
            successStamped(
                KEY_INGESTED to report.ingested,
                KEY_DUPLICATES to report.duplicates,
            )
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
                // T-083 红线：主文案永不带代码——这串只去两个地方，默认收起
                // 的「查看技术详情」折叠区，和上面那句 Log.w。
                Result.failure(
                    workDataOf(
                        KEY_ERROR to t.toString().take(500),
                        KEY_FINISHED_AT to System.currentTimeMillis(),
                    )
                )
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
                //
                // MOB-35：门控见 [mayRearmWatchIncidentally]。MOB-35 放行前台
                // 补捞之后，这句「顺带的存在性确认」会在中断待确认时把监听
                // 悄悄装回去——用户一次「恢复」都没点，MOB-28 红线就破了。
                if (mayRearmWatchIncidentally(ctx)) ensureMediaWatch(ctx)
                // MOB-29: 校准搭这一趟后台任务的便车——**无论这趟怎么结束**
                // （早退、异常、被系统取消、setForeground 直接被拒）都补一次。
                //
                // 为什么需要：校准原来长在备份管线的开头，于是它继承了管线的
                // 全部前置闸门——FGS 提升被拒（MOB-08 记录的最常见失败路径）、
                // bind 失败、地址解析异常，任一条都会让这一趟一次校准都没跑，
                // 而「已备份」那个大数字是用户判断照片安不安全的唯一依据。
                // 补校准在这里，脱离了「备份开始」这个条件。
                //
                // 刻意**不**新开一趟周期任务：MOB-17 定调过兜底不该更频繁
                // （"兜底太频繁会在系统的 log 里面被检测得到"）。搭便车不加
                // 一次唤醒。
                if (!calibrated) {
                    calibrateTail(
                        ctx, pairing, confirmedStore, reuploads, reuploadNotice, sentinel,
                    )
                }
                // SENT-01: 搭便车检查——每次后台任务结束（成败都算）看
                // 一次哨兵判定；该发则发（内部去重，发过 markNotified）。
                maybeNotifySentinel(ctx)
                // DOG-02b: 契机式白名单提醒（同 finally 时机，各自判定）。
                maybeNudgeWhitelist(ctx)
            }
        }
    }

    /** MOB-19: 进度上报。
     *
     *  用 `setProgressAsync` 而不是 suspend 的 `setProgress`：调用点在
     *  `buildCandidates` 的 build lambda 和 `BackupRunner` 的进度回调里，
     *  两者都不是 suspend 上下文（编译器直接顶回来）。不 await 返回的
     *  future——上报是给界面看的，慢一拍无所谓，不该拖住备份。
     *
     *  抛异常（work 已终结/被取消）一律吞掉：**上报不是业务逻辑**，
     *  绝不能因为界面刷新失败而让一批照片传不成。 */
    private fun reportProgress(
        phase: String,
        done: Int,
        total: Int,
        file: String = "",
    ) {
        runCatching {
            setProgressAsync(
                workDataOf(
                    KEY_PHASE to phase,
                    KEY_DONE to done,
                    KEY_TOTAL to total,
                    KEY_FILE to file,
                )
            )
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
    /** MOB-31: 所有成功终态都必须经过这里——[KEY_FINISHED_AT] 少盖一处，
     *  [uiStateOf] 就会把那次运行当成"上古记录"永远选不中它。 */
    private fun successStamped(vararg extras: Pair<String, Any?>): Result =
        Result.success(
            workDataOf(*extras, KEY_FINISHED_AT to System.currentTimeMillis())
        )

    private suspend fun calibrateIfReachable(
        client: DaemonClient,
        daemon: PeerAddrParts,
        store: ConfirmedStore,
        reuploads: ReuploadQueue,
        notice: ReuploadNoticePrefs,
    ): Boolean {
        // PERF-01: 校准时刻顺手清 hash-cache 孤儿（跟随 MediaStore
        // 现存 _ID 集合；查询失败内部跳过，不影响校准）。
        runCatching { pruneHashCache(applicationContext) }
        // MOB-29: 判定与「谁丢了」的算法都在 calibrateConfirmed（纯，JVM
        // 单测直接跑）；这里只做接线：exist-check 走真连接，onLost 发通知。
        return calibrateConfirmed(
            store = store,
            existCheck = { BackupRunner(client).existCheck(daemon, it) },
            onLost = { lost ->
                // MOB-34: 「会被传回来」在此之前只是**通知里的一句话**——
                // 老照片在水位之下，增量扫描永远扫不到它，于是永远传不回去。
                // 这里把这批 hash 对应的本地条目登记进定向补偿队列，下一轮
                // （多数情况就是同一轮，登记发生在扫描之前）真的把它们传回。
                // 必须读 store.load() 的**校准前**快照：calibrateConfirmed
                // 的契约是先 onLost 再 removeMissing，之后文件级记录就没了。
                // MOB-34 第二路：哈希缓存（uri → hash）跨版本存活，专治
                // 「覆盖安装保留老格式 confirmed.json」的存量条目——那些
                // 没有文件级记录，但缓存里有。少这一路，自动更新上来的用户
                // 补偿永远够不着存量照片。
                val queued = enqueueReuploads(
                    store.load(), reuploads, lost, HashCache(hashCacheFile(applicationContext)),
                )
                android.util.Log.i(
                    "PPassBackup",
                    "calibrate: ${lost.size} confirmed asset(s) vanished from the library, " +
                        "they will be re-uploaded (queued ${queued.size} local file(s))",
                )
                // MOB-37: **先落盘、再发通知**，而且通知的异常吞掉。
                // 系统通知只是「提醒你去看」，告知的载体是盘上那条状态
                // （权限没授/渠道被关/锁屏没看见时它照样在 App 里等着）。
                // 顺序与吞异常的两条理由见 noteReuploadNotice 的 kdoc。
                noteReuploadNotice(notice, lost, System.currentTimeMillis()) {
                    postReuploadNotification(applicationContext)
                }
            },
        )
    }

    /** MOB-29: 收尾补校准（见 finally 里的调用点注释）。
     *
     *  主路径那个 client 在 finally 里已经关掉了，这里开一个自己的；
     *  整段带硬超时 + 全异常吞掉——**补校准绝不许让一趟任务的收尾挂住**。 */
    private suspend fun calibrateTail(
        context: Context,
        pairing: Pairing,
        store: ConfirmedStore,
        reuploads: ReuploadQueue,
        notice: ReuploadNoticePrefs,
        sentinel: SentinelStore,
    ) {
        // 缓存空 = 没什么可校准的，连接都不必开。
        if (store.load().confirmed.isEmpty()) return
        val client = DaemonClient()
        try {
            val reachable = withTimeout(CALIBRATE_TAIL_TIMEOUT_MS) {
                client.bind(IdentityStore(context.filesDir).secretKey())
                calibrateIfReachable(
                    client,
                    parsePeerAddrToken(pairing.daemonAddrToken),
                    store,
                    reuploads,
                    notice,
                )
            }
            // SENT-01 同口径：这一趟主路径没记过可达性（压根没走到），
            // 这次探测就是这趟唯一的一次尝试。
            if (reachable) sentinel.recordReachable() else sentinel.recordUnreachable()
        } catch (t: Throwable) {
            android.util.Log.w("PPassBackup", "tail calibrate skipped", t)
            sentinel.recordUnreachable()
        } finally {
            runCatching { client.close() }
        }
    }

    /** MOB-29: 「资源在客户端丢失，正在重传」——用户定稿文案（两句，
     *  第二句教顺序：想真删就先删手机上的原图）。走 UX-02 那条通道，
     *  文案取 i18n 字典（assets/i18n，en/zh 对称测试兜底）。
     *
     *  **不带张数**：定调是「不做精确归因」，一句在人删/换库两种成因下
     *  都成立的话就够了；数字只会引出「哪几张」这个我们不回答的问题。 */
    private fun postReuploadNotification(context: Context) {
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
            context, 3, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        // 字典缺键（理论上不可能——Rust 侧注册表测试兜底）也不许崩，
        // 退回 key 本身只会难看，不会丢掉这次告知。
        val title = DiagText.resolve(context, MSG_REUPLOAD_TITLE) ?: MSG_REUPLOAD_TITLE
        val body = DiagText.resolve(context, MSG_REUPLOAD_BODY) ?: MSG_REUPLOAD_BODY
        val notification = NotificationCompat.Builder(context, FAIL_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setSmallIcon(R.drawable.ic_notification)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build()
        nm.notify(REUPLOAD_NOTIFICATION_ID, notification)
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
