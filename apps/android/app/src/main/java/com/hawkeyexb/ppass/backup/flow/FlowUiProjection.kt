// ARCH-13 (#417) → ARCH-14 (#418) → #413 W5: 逐张循环的 UI 投影。
//
// 事实源分两类：
//  - 引擎视图 [EngineView]（全局状态、等待原因、待办张数、本轮已完成、当前这一张、桌面健康）——UI 与 FGS 通知
//    读的唯一视图，状态 / 进度 / 待备份 / 按钮全部只看它（#413 §8）；
//  - order 表与 FlowControl 的账目（已确认 m、FAILED、已跳过、源已删、FGS 受阻的具体原因）——英雄区的 m/n
//    与设置卡的几行账目，只在 order 写入（revision）或 MediaStore 变化时重读。
// 本文件全是纯函数，JVM 单测直接可跑；HomeScreen 只做「裁决 → 颜色 / 字符串资源」的映射。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.BackupTriplet
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.backup.order.OrderStore
import com.hawkeyexb.ppass.backup.tripletOf
import com.hawkeyexb.ppass.ui.BackupUiState

/**
 * 首页需要的全部事实。
 *
 * - [view]：引擎视图；null = 还没拿到（运行时未就绪 / 待办还没算出来）。全局状态、待备份、当前这一张都只读它。
 * - [confirmed]：范围内（[FlowProjection.of] 的 bucketIds）当前行为 CONFIRMED、且原图还在的 order 数。
 *   原图删了的 CONFIRMED 行（`source_missing`，#416 裁决 2）不算：它已不在 [inScopeTotal] 里。
 * - [inScopeTotal]：范围内照片总数（MediaStore 实时计数，由调用方传入；null = 读不到）
 * - [failed]：当前行为 FAILED 的 order 数（全量口径，不随范围收窄——UI-16 规则 G4）
 * - [skippedByUser]：范围内当前行为 SKIPPED_BY_USER 的张数（「照片都存好了」的闸门 S3）。
 * - [skippedByUserTotal]：全部当前行为 SKIPPED_BY_USER 的张数（设置卡「已跳过的照片 N 张」）。
 * - [fgsBlock]：FGS 受阻的具体原因（额度用完 / 被拒），只用来挑 [WaitReason.FGS_BLOCKED] 的那句人话。
 */
data class FlowProjection(
    val view: EngineView?,
    val confirmed: Long,
    val inScopeTotal: Long?,
    val failed: Long,
    /** 还没有结局的当前行（PAUSED / QUEUED / TRANSFERRING / FAILED）。 */
    val unfinished: Long = 0L,
    val lastSuccessAt: Long = 0L,
    /** 「无法恢复：N 张照片已从手机相册删除」横幅：确认水位之后新出现的张数。 */
    val missingSourceUnacknowledged: Long = 0L,
    val missingSourceAcknowledged: Long = 0L,
    val fgsBlock: FgsBlockReason? = null,
    val skippedByUser: Long = 0L,
    val skippedByUserTotal: Long = 0L,
) {
    val state: GlobalState get() = view?.state ?: GlobalState.IDLE

    /** 只在 [GlobalState.WAITING] 时非空。 */
    val waitReason: WaitReason? get() = view?.waitReason?.takeIf { state == GlobalState.WAITING }

    /** 当前这一张：只在备份中才有。 */
    val current: CurrentItem? get() = view?.current?.takeIf { state == GlobalState.RUNNING }

    /** 「待备份 K」= 待办大小（#413 §8：唯一来源）。null = 还没算出来。 */
    val remaining: Long? get() = view?.pending?.toLong()

    val paused: Boolean get() = state == GlobalState.PAUSED
    val running: Boolean get() = state == GlobalState.RUNNING

    companion object {
        /**
         * 账目部分（读 order 表与 FlowControl）。[view] 原样带上；引擎视图单独变化时调用方只 `copy(view = …)`，
         * 不必重读这几条计数。
         */
        fun facts(
            store: OrderStore,
            control: FlowControl,
            bucketIds: Set<Long>?,
            inScopeTotal: Long?,
            view: EngineView?,
        ): FlowProjection {
            val scoped = store.countCurrentByState(bucketIds)
            val all = if (bucketIds == null) scoped else store.countCurrentByState(null)
            val ackAt = control.missingSourceAckAt()
            return FlowProjection(
                view = view,
                confirmed = store.countConfirmedPresent(bucketIds),
                inScopeTotal = inScopeTotal,
                failed = all[OrderState.FAILED] ?: 0L,
                unfinished = OrderState.entries.filter { it.isOpen }.sumOf { all[it] ?: 0L },
                lastSuccessAt = store.lastConfirmedAtMs(),
                missingSourceUnacknowledged = store.countSourceMissingSkipped(afterMs = ackAt),
                missingSourceAcknowledged = if (ackAt > 0) store.countSourceMissingSkipped(afterMs = 0L, upToMs = ackAt) else 0L,
                fgsBlock = control.fgsBlock(),
                skippedByUser = scoped[OrderState.SKIPPED_BY_USER] ?: 0L,
                skippedByUserTotal = all[OrderState.SKIPPED_BY_USER] ?: 0L,
            )
        }

        /**
         * 旧签名（AndroidFlowRuntime.flowProjection() 与 Rig 测试用）：由运行态 + 持久的暂停 / 等待原因拼出视图，
         * 再按 [supplementEngineView] 补上待办与检查阶段。[remaining] == null → 视图未知。
         */
        fun of(
            store: OrderStore,
            status: LoopStatus,
            control: FlowControl,
            bucketIds: Set<Long>?,
            inScopeTotal: Long?,
            remaining: Long? = null,
        ): FlowProjection = facts(
            store, control, bucketIds, inScopeTotal,
            view = remaining?.let {
                val base = engineViewOf(status, ViewFacts(paused = control.paused(), waitReason = control.waitReason()))
                supplementEngineView(base, status.phase, it.toInt(), doneThisRound = 0)
            },
        )
    }
}

// ======== W1 接线点：视图补齐 ========
/**
 * W1-M1 的 [FlowEngine.view] 已给出全局状态、等待原因、当前这一张、桌面健康；还没给的两样由 UI 侧补齐：
 * - [EngineView.pending] / [EngineView.doneThisRound]：W1 还没填（恒为 0）。先用引擎的 `remainingSnapshot().count`
 *   与「本轮待办的减少量」补上（见 BackupUiStateHolder 的 EngineViewGateway）；
 * - 检查阶段：引擎在入口检查（[LoopPhase.CHECKING]）时视图仍是 IDLE / WAITING，这里算作备份中，不显示成空闲。
 * W1 填好这两样、并从入口开始就报 RUNNING 之后，本函数与网关里的补齐一起删，UI 直接读 [FlowEngine.view]。
 */
internal fun supplementEngineView(view: EngineView, phase: LoopPhase, pending: Int, doneThisRound: Int): EngineView {
    val state = if (view.state != GlobalState.PAUSED && phase != LoopPhase.IDLE) GlobalState.RUNNING else view.state
    return view.copy(
        state = state,
        waitReason = view.waitReason.takeIf { state == GlobalState.WAITING },
        pending = pending,
        doneThisRound = doneThisRound,
        current = view.current.takeIf { state == GlobalState.RUNNING },
    )
}
// ======== W1 接线点结束 ========

/**
 * 投影 → 首页状态。四个全局状态各有出口（#413 §4）：
 * - 已暂停：[BackupUiState.Paused]；
 * - 备份中：有当前这一张 → [BackupUiState.Sending]，否则（检查 / 准备阶段）→ [BackupUiState.Preparing]；
 * - 等待中：[BackupUiState.Waiting]（带原因）。NOT_PAIRED 不说「等待」——出路是配对失效红卡；
 * - 空闲：有 FAILED 显示 Trouble（点击 = 立即重试一次），范围内每一张都有了结局显示 AllSafe，否则 Idle。
 *
 * Sending 的「第 x / y 张」按本轮算：x = 本轮已完成 + 1，y = 本轮已完成 + 待备份（待备份含正在传的这一张）。
 */
fun backupUiStateOf(p: FlowProjection): BackupUiState {
    val v = p.view
    return when (p.state) {
        GlobalState.PAUSED -> BackupUiState.Paused
        GlobalState.RUNNING -> {
            val current = p.current ?: return BackupUiState.Preparing
            val (done, total) = roundOrdinalOf(v?.doneThisRound ?: 0, v?.pending ?: 0)
            BackupUiState.Sending(done = done, total = total, currentFile = current.fileName)
        }
        GlobalState.WAITING -> p.waitReason?.takeIf { it != WaitReason.NOT_PAIRED }?.let { BackupUiState.Waiting(it) }
            ?: idleUiStateOf(p)
        GlobalState.IDLE -> idleUiStateOf(p)
    }
}

private fun idleUiStateOf(p: FlowProjection): BackupUiState = when {
    // 技术标记，只进「查看技术详情」；主文案是 run_failed（troubleTextOf 是唯一渲染闸门）。
    p.failed > 0 -> BackupUiState.Trouble("flow.failed=${p.failed}")
    flowAllDone(p) -> BackupUiState.AllSafe(ingested = p.confirmed.toInt(), duplicates = 0)
    else -> BackupUiState.Idle
}

/** 本轮的「第 x / y 张」。y 至少是 x：待办刚被别处清零、这一张还没收尾时，不说「第 3 / 2 张」。 */
internal fun roundOrdinalOf(doneThisRound: Int, pending: Int): Pair<Int, Int> {
    val done = doneThisRound.coerceAtLeast(0) + 1
    return done to (doneThisRound.coerceAtLeast(0) + pending.coerceAtLeast(0)).coerceAtLeast(done)
}

/**
 * 「范围内每一张都有了结局」。待办算出来之后以它为准（0 = 没有待传的）；还没算出来时退回计数比较。
 * 无论哪条路，都要求至少确认过一张、且没有未完成的行。
 */
internal fun flowAllDone(p: FlowProjection): Boolean {
    if (p.confirmed <= 0 || p.unfinished != 0L) return false
    return p.remaining?.let { it == 0L } ?: (p.inScopeTotal == null || p.confirmed >= p.inScopeTotal)
}

/**
 * 英雄区三元组。m = 原图还在的已确认数，n = 范围内总数，K = 待办（[EngineView.pending]；还没算出来时退回 n − m）。
 * bucketIds == null（还没选过范围）或 n 读不到 → null，英雄区说「读不到」。
 */
fun flowTripletOf(p: FlowProjection, bucketIds: Set<Long>?): BackupTriplet? {
    if (bucketIds == null) return null
    val n = p.inScopeTotal ?: return null
    return tripletOf(
        n = n,
        confirmedCount = p.confirmed,
        lastSuccessAt = p.lastSuccessAt,
        hasFailedNeedsUser = p.failed > 0L,
        pausedByUser = p.paused,
        remaining = p.remaining,
        skippedByUser = p.skippedByUser,
    )
}

/** MOB-51: the durable command behind the single hero button click — routed on the same projection. */
enum class FlowCommand { Pause, Continue, Retry, Wake }

/** 「继续」只在已暂停，「暂停」只在备份中（#413 §5）；其余按账目重试 / 唤醒。 */
fun flowCommandOf(p: FlowProjection): FlowCommand = when (p.state) {
    GlobalState.PAUSED -> FlowCommand.Continue
    GlobalState.RUNNING -> FlowCommand.Pause
    GlobalState.IDLE, GlobalState.WAITING -> if (p.failed > 0) FlowCommand.Retry else FlowCommand.Wake
}

/** A phone-deleted source was skipped; it is informative and never retryable. */
data class MissingSourceNotice(val count: Int)

fun flowMissingSourceNotice(p: FlowProjection): MissingSourceNotice? =
    p.missingSourceUnacknowledged.takeIf { it > 0 }?.let { MissingSourceNotice(it.toInt()) }

/**
 * 当前这一张的字节进度（千分比）。首页进度条与前台服务通知的进度条共用这一个函数。
 * null = 没在传，或者总字节数未知（通知里画不确定进度条）。
 */
fun transferPermilleOf(current: CurrentItem?): Int? {
    val item = current ?: return null
    if (item.totalBytes <= 0) return null
    return ((item.bytesSent.coerceIn(0, item.totalBytes) * 1000) / item.totalBytes).toInt()
}

/**
 * 设置页「取消剩余 N 张」那一行的 N。只在已暂停 / 等待中出现（#413 §5：备份中先暂停，空闲时没有「剩余」）。
 * null = 这一行不渲染：不在这两个状态、N 还没算出来、没有剩余、或配对已失效（出路是重新扫码，不是取消）。
 * 确认框里的 N 不用它，用点击那一刻的快照（[RemainingSnapshot]）。
 */
fun cancelRemainingRowCount(p: FlowProjection?, pairingLost: Boolean): Long? {
    if (p == null || pairingLost) return null
    if (p.state != GlobalState.PAUSED && p.state != GlobalState.WAITING) return null
    return p.remaining?.takeIf { it > 0 }
}

/**
 * 设置卡「已跳过的照片 N 张 · 点击恢复」那一行的 N（用户取消过的张数）。null = 没有，不渲染。
 * 配对失效时照样显示：它是账目，恢复只改本机，不需要连着电脑。
 */
fun skippedRowCount(p: FlowProjection?): Long? = p?.skippedByUserTotal?.takeIf { it > 0 }

/**
 * 等待原因 → 状态行那句人话（#413 §4 / 契约 §3）。null = 此刻不在等，或者不该在状态行说（NOT_PAIRED：出路在红卡）。
 * FGS 受阻再按 [FlowProjection.fgsBlock] 细分「额度用完」与「被拒」；说不清时用「被拒」那句。
 */
fun waitReasonTextRes(p: FlowProjection): Int? {
    if (p.state != GlobalState.WAITING) return null
    val reason = p.waitReason ?: return null
    return waitReasonTextRes(reason, p.fgsBlock)
}

internal fun waitReasonTextRes(reason: WaitReason, fgsBlock: FgsBlockReason?): Int? = when (reason) {
    WaitReason.NOT_PAIRED -> null
    WaitReason.DISABLED -> R.string.state_waiting_disabled
    WaitReason.WIFI -> R.string.wifi_deferred_hint
    WaitReason.BATTERY -> R.string.state_waiting_battery
    WaitReason.FGS_BLOCKED -> fgsBlockNoticeRes(fgsBlock) ?: R.string.state_background_protection_unknown
    WaitReason.DESKTOP_UNREACHABLE -> R.string.state_waiting_desktop_unreachable
    WaitReason.DESKTOP_STORAGE_FULL -> R.string.state_waiting_desktop_full
    WaitReason.DESKTOP_LIBRARY_UNAVAILABLE -> R.string.state_waiting_desktop_library
    WaitReason.DESKTOP_STORAGE_ERROR -> R.string.state_waiting_desktop_error
}

/**
 * 桌面剩余空间不足 5 GiB 的预警（#413 §7）。已经因为桌面存满而在等时不重复说（状态行说的就是这件事）。
 */
fun desktopLowSpaceWarning(p: FlowProjection?): Boolean {
    val v = p?.view ?: return false
    if (v.desktopHealth?.lowSpace != true) return false
    return p.waitReason != WaitReason.DESKTOP_STORAGE_FULL
}
