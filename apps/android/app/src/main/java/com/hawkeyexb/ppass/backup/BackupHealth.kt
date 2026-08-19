// MOB-18: 后台备份是否还活着——force-stop 检测。
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

import android.content.Context
import androidx.work.WorkManager
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 查 WorkManager：content trigger 监听还在不在。
 *
 *  **主动查询**（本地数据库一次读），不需要 App 常驻、不需要监听任何东西。
 *  判据用 content trigger 而不是周期任务：它是主路径，且每轮备份后由
 *  ContentTriggerRearmWorker 重挂，正常运行时必定存在；它不在 = 调度体系
 *  已经断了。
 *
 *  ⚠️ 阻塞调用，别在主线程用。 */
fun isBackupScheduled(context: Context): Boolean =
    WorkManager.getInstance(context)
        .getWorkInfosForUniqueWork(CONTENT_TRIGGER_WORK_NAME)
        .get()
        .any { !it.state.isFinished }

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
