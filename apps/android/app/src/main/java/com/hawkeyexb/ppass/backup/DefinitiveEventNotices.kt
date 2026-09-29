// #130 第 1 层：手机端对**确定事件**发系统通知——只发「确定、不会自愈、用户能处理」的三类事件。
//
// 1. 配对失效：桌面明确回 not_authorized / not_paired（#466 的判据，事实源是
//    `flowDeliveryPairingLoss`——投递、探测、前台心跳三处都往它里记，红卡也读它）。
// 2. 相册权限被收回（含从「全部」降到「部分」）：`mediaAccessOf` 三档，任一次运行时对比上次看到的档位。
// 3. 系统停止了后台备份：MOB-28 的中断事实（`BackupHealthState.interruptedUnacknowledged`），
//    或电池优化被重新打开（`isIgnoringBatteryOptimizations` true → false）。
//
// 临时失败（桌面不在、网络、中继限流、重试中）和单张最终失败**不在这里**——#418 的决定不变，
// `FlowEngine.fail()` 仍不发通知。
//
// ## 去重 / 复位（状态落盘，进程重启不重复发）
//
// 每类事件「状态变化时只发一次，恢复后复位」。判定是纯函数 [decideDefinitiveNotices]，
// 上一次的状态存在 `definitive_notices.json`：
// - 配对失效的去重键是**配对代号（epoch）**。`flowDeliveryPairingLoss` 只在内存里，进程重启后
//   `isLost` 会是 false——那不代表恢复。复位只有两种：本地没有配对了，或当前配对换了代号（重新扫码）。
// - 相册权限记上次看到的档位：变差才发（FULL → PARTIAL / NONE，PARTIAL → NONE），回到 FULL 复位。
//   从没记过（新装、升级上来）只记基线不发。
// - 后台中断的去重键是 `detectedAt`（`recordInterrupted` 只在未确认时写，同一次中断它不变）；
//   用户点了「恢复」（interruptedUnacknowledged = false）复位。电池优化记上次看到的值，只在 true → false
//   且用户要后台备份（`AutoBackupPrefs.requested()`）时发；从没记过只记基线。
//
// ## 开关与通知权限
//
// 「需要处理时通知我」开关（NotifyOnFailurePrefs）和系统通知权限只挡**发出去**这一步，状态照常往前走：
// 否则开关关着时发生过的事，会在用户打开开关那一刻一起补发。后台从不申请 POST_NOTIFICATIONS。
package com.hawkeyexb.ppass.backup

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.hawkeyexb.ppass.backup.flow.PairingEpoch
import com.hawkeyexb.ppass.backup.flow.flowDeliveryPairingLoss
import com.hawkeyexb.ppass.battery.isIgnoringBatteryOptimizations
import com.hawkeyexb.ppass.transport.PairingStore
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 三类确定事件。每类一个通知 id（后发的替换先发的）。 */
enum class DefinitiveEvent { PAIRING_LOST, MEDIA_ACCESS_REVOKED, BACKGROUND_STOPPED }

/** 一条要发的通知：事件 + 文案需要的那一点事实。 */
sealed class DefinitiveNotice(val event: DefinitiveEvent) {
    data object PairingLost : DefinitiveNotice(DefinitiveEvent.PAIRING_LOST)

    /** [now] 是降到的那一档（PARTIAL 或 NONE）。 */
    data class MediaAccessRevoked(val now: MediaAccess) : DefinitiveNotice(DefinitiveEvent.MEDIA_ACCESS_REVOKED)

    /** [batteryOnly] = 只是电池优化被打开（没有 MOB-28 中断）。两者同时成立时按中断说。 */
    data class BackgroundStopped(val batteryOnly: Boolean) : DefinitiveNotice(DefinitiveEvent.BACKGROUND_STOPPED)
}

/** 这一次运行看到的事实（Android 侧查出来，纯函数只读它）。 */
data class DefinitiveFacts(
    /** 当前配对的代号；null = 没有配对。 */
    val pairingEpoch: String?,
    /** 当前配对被桌面明确拒绝过（`flowDeliveryPairingLoss.isLost(当前 epoch)`）。 */
    val pairingLost: Boolean,
    val mediaAccess: MediaAccess,
    /** 用户要后台备份（意图，不是此刻排没排上）。 */
    val backgroundRequested: Boolean,
    /** MOB-28 的中断还没被用户确认时的 `detectedAt`；null = 没有未确认的中断。 */
    val interruptionDetectedAt: Long?,
    val batteryWhitelisted: Boolean,
)

@Serializable
data class DefinitiveNoticeState(
    /** 已为哪个配对代号发过「配对失效」。 */
    val notifiedLostEpoch: String? = null,
    /** 上次看到的相册权限档位（MediaAccess.name）；null = 从没记过。 */
    val lastMediaAccess: String? = null,
    /** 已为哪一次中断（detectedAt）发过「系统停止了后台备份」。 */
    val notifiedInterruptionAt: Long? = null,
    /** 上次看到的电池优化豁免；null = 从没记过。 */
    val lastBatteryWhitelisted: Boolean? = null,
)

data class DefinitiveDecision(
    val next: DefinitiveNoticeState,
    val post: List<DefinitiveNotice>,
    /** 已恢复的事件：撤掉还挂着的旧通知。 */
    val cancel: Set<DefinitiveEvent>,
)

private fun rankOf(access: MediaAccess): Int = when (access) {
    MediaAccess.FULL -> 2
    MediaAccess.PARTIAL -> 1
    MediaAccess.NONE -> 0
}

/** 纯判定：上一次的状态 + 这一次的事实 → 新状态、要发的、要撤的。 */
fun decideDefinitiveNotices(prev: DefinitiveNoticeState, facts: DefinitiveFacts): DefinitiveDecision {
    val post = mutableListOf<DefinitiveNotice>()
    val cancel = mutableSetOf<DefinitiveEvent>()
    val paired = facts.pairingEpoch != null

    // 1. 配对失效：键是 epoch。没配对 / 换了代号才复位；isLost 变 false（进程重启）不算恢复。
    var notifiedLostEpoch = prev.notifiedLostEpoch
    if (notifiedLostEpoch != null && notifiedLostEpoch != facts.pairingEpoch) {
        notifiedLostEpoch = null
        cancel += DefinitiveEvent.PAIRING_LOST
    }
    if (paired && facts.pairingLost && notifiedLostEpoch != facts.pairingEpoch) {
        post += DefinitiveNotice.PairingLost
        notifiedLostEpoch = facts.pairingEpoch
        cancel -= DefinitiveEvent.PAIRING_LOST
    }

    // 2. 相册权限：变差才发，回到 FULL 复位；没有基线只记不发；没配对时只记（没有要备份的东西）。
    val lastAccess = prev.lastMediaAccess?.let { name -> MediaAccess.entries.firstOrNull { it.name == name } }
    if (lastAccess != null && rankOf(facts.mediaAccess) < rankOf(lastAccess) && paired) {
        post += DefinitiveNotice.MediaAccessRevoked(facts.mediaAccess)
    }
    if (lastAccess != null && lastAccess != MediaAccess.FULL && facts.mediaAccess == MediaAccess.FULL) {
        cancel += DefinitiveEvent.MEDIA_ACCESS_REVOKED
    }

    // 3. 后台被停：中断按 detectedAt 去重；电池优化只在 true → false 且用户要后台备份时发。
    val interruptionAt = facts.interruptionDetectedAt?.takeIf { facts.backgroundRequested }
    val newInterruption = interruptionAt != null && interruptionAt != prev.notifiedInterruptionAt
    val batteryReenabled = prev.lastBatteryWhitelisted == true && !facts.batteryWhitelisted && facts.backgroundRequested
    if (paired && (newInterruption || batteryReenabled)) {
        post += DefinitiveNotice.BackgroundStopped(batteryOnly = interruptionAt == null)
    }
    val wasStopped = prev.notifiedInterruptionAt != null || prev.lastBatteryWhitelisted == false
    val isStopped = interruptionAt != null || (!facts.batteryWhitelisted && facts.backgroundRequested)
    if (wasStopped && !isStopped) cancel += DefinitiveEvent.BACKGROUND_STOPPED

    return DefinitiveDecision(
        next = DefinitiveNoticeState(
            notifiedLostEpoch = notifiedLostEpoch,
            lastMediaAccess = facts.mediaAccess.name,
            notifiedInterruptionAt = interruptionAt,
            lastBatteryWhitelisted = facts.batteryWhitelisted,
        ),
        post = post,
        cancel = cancel,
    )
}

/** 落盘（tmp+rename，与 BackupHealthPrefs 同款）。 */
class DefinitiveNoticeStore(private val dir: File) {
    private val file = File(dir, "definitive_notices.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun load(): DefinitiveNoticeState =
        if (file.isFile) {
            runCatching { json.decodeFromString(DefinitiveNoticeState.serializer(), file.readText()) }
                .getOrDefault(DefinitiveNoticeState())
        } else {
            DefinitiveNoticeState()
        }

    fun save(state: DefinitiveNoticeState) {
        dir.mkdirs()
        val tmp = File(dir, "definitive_notices.json.tmp")
        tmp.writeText(json.encodeToString(DefinitiveNoticeState.serializer(), state))
        check(tmp.renameTo(file)) { "cannot persist definitive_notices.json" }
    }
}

/** 发送边界（Android 侧是 [SystemDefinitiveEventNotifier]，JVM 测试用 fake）。 */
interface DefinitiveEventNotifier {
    /** 「需要处理时通知我」开关开着，且系统允许本 App 发通知。 */
    fun enabled(): Boolean
    fun post(notice: DefinitiveNotice)
    fun cancel(event: DefinitiveEvent)
}

/** 读状态 → 判定 → 先落盘，再 best-effort 发/撤。状态推进不看开关。 */
class DefinitiveEventMonitor(
    private val store: DefinitiveNoticeStore,
    private val notifier: DefinitiveEventNotifier,
) {
    fun evaluate(facts: DefinitiveFacts) = synchronized(LOCK) {
        val decision = decideDefinitiveNotices(store.load(), facts)
        store.save(decision.next)
        decision.cancel.forEach { runCatching { notifier.cancel(it) } }
        if (decision.post.isNotEmpty() && runCatching { notifier.enabled() }.getOrDefault(false)) {
            decision.post.forEach { runCatching { notifier.post(it) } }
        }
        decision
    }

    private companion object {
        /** 启动线程、Worker、前台、配对失效订阅可能同时评估——进程内串行（本 App 单进程）。 */
        val LOCK = Any()
    }
}

/**
 * MOB-94 的相册权限三档生产查询点（MainActivity 与这里共用）。
 * `imagesGranted` 取主相册权限——API 33+ 是 READ_MEDIA_IMAGES，更低版本是 READ_EXTERNAL_STORAGE。
 */
fun currentMediaAccess(context: Context): MediaAccess = mediaAccessOf(
    imagesGranted = ContextCompat.checkSelfPermission(
        context,
        if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE,
    ) == PackageManager.PERMISSION_GRANTED,
    visualSelectedGranted = ContextCompat.checkSelfPermission(
        context, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
    ) == PackageManager.PERMISSION_GRANTED,
    sdkInt = Build.VERSION.SDK_INT,
)

/** 这一次运行的事实。阻塞（读文件 + binder），调用方放到非主线程。 */
internal fun definitiveFactsOf(context: Context): DefinitiveFacts {
    val dir = context.filesDir
    val epoch = PairingStore(dir).load()?.pairingEpoch
    val health = BackupHealthPrefs(dir).load()
    return DefinitiveFacts(
        pairingEpoch = epoch,
        pairingLost = epoch != null && flowDeliveryPairingLoss.isLost(PairingEpoch(epoch)),
        mediaAccess = currentMediaAccess(context),
        backgroundRequested = AutoBackupPrefs(dir).requested(),
        interruptionDetectedAt = health.detectedAt.takeIf { health.interruptedUnacknowledged },
        batteryWhitelisted = isIgnoringBatteryOptimizations(context),
    )
}

/**
 * #130 第 1 层的唯一评估入口：进程启动、Worker 唤醒、App 进前台、配对失效被记下时都调它。
 * 幂等；任何异常都吞掉（通知是补充渠道，App 内红卡 / 引导卡才是状态真相）。
 */
fun evaluateDefinitiveEvents(context: Context) {
    val app = context.applicationContext
    runCatching {
        DefinitiveEventMonitor(
            DefinitiveNoticeStore(app.filesDir),
            SystemDefinitiveEventNotifier(app, NotifyOnFailurePrefs(app.filesDir)),
        ).evaluate(definitiveFactsOf(app))
    }.onFailure { android.util.Log.w("PPassNotice", "definitive event evaluation failed", it) }
}
