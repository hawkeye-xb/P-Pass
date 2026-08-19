// MOB-27（2026-08-19 用户定稿）：监听与干活彻底分家。
//
// ## 旧模型的洞
//
// content trigger 以前直接绑在 BackupWorker 上：MediaStore 一变，
// **同一个 job** 既是"监听"又是"干活"。于是 job 一开始跑，监听就被消耗掉，
// 直到备份跑完 + rearm 重挂之前，**没有任何监听在接 MediaStore 通知**。
// 备份跑 2 分钟，监听就断 2 分钟。用户真机实测的原话（2026-08-19）：
// "前面的出去了，后面的就没有同步"。
//
// 我们在外面用 ContentTriggerRearmWorker + catchUp 补捞造了个假队列去补，
// 补丁依赖时间常数（等 1s、轮询 30×500ms），用户当场否掉："你强行用时间
// 来做判断的话，是不太合适的。"
//
// ## 系统本来就提供了正确答案
//
// `JobInfo.Builder#addTriggerContentUri` 的 javadoc（AOSP，本机
// android-36 sources 逐字核对）写得很直白：
//
// > To continually monitor for content changes, you need to schedule a new
// > JobInfo **using the same job ID** and observing the same URIs
// > **in place of calling jobFinished()**. […] Following this pattern will
// > ensure you do not lose any content changes: **while your job is running,
// > the system will continue monitoring for content changes, and propagate
// > any changes it sees over to the next job you schedule.**
//
// 这就是 event loop：**系统是事件队列，我们取一个、干一个、放回去。**
// 处理完不是 jobFinished()，而是 schedule(同一个 job ID)——那一下就是
// "释放"，系统立刻把运行期间攒下的变更投递给新 job。空窗为零。
//
// 我们吃不到这个语义的唯一原因是中间隔着 WorkManager：`REPLACE` 每次
// 新建 WorkSpec，底下 job ID 跟着换，而系统的"转交"是**按 job ID 认人**的。
// 所以 content trigger 这一条通道绕过 WorkManager，直接 JobScheduler。
//
// ## 改完之后
//
// 看门 Job 醒来只做两件事——派活、重挂——毫秒级返回。备份在 WorkManager
// 那边异步跑，跑多久都跟监听无关：**看门的永远在岗，干活的爱跑多久跑多久。**
//
// 顺带堵掉的第二个洞：旧的 content trigger 带着 UNMETERED + batteryNotLow
// 约束，意味着**不在 Wi-Fi 时监听压根不会被投递**——出门拍一天照，那一天
// 的通知全丢，只能等 5h 周期兜底。现在监听是裸的（永远在线），Wi-Fi 和
// 电量的要求挪到派出去的备份 work 上：有新照片立刻知道，能不能传是另一回事。
package com.hawkeyexb.ppass.backup

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import androidx.work.ExistingWorkPolicy
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.hawkeyexb.ppass.transport.PairingStore
import kotlin.concurrent.thread

/** 看门 Job 的 job ID。**必须是稳定常量**——整个方案的支点就在这里：
 *  系统的"运行期间变更转交给下一个 job"是按 job ID 认人的，ID 一变就
 *  接不上。改这个数字等于把队列清空一次（旧 job 变孤儿，需 cancel 旧 ID）。 */
const val MEDIA_WATCH_JOB_ID = 20260819

/** 看门 Job 派活的目标通道。与其它备份通道（周期/补捞/手动）分开，
 *  这条通道有自己的排队语义（见 [dispatchWatchBackup]）。 */
const val MEDIA_WATCH_BACKUP_WORK_NAME = "ppass-media-watch-backup"

private const val TAG = "PPassWatch"

/**
 * 看门 Job 的 JobInfo。
 *
 * **刻意不设任何约束**（网络/电量/充电一概没有）：约束挂在监听上就等于
 * "不满足条件时连通知都收不到"，那是旧实现最隐蔽的一个洞。约束属于
 * 派出去的备份 work（见 [dispatchWatchBackup]）。
 *
 * `FLAG_NOTIFY_FOR_DESCENDANTS` 必须带（MOB-08 根因，全项目最贵的教训）：
 * MediaProvider 在 insert 后 notifyChange 发的是**带行 id 的 item URI**
 * （.../images/media/1000000299），不是集合 URI。精确匹配（flag=0）永远
 * 收不到通知，content trigger 从此一次都不触发。真机 dumpsys 里系统自家
 * 的 MediaStore 观察者也全是 0x1。
 *
 * [triggerUris] 可注入——生产恒用 MediaStore 两集合，测试用来绕开
 * mockable android.jar 下静态字段为 null 的限制。
 */
fun buildMediaWatchJobInfo(
    context: Context,
    triggerUris: List<Uri> = listOf(
        MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
        MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
    ),
): JobInfo {
    val builder = JobInfo.Builder(
        MEDIA_WATCH_JOB_ID,
        ComponentName(context, MediaWatchJob::class.java),
    )
    triggerUris.forEach {
        builder.addTriggerContentUri(
            JobInfo.TriggerContentUri(it, JobInfo.TriggerContentUri.FLAG_NOTIFY_FOR_DESCENDANTS)
        )
    }
    // MOB-11 的两个节奏参数原样搬过来（语义与旧的 Constraints 版一致）：
    // update delay 是**尾沿防抖**——连拍期间计时不断重置，停手 1s 才响
    // 一次，所以 100ms 连拍 5 秒（50 张）只触发 1 次，不是 50 次。
    // max delay 是从**第一次**变化起算的强制闸——防止持续 churn
    // （截图/IM 收图/其它 App 批量写）让 1s 静默窗口永远等不到。
    return builder
        .setTriggerContentUpdateDelay(CONTENT_UPDATE_DELAY_MS)
        .setTriggerContentMaxDelay(CONTENT_MAX_DELAY_MS)
        .build()
}

private fun jobScheduler(context: Context): JobScheduler =
    context.getSystemService(JobScheduler::class.java)

/** 监听已挂着吗？（重启后必为 false——见 [ensureMediaWatch]） */
fun isMediaWatchScheduled(context: Context): Boolean =
    runCatching { jobScheduler(context).getPendingJob(MEDIA_WATCH_JOB_ID) != null }
        .getOrDefault(false)

/**
 * 幂等地确保监听挂着。**任何路径都必须走这里，不许裸 schedule()。**
 *
 * 为什么要 guard 而不是无脑 schedule：覆盖一个**正在 pending** 的 trigger
 * job 会把它已经积累的变更一起丢掉，并重置 1s 防抖计时（MOB-14 的老坑：
 * 用户拍完照顺手打开 App 看"传了没"，正好踩中防抖窗口，那张照片再也不会
 * 触发）。javadoc 承诺的"变更转交"只覆盖 job **running** 期间，不覆盖
 * pending 期。
 *
 * 谁来调用（每一条都是必要的，缺一条就有场景失联）：
 * - `scheduleAutoBackup`（App 启动 / 进程被系统拉起）
 * - `BackupWorker` 每轮结束的 finally（每 5h 至少自检一次）
 * - [MediaWatchJob] 自己跑完（正常的"释放"路径）
 *
 * ⚠️ **重启后监听必然消失**：javadoc 明确 trigger URI 与 `setPersisted`
 * 互斥，看门 job 天生不可持久化。复活链路是"重启 → WorkManager 的
 * BOOT_COMPLETED 拉起进程跑 5h 周期任务 → PPassApplication.onCreate →
 * 这里重挂"。所以重启后监听空窗上限 = 周期任务首跑。数据不丢（照片还在
 * 水位之上，周期任务连扫带重挂），亏的只是时延。要压到 0 得自己加一个
 * BOOT_COMPLETED receiver——决策点写在 MOB-27 卡里，当前不做。
 */
fun ensureMediaWatch(context: Context) {
    if (isMediaWatchScheduled(context)) return
    scheduleMediaWatchNow(context)
}

/** 无条件重挂——只给 [MediaWatchJob] 的"释放"路径用（那时旧 job 正在跑，
 *  不是 pending，schedule 同 ID 正是官方要求的动作）。 */
internal fun scheduleMediaWatchNow(context: Context) {
    val result = runCatching { jobScheduler(context).schedule(buildMediaWatchJobInfo(context)) }
        .getOrElse {
            android.util.Log.w(TAG, "media watch schedule threw", it)
            return
        }
    // OEM 上 schedule 会**返回失败而不抛异常**（配额/限制），静默失败等于
    // 监听没挂上。必须留痕，否则排查时看不出"挂了但没挂上"。
    if (result != JobScheduler.RESULT_SUCCESS) {
        android.util.Log.w(TAG, "media watch schedule refused by system, result=$result")
    }
}

/** UX-06: 暂停自动备份时连监听一起停（否则"暂停"对事件②形同虚设）。 */
fun cancelMediaWatch(context: Context) {
    runCatching { jobScheduler(context).cancel(MEDIA_WATCH_JOB_ID) }
}

/**
 * 队列去重：**已经有一个"等着跑"的就不必再排。**
 *
 * 它跑起来会扫水位以上的全部，前面攒的都能捞到，多排几个只是多几次
 * 空扫描——但每次空扫描都会闪一下前台服务通知（连拍 10 分钟能闪 21 次），
 * 纯属打扰用户。
 *
 * `ENQUEUED` = 等约束（比如没连 Wi-Fi）；`BLOCKED` = 排在前一个后面。
 * 两者都是"还没跑，跑起来会扫全量"，所以都算数。
 * `RUNNING` **不算**——正在跑的那个可能已经扫过了，这次事件的照片它
 * 未必看得到，必须再排一个跟在它后面。
 */
internal fun shouldDispatchWatchBackup(states: List<WorkInfo.State>): Boolean =
    states.none { it == WorkInfo.State.ENQUEUED || it == WorkInfo.State.BLOCKED }

/**
 * 派活：往备份通道排一轮。
 *
 * `APPEND_OR_REPLACE` 就是队列语义——正在跑的时候排进来的，**排队等着**，
 * 前一个跑完才轮到它。不是并行（两个 BackupWorker 同时扫同一个水位会
 * 重复推送字节），也不是丢弃（KEEP 会把这次事件吞掉，洞又回来了），也
 * 不是抢占（REPLACE 会打断正在传照片的那个）。
 *
 * 链上某个 work 彻底失败时，排在它后面的会被连坐标记 FAILED 而不执行——
 * 这是**对的**：水位没推进，那一轮的照片还在，后面那个跑起来也是撞同一
 * 个错。下一个事件来时 `APPEND_OR_REPLACE` 会把这条死链整个替换掉，自愈。
 */
internal fun dispatchWatchBackup(context: Context) {
    val wm = WorkManager.getInstance(context)
    val states = wm.getWorkInfosForUniqueWork(MEDIA_WATCH_BACKUP_WORK_NAME).get().map { it.state }
    if (!shouldDispatchWatchBackup(states)) return
    val settings = BackupSettings(context.filesDir).load()
    // 约束在这里，不在监听上（见文件头）。后台档：Wi-Fi 随设置 + 电量不低。
    val spec = constraintsFor(BackupTier.BACKGROUND, settings)
    // .result.get() 等落库——onStartJob 之后进程随时可能被回收，
    // 派活没落盘就等于没派。
    wm.enqueueUniqueWork(
        MEDIA_WATCH_BACKUP_WORK_NAME,
        ExistingWorkPolicy.APPEND_OR_REPLACE,
        backupWorkRequest(spec),
    ).result.get()
}

/**
 * 看门 Job：只派活、只重挂，不干活。
 *
 * onStartJob 里的**顺序是承重的**：先派活，后重挂。
 * javadoc 原文："Scheduling the new job before or during processing will
 * cause the current job to be stopped […] **your app process may be killed**
 * since it will no longer be in a valid component lifecycle."
 * 先重挂的话，派活的代码可能根本跑不到——监听是活的，但这一波照片没人管。
 *
 * 返回 `true`（我有异步工作）+ 后台线程收尾：派活要等 WorkManager 落库，
 * 那是阻塞调用，不能占主线程。重挂用 `schedule(同 job ID)` 代替
 * `jobFinished()`，这是 javadoc 明确允许的——"you do not need to call
 * jobFinished() if you call schedule() using the same job ID as the
 * currently running job."
 */
class MediaWatchJob : JobService() {

    override fun onStartJob(params: JobParameters?): Boolean {
        val ctx = applicationContext
        thread(name = "ppass-media-watch") {
            try {
                // 未配对 / 已暂停 → 不派活（doWork 内部还有第二道闸）。
                val paused = AutoBackupPrefs(ctx.filesDir).paused()
                val paired = PairingStore(ctx.filesDir).load() != null
                if (paired && !paused) dispatchWatchBackup(ctx)
            } catch (t: Throwable) {
                android.util.Log.w(TAG, "dispatch failed", t)
            } finally {
                // 释放。**无论派活成败都要重挂**——派活失败最多丢一轮
                // （水位没动，下个事件捞得回来），重挂失败是监听永久消失。
                //
                // 暂停态下不重挂：否则「暂停自动备份」被这里悄悄复活
                // （pauseAutoBackup 的 cancel 与这里可能撞上，所以再查一次）。
                if (!AutoBackupPrefs(ctx.filesDir).paused()) scheduleMediaWatchNow(ctx)
            }
        }
        return true
    }

    /** 系统在我们重挂之前把 job 停了（极罕见——onStartJob 到重挂只有
     *  毫秒级）。返回 true 让系统按退避重排，保证监听不会因此永久丢失。 */
    override fun onStopJob(params: JobParameters?): Boolean = true
}
