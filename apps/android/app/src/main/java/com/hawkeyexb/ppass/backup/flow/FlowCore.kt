// ARCH-13 (#417): 逐张循环的核心类型与端口。本文件不碰任何 Android API，JVM 单测直接可跑。
//
// 模型（#413 正文「循环」一节）：
//   触发 → worker 里检查条件（不持有 FGS）→ 申请 FGS + PARTIAL_WAKE_LOCK →
//   取件 ① 未完成 order → ② 慢路径标记的 QUEUED → ③ 快路径下一张 → 传输 → 下一张 → 释放。
// 没有物化队列、没有发现水位、没有取消轮；「对哪张照片做过决定」全部落在 order 表上。
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
 * 触发原因。三个维度：
 * - [userPresent]：人在场（打开 App、改范围、点继续、手动）——不查后台开关、不查电量（MOB-19 / NET-06）。
 *   仅 Wi‑Fi 对所有触发都生效（MOB-76）。
 * - [slowPath]：这次要跑慢路径（#413：5h 兜底、App 打开、新增相册；`getVersion` 变化另行检测）。
 */
enum class TriggerReason(val userPresent: Boolean = false, val slowPath: Boolean = false) {
    MEDIA_CHANGE,
    PROCESS_START,
    NETWORK_CHANGE,
    UNREACHABLE_PROBE,
    CONSTRAINTS_MET,
    PERIODIC(slowPath = true),
    APP_FOREGROUND(userPresent = true, slowPath = true),
    SCOPE_ADDED(userPresent = true, slowPath = true),
    PAIRING_REPAIRED(userPresent = true, slowPath = true),
    USER_CONTINUE(userPresent = true),
    RETRY_FAILED(userPresent = true, slowPath = true),
    MANUAL(userPresent = true),
}

/** 循环为什么没在跑 / 为什么停了。null = 没有等待（空闲或正在传）。 */
enum class WaitReason {
    NOT_PAIRED,
    DISABLED,
    WIFI,
    BATTERY,
    /** FGS 被拒或超时（今天额度用完）：App 回到前台之前不再申请（#414）。 */
    FGS_BLOCKED,
    DESKTOP_UNREACHABLE,
    /** 桌面明确回报无法保存（`storage_failed`）：等下一次唤醒（#415 裁决 3）。 */
    PEER_REFUSED,
}

/** 一次检查所需的全部条件事实。由 Android 层实时读取，这里只做判断。 */
data class Conditions(
    val paired: Boolean = true,
    val autoBackupEnabled: Boolean = true,
    val wifiOnly: Boolean = false,
    val onUnmetered: Boolean = true,
    val batteryLow: Boolean = false,
    val fgsBlocked: Boolean = false,
)

/**
 * worker 里的条件检查（不含暂停——暂停是更早、更硬的一道闸；不含桌面可达——那要走网络）。
 * 纯函数，C-04 的判据本体。
 */
fun waitReasonOf(conditions: Conditions, userPresent: Boolean): WaitReason? = when {
    !conditions.paired -> WaitReason.NOT_PAIRED
    !userPresent && !conditions.autoBackupEnabled -> WaitReason.DISABLED
    conditions.wifiOnly && !conditions.onUnmetered -> WaitReason.WIFI
    !userPresent && conditions.batteryLow -> WaitReason.BATTERY
    conditions.fgsBlocked -> WaitReason.FGS_BLOCKED
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
 * 一次传输的结局，按 #410 / #415 裁决 3 分类：
 * - [ItemFailure]：这一张的问题（读不出、hash 对不上、桌面拒收这条请求）——立即重试 1 次，仍失败记 FAILED、计次数。
 * - [PathFailure]：路走不通（不可达、握手失败、3 分钟无新字节、`fetch_failed`）——order 保持可续传，退出循环，不计次数。
 * - [PeerFailure]：桌面明确说存不下（`storage_failed`）——退出循环，不计次数。
 */
sealed interface DeliveryOutcome {
    data class Confirmed(val receipt: CompletionReceipt) : DeliveryOutcome
    data object SourceMissing : DeliveryOutcome
    data class ItemFailure(val reason: String) : DeliveryOutcome
    data class PathFailure(val reason: String) : DeliveryOutcome
    data class PeerFailure(val code: String) : DeliveryOutcome
    data object PairingLost : DeliveryOutcome
}

/** 传输端口。取消（协程 cancel）时实现必须停掉原生传输再把取消抛出去。 */
interface ItemDelivery {
    suspend fun deliver(request: DeliveryRequest, onProgress: (bytesSent: Long) -> Unit): DeliveryOutcome

    /** 通知桌面丢掉这一张已传的部分（用户取消 / 移出范围）。尽力而为，不许抛。 */
    fun discardPartial(orderId: Long, pairingEpoch: PairingEpoch)
}

/** 桌面可达探测（`hello`，有超时）。顺带拿到桌面现在的配对代号。 */
sealed interface ProbeResult {
    data class Reachable(val advertisedEpoch: String?) : ProbeResult
    data object Unreachable : ProbeResult
    data object PairingLost : ProbeResult
}

fun interface DesktopProbe {
    suspend fun probe(): ProbeResult
}

/** 慢路径第 2 步：分页问桌面「这些 hash 你还在吗」，返回缺的那些。不可达时抛。 */
fun interface RemotePresence {
    suspend fun missing(hashes: List<String>): Set<String>
}

/** 按 media_id 算整文件 BLAKE3。原图没了抛 [SourceMissingException]。 */
fun interface ContentHasher {
    fun hash(mediaId: Long): String
}

/** A discovered MediaStore item disappeared; retrying cannot recreate it. */
class SourceMissingException(cause: Throwable? = null) : Exception(cause)

/**
 * FGS + PARTIAL_WAKE_LOCK 的生命周期 = 循环的生命周期（#413）。
 *
 * [acquire] 只调用**一次** `startForegroundService`，然后有界等待服务自己观察到的结论；
 * 被拒 / 超时返回 false，由引擎记下持久事实（#414）。暂停、停止、超时这些路径只会调 [release]。
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

/** 用户控制与 FGS 受阻事实的持久存储。 */
interface FlowControl {
    fun paused(): Boolean

    fun setPaused(paused: Boolean)

    fun fgsBlock(): FgsBlockReason?

    fun recordFgsBlock(reason: FgsBlockReason)

    /** App 进入前台时清除（前台会重置 dataSync 额度，#411）。 */
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
