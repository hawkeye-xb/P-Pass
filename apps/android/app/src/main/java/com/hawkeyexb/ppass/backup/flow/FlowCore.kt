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

    /**
     * App 在前台时 MediaStore 变了（首页的 ContentObserver）：人在场，不查后台开关——「后台备份」关着时
     * MediaWatchJob 不注册，只有这条路能兑现「打开 P-Pass 时照常备份」。
     */
    FOREGROUND_MEDIA_CHANGE(userPresent = true),

    /** #439：等待中（桌面不可达）时，前台心跳又连上了桌面。只由前台心跳发出，人在场。 */
    DESKTOP_REACHABLE(userPresent = true),

    /**
     * #522：额度确定耗尽时登记的一次性唤醒，到点 = 系统复位点之后（见 [FgsBudgetDecision.wakeAtElapsedMs]）。
     * 后台触发、带对账：耗尽那一刻还没传完的照片（含对账才扫得到的）这一轮接着传。
     */
    BUDGET_RESET(reconcile = true),
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
    // #555：盘满时 daemon 的写入探针以 ENOSPC 失败，健康报告里同样是
    // libraryWritable=false——「文件夹打不开」与「盘满了」曾因此共用一个
    // 等待原因。空间事实在 freeBytes 里：低于保留余量归为空间不足。
    !health.libraryWritable && health.criticallyLow -> WaitReason.DESKTOP_STORAGE_FULL
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

    /**
     * #522：额度确定耗尽——[delayMs] 后一次性唤醒（[TriggerReason.BUDGET_RESET]）。唯一名、新的替换旧的：
     * 新一次耗尽的窗口起点只会更晚，旧唤醒若早于新复位点，到点会被跳过且不再登记。
     */
    fun scheduleBudgetResetWake(delayMs: Long) = Unit

    /** #522：回过前台（额度会在下一次 startForeground 时复位），撤掉那个唤醒。 */
    fun cancelBudgetResetWake() = Unit
}

/** FGS 受阻的原因。 */
enum class FgsBlockReason { BUDGET_EXHAUSTED, START_REFUSED }

/**
 * #522：一个「系统时钟上的时刻」——开机序号（`Settings.Global.BOOT_COUNT`）+ 开机以来的时长
 * （`SystemClock.elapsedRealtime`，系统 24h 窗口用的就是这个钟）。开机序号不同 = 不是同一次开机，时长不可比。
 */
data class BootInstant(val bootCount: Int, val elapsedMs: Long)

/**
 * #522：dataSync 额度的两条系统事实（持久化，见 [FlowControl.fgsBudgetFacts]）。
 * - [lastGrantAt]：最近一次 `startForeground` 成功的时刻 ≈ 系统 `TimeLimitedFgsInfo.mFirstFgsStartRealtime`
 *   （并行数 0→1 时覆盖；被拒的申请在预检阶段就抛，不更新它）。
 * - [exhaustedRefusalAt]：系统明确说「Time limit already exhausted」的时刻；之后成功一次就清。
 */
data class FgsBudgetFacts(
    val lastGrantAt: BootInstant? = null,
    val exhaustedRefusalAt: BootInstant? = null,
)

/** 系统复位额度的窗口（AOSP android15 `ActiveServices`：最近一次会话开始距今超过 24h 就在 startForeground 时复位）。 */
internal const val FGS_BUDGET_RESET_WINDOW_MS = 24 * 60 * 60 * 1000L

/** 我们记下的授予时刻比系统的晚几毫秒；再留一分钟余量，偏差一律落在「多试一次」那边。 */
internal const val FGS_BUDGET_RESET_MARGIN_MS = 60_000L

/**
 * #522：有「确定被拒」记录时的判定。[skip] = 这次后台触发跳过申请；[why] 写进日志（不跳过时说明为什么仍去申请）。
 * [wakeAtElapsedMs]（只在 skip 时有）：系统复位点之后的时刻 = 最近一次成功授予 + 24h + 余量，一次性唤醒定在这里。
 */
internal data class FgsBudgetDecision(val skip: Boolean, val why: String, val wakeAtElapsedMs: Long? = null)

/**
 * #522：后台触发要不要跳过 `startForegroundService`。null = 没有「确定被拒」的记录，照常申请、不必说明。
 *
 * 只在下面全部成立时跳过——任何一条拿不准都照常申请（最多白申请一次，绝不错过恢复后的第一次）：
 *  1. 系统**明确**拒绝过（消息含 "Time limit"，见 [FlowControl.recordBudgetRefusal]）。onTimeout 不算：
 *     AOSP 在 `enableFgsTimeoutCrashBehavior` 关闭时下一次 startForeground 会直接复位，onTimeout 之后不一定被拒；
 *  2. 读得到系统时钟，且最近一次成功授予、拒绝、现在三者是同一次开机（重启会清掉 system_server 里的额度账）；
 *  3. 拒绝之后 App 没回过前台（[lastForegroundAt]，对应 AOSP 的 `lastTopTime > lastTimeOutAt`）。
 *     持久化的复位走 [FlowControl.clearBudgetRefusal]；这里再看一眼进程内的事实，引擎当时没起来也不会漏；
 *  4. 现在还在「最近一次授予 + 24h − 余量」之内（过了这个点系统会复位，下一次必须真去申请）。
 */
internal fun fgsBudgetDecision(facts: FgsBudgetFacts, now: BootInstant?, lastForegroundAt: BootInstant? = null): FgsBudgetDecision? {
    val refusal = facts.exhaustedRefusalAt ?: return null
    fun request(why: String) = FgsBudgetDecision(skip = false, why = why)
    if (now == null) return request("system clock (BOOT_COUNT) unavailable")
    val grant = facts.lastGrantAt ?: return request("start of the system window unknown (no successful start on record)")
    if (refusal.bootCount != now.bootCount || grant.bootCount != now.bootCount) return request("device rebooted since")
    if (refusal.elapsedMs < grant.elapsedMs || now.elapsedMs < refusal.elapsedMs) return request("inconsistent timestamps")
    if (lastForegroundAt != null && lastForegroundAt.bootCount == now.bootCount && lastForegroundAt.elapsedMs >= refusal.elapsedMs) {
        return request("app came to the foreground since")
    }
    val resetAt = grant.elapsedMs + FGS_BUDGET_RESET_WINDOW_MS - FGS_BUDGET_RESET_MARGIN_MS
    if (now.elapsedMs >= resetAt) return request("past the system reset point (last successful start + 24h)")
    return FgsBudgetDecision(
        wakeAtElapsedMs = grant.elapsedMs + FGS_BUDGET_RESET_WINDOW_MS + FGS_BUDGET_RESET_MARGIN_MS,
        skip = true,
        why = "dataSync budget exhausted (system refused with 'Time limit' ${(now.elapsedMs - refusal.elapsedMs) / 1000}s ago), " +
            "app not in the foreground since; system resets in ${(resetAt - now.elapsedMs) / 60_000}min",
    )
}

/** [fgsBudgetDecision] 的简写：跳过时返回原因，否则 null。 */
internal fun fgsBudgetSkipReason(facts: FgsBudgetFacts, now: BootInstant?, lastForegroundAt: BootInstant? = null): String? =
    fgsBudgetDecision(facts, now, lastForegroundAt)?.takeIf { it.skip }?.why

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

    /**
     * #522：额度事实（**落盘**）。系统的额度账记在 system_server 里、按 uid 保存，我们的进程被杀重启后它还在，
     * 所以「确定被拒」也要跨进程保留；重启设备会清掉系统的账，靠 [BootInstant.bootCount] 识别。
     */
    fun fgsBudgetFacts(): FgsBudgetFacts = FgsBudgetFacts()

    /** 服务 `startForeground` 成功：记下时刻（系统 24h 窗口的起点），并清掉「确定被拒」。 */
    fun recordFgsGrant(at: BootInstant?) = Unit

    /** 系统明确说额度耗尽（"Time limit already exhausted"）。 */
    fun recordBudgetRefusal(at: BootInstant?) = Unit

    /** App 回过前台（系统会在下一次 startForeground 时复位额度）：不再跳过。返回之前是否记着。 */
    fun clearBudgetRefusal(): Boolean = false

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
