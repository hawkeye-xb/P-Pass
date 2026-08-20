// MOB-28（2026-08-20 用户拍板做）：监听中断的**区分**与用户确认恢复。
//
// ## 为什么现在能做，昨天不能
//
// MOB-18 当初被 pending，理由是"我们拦不住 WorkManager 自愈"——
// `ForceStopRunnable` 跑在 `androidx.startup` 的 ContentProvider 里，比
// `Application.onCreate` 还早就把 work 重排了，"检测到 → 只提示不恢复"
// 应用层实现不了。真机数据：
//
// ```
// force-stop 前  JobScheduler job 数: 2
// force-stop 后  JobScheduler job 数: 0
// 重开 App 后    JobScheduler job 数: 2   ← 没等我们的代码动手就恢复了
// ```
//
// **MOB-27 把这个前提推翻了。** 照片监听现在是我们自己注册在 JobScheduler
// 上的 job（`MEDIA_WATCH_JOB_ID`），WorkManager 完全不知道它存在，
// `ForceStopRunnable` 碰不到它。除了我们自己调 `ensureMediaWatch`，没有
// 任何东西会把它装回去——所以"用户点了才恢复"现在真的做得到。
//
// ## 还差一个判据：怎么区分"重启"和"被清"
//
// 两种情况都表现为监听不在，但语义完全相反：
// - **重启**：用户没做任何"停止"的意思表示 → 自动恢复才符合预期
// - **force-stop / OEM 清理**：用户（或系统）主动掐掉了 → 必须问
//
// 判据是**开机时刻**：`currentTimeMillis() - elapsedRealtime()`。
// `elapsedRealtime` 从开机起单调递增（含深睡），所以这个差在同一次开机内
// 是稳定值，重启后会变。见 [bootStampOf] / [isSameBoot]。
//
// ## 用户原话（2026-08-19，本卡的全部理由）
//
// "不要做静默恢复，就是要提醒。"
// "必须点了才恢复。你都提示了，就别自作主张。"
package com.hawkeyexb.ppass.backup

import android.content.Context
import com.hawkeyexb.ppass.transport.PairingStore
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 监听不在位时该怎么办。 */
enum class WatchRecovery {
    /** 监听在位，正常路径。 */
    NORMAL,

    /** 监听不在，但是重启导致的（或首次安装）——用户没做任何"停止"的
     *  意思表示，自动挂上才符合预期。 */
    AUTO_REARM,

    /** 监听在**同一次开机内**凭空消失了——force-stop 或 OEM 清理。
     *  不许自动恢复：记录 + 提示，用户点了才恢复。 */
    ASK_USER,
}

/**
 * 开机时刻 = 墙上时钟 − 开机以来的时长。
 *
 * `elapsedRealtime` 从开机起单调递增（含深睡不停），所以这个差在同一次开机
 * 内是**稳定值**，重启后会变成另一个值。这是标准做法，不需要任何权限。
 */
internal fun bootStampOf(nowMs: Long, elapsedRealtimeMs: Long): Long = nowMs - elapsedRealtimeMs

/** 容差：NTP 校时会让墙上时钟小幅跳动，从而让开机时刻算出来差几秒。
 *  取 60s——远大于正常校时幅度，远小于任何真实的开机间隔。 */
internal const val BOOT_STAMP_TOLERANCE_MS = 60_000L

internal fun isSameBoot(a: Long, b: Long): Boolean =
    kotlin.math.abs(a - b) <= BOOT_STAMP_TOLERANCE_MS

/**
 * 判定表。**纯函数**——三个布尔进，一个结论出，JVM 单测直接覆盖全部八种组合。
 *
 * 顺序是承重的：`awaitingUserConsent` 必须排在最前面。已经在等用户点了，
 * **重启也不许悄悄替他决定**——否则用户重启一次手机，那条提示就凭空消失，
 * 而备份被谁停过这件事他永远不会知道。这正是"别自作主张"的字面要求。
 */
internal fun decideRecovery(
    watchScheduled: Boolean,
    sameBootAsLastRun: Boolean,
    awaitingUserConsent: Boolean,
): WatchRecovery = when {
    awaitingUserConsent -> WatchRecovery.ASK_USER
    watchScheduled -> WatchRecovery.NORMAL
    !sameBootAsLastRun -> WatchRecovery.AUTO_REARM
    else -> WatchRecovery.ASK_USER
}

@Serializable
data class BackupHealthState(
    /** 检测到调度体系断过、且用户还没确认知晓。 */
    val interruptedUnacknowledged: Boolean = false,
    /** 检测到中断的时刻（unix ms；0 = 无记录）。 */
    val detectedAt: Long = 0L,
    /** MOB-28: 上次进程运行时记录的**开机时刻**（见 [bootStampOf]）。
     *  0 = 从没记过（首次安装）——按"不同次开机"处理，自动挂上。 */
    val lastBootStamp: Long = 0L,
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

    /** MOB-28: 必须 copy 而不是整体覆盖——整体覆盖会把 [lastBootStamp]
     *  抹成 0，下一次进程启动就会把"被清"误判成"重启"，提示永远出不来。 */
    fun recordInterrupted(now: Long) {
        save(load().copy(interruptedUnacknowledged = true, detectedAt = now))
    }

    /** MOB-28: 每次进程启动都记一次开机时刻（判据的另一半）。 */
    fun recordBootStamp(stamp: Long) {
        save(load().copy(lastBootStamp = stamp))
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

/**
 * MOB-28: 进程启动时的监听对账。**两个入口共用这一段**——
 * `PPassApplication.onCreate`（进程因任何原因起来）与 `BootWatchReceiver`
 * （开机广播）。幂等，重复调用无副作用。
 *
 * ⚠️ 阻塞（读文件 + binder），调用方负责放到非主线程。
 *
 * 判据为什么不再查 WorkManager：MOB-18 初版查 `getWorkInfosForUniqueWork`
 * **完全失效**——那个 API 读的是 WorkManager 自己的数据库，而 force-stop 清的
 * 是 JobScheduler 里的 job，两套存储。force-stop 后 work 记录纹丝不动，判据
 * 恒真。现在直接查看门 job（`isMediaWatchScheduled`）：它就在 JobScheduler
 * 上，被清就是真的没了，而且 WorkManager 的自愈机制碰不到它。
 */
fun reconcileWatchOnProcessStart(context: Context, nowMs: Long, elapsedMs: Long) {
    if (PairingStore(context.filesDir).load() == null) return
    if (AutoBackupPrefs(context.filesDir).paused()) return

    val prefs = BackupHealthPrefs(context.filesDir)
    val state = prefs.load()
    val stamp = bootStampOf(nowMs, elapsedMs)
    val decision = decideRecovery(
        watchScheduled = isMediaWatchScheduled(context),
        sameBootAsLastRun = isSameBoot(stamp, state.lastBootStamp),
        awaitingUserConsent = state.interruptedUnacknowledged,
    )
    // 开机时刻**先记**——无论结论如何。漏记会让下一次启动把同一次开机
    // 误判成重启，提示就永远出不来。

    prefs.recordBootStamp(stamp)

    when (decision) {
        WatchRecovery.ASK_USER -> {
            // 只记录、只提示，**不重挂、不跑备份**。
            // 用户原话："必须点了才恢复。你都提示了，就别自作主张。"
            if (!state.interruptedUnacknowledged) prefs.recordInterrupted(nowMs)
        }
        WatchRecovery.NORMAL, WatchRecovery.AUTO_REARM -> {
            scheduleAutoBackup(context)
            triggerProcessStartCatchup(context)
        }
    }
}

/** MOB-28: 用户在提示卡上点了「恢复备份」——**唯一**允许在 ASK_USER 之后
 *  重挂的入口。清标志 + 重挂 + 立刻补跑一次（人在操作，用户在场档）。 */
fun resumeAfterInterruption(context: Context) {
    BackupHealthPrefs(context.filesDir).acknowledge()
    scheduleAutoBackup(context)
    triggerUserPresentBackup(context)
}
