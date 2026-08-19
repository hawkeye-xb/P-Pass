// MOB-18: 后台备份是否还活着——force-stop 检测。
//
// ⚠️ **本模块当前无人调用**：功能于 2026-08-19 被用户拍板 pending 进
// backlog，UI 提示与调度接线均已撤除。保留代码是因为判据本身（两边对账）
// 是真机验证过的正确结论，将来若要重做这个能力可以直接接回来。
// 撤除原因见 .claude/cards/backlog/MOB-18-force-stop-detection.md。
//
// 用户在设置里「强行停止」App 之后，JobScheduler 会清空这个 App 的**全部**
// job：content trigger 监听没了、周期兜底没了。这是 Android 平台行为，任何
// App 都一样，无法阻止，也无法在后台自愈（force-stop 之后 App 不允许自启动，
// 只有用户手动打开才有机会）。
//
// 麻烦的是它**静默**：权限还在、配对还在，所以既有的三张引导卡
// （电池白名单 / 通知权限 / 配对失效）一张都不会亮，用户完全看不出备份
// 已经彻底停摆，只会觉得"照片怎么不同步了"。
//
// 用户定调（2026-08-19）："不要做静默恢复，就是要提醒。"
package com.hawkeyexb.ppass.backup

import android.app.job.JobScheduler
import android.content.Context
import androidx.work.WorkManager
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 调度体系是否还活着。
 *
 *  ## 判据为什么是「两边对账」而不是只查 WorkManager
 *
 *  初版只查 `getWorkInfosForUniqueWork`，真机实测**完全失效**——用户
 *  force-stop 之后提示一次都没亮过。原因：那个 API 读的是 **WorkManager
 *  自己的数据库**，而 force-stop 清的是 **JobScheduler 里的 job**，两者
 *  是两套存储。force-stop 后 work 记录纹丝不动（状态还是 ENQUEUED），
 *  判据恒真。实测数据：
 *
 *  ```
 *  force-stop 前  JobScheduler job 数: 2
 *  force-stop 后  JobScheduler job 数: 0    ← 只有这边被清
 *  ```
 *
 *  所以改成对账：**WorkManager 认为有活儿在排，JobScheduler 那边却一个
 *  job 都没有** = 调度被外力清空了。单查任一边都不行——
 *  - 只查 WorkManager：force-stop 检测不到（初版的错）；
 *  - 只查 JobScheduler：未配对/已暂停时本来就没 job，会误报。
 *
 *  ⚠️ 阻塞调用（读 WorkManager 本地库），别在主线程用。 */
fun isBackupScheduled(context: Context): Boolean {
    val hasWork = WorkManager.getInstance(context)
        .getWorkInfosForUniqueWork(CONTENT_TRIGGER_WORK_NAME)
        .get()
        .any { !it.state.isFinished }
    // 压根没排过（未配对 / 已暂停）——不是"被清空"，调用方另有前置判断。
    if (!hasWork) return false
    val js = context.getSystemService(JobScheduler::class.java) ?: return true
    // 周期兜底任务是常驻的，所以正常运行时这里必定非空；全空只可能是
    // 被外力清过（rearm 间隙也不会全空——周期任务还在）。
    return js.allPendingJobs.isNotEmpty()
}

@Serializable
data class BackupHealthState(
    /** 检测到调度体系断过、且用户还没确认知晓。 */
    val interruptedUnacknowledged: Boolean = false,
    /** 检测到中断的时刻（unix ms；0 = 无记录）。 */
    val detectedAt: Long = 0L,
)

/** 中断记录的落盘（tmp+rename 崩溃安全，与 AutoBackupPrefs 同款）。
 *
 *  为什么要落盘而不是内存标志：检测发生在 `PPassApplication.onCreate`
 *  的后台线程，UI 在 `MainActivity` 里读——跨组件、且要能扛住进程重启。 */
class BackupHealthPrefs(private val dir: File) {
    private val file = File(dir, "backup_health.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun load(): BackupHealthState =
        if (file.isFile) {
            runCatching {
                json.decodeFromString(BackupHealthState.serializer(), file.readText())
            }.getOrDefault(BackupHealthState())
        } else BackupHealthState()

    fun recordInterrupted(now: Long) {
        save(BackupHealthState(interruptedUnacknowledged = true, detectedAt = now))
    }

    /** 用户在 UI 上点了「知道了」——提示消失，但不清 detectedAt。 */
    fun acknowledge() {
        save(load().copy(interruptedUnacknowledged = false))
    }

    private fun save(state: BackupHealthState) {
        dir.mkdirs()
        val tmp = File(dir, "backup_health.json.tmp")
        tmp.writeText(json.encodeToString(BackupHealthState.serializer(), state))
        check(tmp.renameTo(file)) { "cannot persist backup_health.json" }
    }
}
