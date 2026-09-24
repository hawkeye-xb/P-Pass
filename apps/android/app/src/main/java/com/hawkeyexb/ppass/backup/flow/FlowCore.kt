// ARCH-13 (#417) → #413: 逐张循环的核心类型与端口。本文件不碰任何 Android API，JVM 单测直接可跑。
//
// 模型（#413 最终设计）：三层——意图（范围、跳过名单、暂停标志）/ 事实（order：一次传输一行）/ 待办（现算）。
// 触发只叫醒循环 → 入口检查（不持有 FGS、不读文件）→ 申请 FGS + wakelock + 一条推送订阅 →
// 取件（遗留续传 → 对账扫描 → 新照片 → 对账补传）→ 准备 → 传输 → 提交 → 下一张 → 释放。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.MediaDetails
import kotlinx.serialization.Serializable

/** 配对代号（授权凭证的版本号，不是身份）。 */
@Serializable
data class PairingEpoch(val value: String) {
    companion object {
        val INITIAL = PairingEpoch("")
    }
}

/**
 * MOB-98：一张照片的「版本」只由**内容变没变**决定 —— `date_modified` 与 `size`。
 * `generation_modified` 不在其列：它在内容一个字节没变时也会自增（把照片移进相册就会）。
 */
internal fun sourceVersionOf(dateModified: Long, size: Long): String = "$dateModified:$size"

/** 桌面给出的完成凭据（已由 [relayFlowCompletion] 对过四个字段）。 */
data class CompletionReceipt(
    val queueSequence: Long,
    val receiptId: String,
    val pairingEpoch: PairingEpoch = PairingEpoch.INITIAL,
    val contentHash: String? = null,
    val leaseToken: String = "",
)

/** `lease_token` 的线上形状。#417：queue_sequence / lease_token 都由 order 行 id 填，线协议不改。 */
internal fun leaseTokenFor(orderId: Long): String = "lease-$orderId"

/**
 * AUDIT-01：长期审计事件的种类。事件与它描述的事实在同一个 order 事务里落库
 * （[com.hawkeyexb.ppass.backup.order.OrderStore.transition] 的 audit 参数）。
 */
object AuditKinds {
    const val ROUND_CONTROLLED = "flow.round.controlled"
    const val ITEM_CONFIRMED = "flow.item.confirmed"
    const val ITEM_ATTENTION = "flow.item.attention"
    const val ITEM_SOURCE_MISSING = "flow.item.source_missing"
    const val RECONCILIATION_RESOLVED = "flow.reconciliation.resolved"
}

/**
 * 触发原因。触发只叫醒循环（在跑就合并），不带任何「做什么」的指令，只有两个维度：
 * - [userPresent]：人在场（打开 App、改范围、点继续、手动）——不查后台开关、不查电量（MOB-19 / NET-06）。
 *   仅 Wi‑Fi 对所有触发都生效（MOB-76）。
 * - [reconcile]：这一轮在「发现」（`generation > G` 的新照片）取完之后接着做「对账」：扫一遍范围内
 *   G 以下的照片（新增相册、恢复已跳过、中断遗留）、兜底重试失败项、问桌面「这些还在吗」。
 *
 * 枚举名会被写进 WorkManager 的 input data（BackupWorker 的 KEY_REASON），**不许改名**。
 */
enum class TriggerReason(val userPresent: Boolean = false, val reconcile: Boolean = false) {
    MEDIA_CHANGE,
    PROCESS_START,
    NETWORK_CHANGE,
    UNREACHABLE_PROBE,
    CONSTRAINTS_MET,
    PERIODIC(reconcile = true),
    APP_FOREGROUND(userPresent = true, reconcile = true),
    SCOPE_ADDED(userPresent = true, reconcile = true),
    PAIRING_REPAIRED(userPresent = true, reconcile = true),
    /** 继续：暂停期间只改了意图（范围、跳过名单），继续后待办现算，所以要对账。 */
    USER_CONTINUE(userPresent = true, reconcile = true),
    RETRY_FAILED(userPresent = true, reconcile = true),
    /** #418「已跳过的照片 · 点击恢复」：移出跳过名单的照片在 G 以下，只有对账扫得到。 */
    RESTORE_SKIPPED(userPresent = true, reconcile = true),
    MANUAL(userPresent = true),
}

/**
 * 全局「等待中」的原因（[GlobalState.WAITING]）。由我们自动恢复，持久化（进程重启后还在，见 [FlowControl.waitReason]）。
 * 持久化存 [name]，不许改名。
 */
enum class WaitReason {
    NOT_PAIRED,
    DISABLED,
    WIFI,
    BATTERY,
    /** 后台申请 FGS 被拒或被系统收走：下一次触发照常重试（不再卡到回前台）。 */
    FGS_BLOCKED,
    /** 桌面不可达（探测失败 / 路径失败）：挂网络回调 + 3 次间隔 10 分钟的探测。 */
    DESKTOP_UNREACHABLE,
    /** 桌面存不下（`storage_full`）。 */
    DESKTOP_STORAGE_FULL,
    /** 桌面照片库文件夹不存在或不可写（`library_unavailable` / 健康检查 `library_writable=false`）。 */
    DESKTOP_LIBRARY_UNAVAILABLE,
    /** 桌面索引库等其他写失败（`storage_failed` / 健康检查 `index_ok=false`）。 */
    DESKTOP_STORAGE_ERROR,
}

/** 对端失败 → 等待原因。 */
fun waitReasonOf(kind: PeerFailureKind): WaitReason = when (kind) {
    PeerFailureKind.STORAGE_FULL -> WaitReason.DESKTOP_STORAGE_FULL
    PeerFailureKind.LIBRARY_UNAVAILABLE -> WaitReason.DESKTOP_LIBRARY_UNAVAILABLE
    PeerFailureKind.STORAGE_ERROR -> WaitReason.DESKTOP_STORAGE_ERROR
}

/** 探测带回的桌面健康 → 不健康时的等待原因；null = 健康（旧桌面不报 health 也算健康）。低空间只是预警，不挡。 */
fun waitReasonOf(health: DesktopHealth?): WaitReason? = when {
    health == null -> null
    !health.libraryWritable -> WaitReason.DESKTOP_LIBRARY_UNAVAILABLE
    !health.indexOk -> WaitReason.DESKTOP_STORAGE_ERROR
    else -> null
}

/** 一次检查所需的全部条件事实。由 Android 层实时读取，这里只做判断。 */
data class Conditions(
    val paired: Boolean = true,
    val autoBackupEnabled: Boolean = true,
    val wifiOnly: Boolean = false,
    val onUnmetered: Boolean = true,
    val batteryLow: Boolean = false,
)

/**
 * 入口的条件检查（不含暂停——暂停是更早、更硬的一道闸；不含桌面可达——那要走网络）。
 * 纯函数，C-04 的判据本体。FGS 受阻不在这里：它不是一个持久的闸门，下一次触发照常去申请。
 */
fun waitReasonOf(conditions: Conditions, userPresent: Boolean): WaitReason? = when {
    !conditions.paired -> WaitReason.NOT_PAIRED
    !userPresent && !conditions.autoBackupEnabled -> WaitReason.DISABLED
    conditions.wifiOnly && !conditions.onUnmetered -> WaitReason.WIFI
    !userPresent && conditions.batteryLow -> WaitReason.BATTERY
    else -> null
}

/** 传一张的请求。queue_sequence = [orderId]，lease_token = [leaseTokenFor]。 */
data class DeliveryRequest(
    val orderId: Long,
    val pairingEpoch: PairingEpoch,
    val contentHash: String,
    val details: MediaDetails,
) {
    val leaseToken: String get() = leaseTokenFor(orderId)
}

/**
 * 一次传输的结局，按 #410 / #415 裁决 3 / #413 契约 §5 分类：
 * - [SourceMissing]：原图没了、导入的 hash 与这张 order 记的对不上（中断期间被编辑）——记「源已删」，**不计失败**。
 * - [ItemFailure]：这一张的问题（读不出、桌面拒收这条请求、未知错误码）——立即重试 1 次，仍失败记 FAILED、计次数。
 * - [PathFailure]：路走不通（不可达、握手失败、onLost、3 分钟无新字节、`fetch_failed`、provider 上线超时）——
 *   order 保持「传输中」可续传，退出循环，不计次数。
 * - [PeerFailure]：桌面自身的问题（`storage_full` / `library_unavailable` / `storage_failed`）——退出循环，不计次数，
 *   原因带回手机显示。
 */
sealed interface DeliveryOutcome {
    data class Confirmed(val receipt: CompletionReceipt) : DeliveryOutcome
    data object SourceMissing : DeliveryOutcome
    data class ItemFailure(val reason: String) : DeliveryOutcome
    data class PathFailure(val reason: String) : DeliveryOutcome
    data class PeerFailure(val kind: PeerFailureKind, val code: String) : DeliveryOutcome
    data object PairingLost : DeliveryOutcome
}

/**
 * 传输端口。
 *
 * 取消（协程 cancel：暂停 / FGS 被收 / 断网）时实现必须：停掉原生传输 → 同步、不可取消、有界（约 3 秒）地发
 * `flow.suspend`（桌面保持 grant active、半截受保护）→ 再把取消抛出去。**取消绝不发 `flow.cancel`**；
 * 丢弃半截只走显式的 [discardPartial]。
 */
interface ItemDelivery {
    /**
     * 一轮传输的会话：持有 FGS 期间整轮共用一条推送订阅，[block] 返回（或被取消）时关掉。
     * 默认实现什么都不做（测试用的假端口）。
     */
    suspend fun <T> session(block: suspend () -> T): T = block()

    suspend fun deliver(request: DeliveryRequest, onProgress: (bytesSent: Long) -> Unit): DeliveryOutcome

    /** 通知桌面丢掉这一张已传的部分（`flow.cancel_tuple`：用户取消剩余 / 旧版本作废 / 移出范围）。有界等待，不许抛。 */
    suspend fun discardPartial(orderId: Long, pairingEpoch: PairingEpoch)
}

/** 桌面可达探测（`hello`，有超时）。顺带拿到桌面现在的配对代号与健康状况。 */
sealed interface ProbeResult {
    data class Reachable(val advertisedEpoch: String?, val health: DesktopHealth? = null) : ProbeResult
    data object Unreachable : ProbeResult
    data object PairingLost : ProbeResult
}

fun interface DesktopProbe {
    suspend fun probe(): ProbeResult
}

/** 对账：分页问桌面「这些 hash 你还在吗」，返回缺的那些。不可达时抛。 */
fun interface RemotePresence {
    suspend fun missing(hashes: List<String>): Set<String>
}

/** A discovered MediaStore item disappeared; retrying cannot recreate it. */
class SourceMissingException(cause: Throwable? = null) : Exception(cause)

/**
 * FGS + PARTIAL_WAKE_LOCK 的生命周期 = 循环的生命周期（#413）。
 *
 * [acquire] 每轮只调用**一次** `startForegroundService`，然后有界等待服务自己观察到的结论；
 * 被拒 / 超时返回 false，引擎进「等待中」，下一次触发照常再申请（#413：不再持久卡死到回前台）。
 * 暂停、停止、超时这些路径只会调 [release]。
 */
interface ForegroundLease {
    suspend fun acquire(): Boolean

    /** 服务仍在前台（没被系统 onTimeout 收走）。每张开始前检查。 */
    fun isHeld(): Boolean

    /** 有进度就续期 wakelock（它带超时，防止泄漏）。 */
    fun renew()

    fun update(status: LoopStatus)

    fun release()
}

/** 条件不满足时登记的唤醒。 */
interface WakeScheduler {
    /** 桌面不可达：3 个一次性任务，间隔 10 分钟。 */
    fun scheduleUnreachableProbes()

    fun cancelUnreachableProbes()

    /** 条件不满足：一个带相应约束（Wi‑Fi / 电量）的一次性任务。 */
    fun scheduleWhenConditionsMet(reason: WaitReason)
}

/** FGS 受阻的原因。 */
enum class FgsBlockReason { BUDGET_EXHAUSTED, START_REFUSED }

/** 意图（暂停标志）与等待原因的持久存储。 */
interface FlowControl {
    fun paused(): Boolean

    fun setPaused(paused: Boolean)

    /** 持久化的等待原因（[GlobalState.WAITING]）；null = 没在等。进程重启后还在。 */
    fun waitReason(): WaitReason? = null

    fun setWaitReason(reason: WaitReason?) = Unit

    /** 最近一次 FGS 受阻的原因（只给 UI 说人话用，**不是闸门**）；成功拿到 FGS 时清掉。 */
    fun fgsBlock(): FgsBlockReason?

    fun recordFgsBlock(reason: FgsBlockReason)

    fun clearFgsBlock()

    /** MOB-100：「已跳过 N 张…不会再重传」横幅的确认水位（ms）。 */
    fun missingSourceAckAt(): Long

    fun setMissingSourceAckAt(atMs: Long)
}

/** 日志出口。核心不直接碰 android.util.Log（JVM 单测里它会抛）。 */
fun interface FlowLogger {
    fun log(message: String)
}

/** 当前这一张。 */
data class CurrentItem(
    val orderId: Long,
    val fileName: String,
    val bytesSent: Long,
    val totalBytes: Long,
)

enum class LoopPhase { IDLE, CHECKING, RUNNING }

/** 循环的运行态（内存，不持久化）——UI 投影与 FGS 通知读它。 */
data class LoopStatus(
    val phase: LoopPhase = LoopPhase.IDLE,
    val current: CurrentItem? = null,
    val waitReason: WaitReason? = null,
) {
    val running: Boolean get() = phase == LoopPhase.RUNNING
}

/**
 * 「取消剩余 N 张」弹窗那一刻的边界（契约 §3）。[count] 是弹窗上的 N；确认时 [FlowEngine.cancelRemaining]
 * 只把这份边界里的照片写进跳过名单——弹窗之后新拍的照片不在里面。
 */
class RemainingSnapshot internal constructor(
    val count: Int,
    val takenAtMs: Long,
    internal val targets: List<com.hawkeyexb.ppass.backup.order.SkipTarget>,
)
