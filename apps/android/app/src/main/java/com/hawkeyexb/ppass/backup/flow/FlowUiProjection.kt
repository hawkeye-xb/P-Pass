// ARCH-13 (#417): 逐张循环的 UI 投影。取代 DiscoveryLedgerSnapshot → UI 的那一套。
//
// 事实源只有三个：order 表（计数）、循环的运行态（当前这一张、等待原因）、FlowControl（暂停、FGS 受阻）。
// UI 行为改动属于 #418；这里提供 #417 约定的最小投影，并把它映射回首页现有的 BackupUiState，
// 让 App 在 #418 之前能编译运行。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.backup.order.OrderStore
import com.hawkeyexb.ppass.ui.BackupUiState

/**
 * 首页需要的全部事实（#417 约定的投影 API，交接给 #418）。
 *
 * - [confirmed]：范围内（[FlowProjection.of] 的 bucketIds）当前行为 CONFIRMED 的 order 数
 * - [inScopeTotal]：范围内照片总数（MediaStore 实时计数，由调用方传入；null = 读不到）
 * - [current]：当前这一张的进度（字节）；null = 没在传
 * - [waitReason]：等待原因；null = 没在等
 * - [paused]：用户暂停
 * - [failed]：当前行为 FAILED 的 order 数（全量口径，不随范围收窄——UI-16 规则 G4）
 */
data class FlowProjection(
    val confirmed: Long,
    val inScopeTotal: Long?,
    val current: CurrentItem?,
    val waitReason: WaitReason?,
    val paused: Boolean,
    val failed: Long,
    val running: Boolean = current != null,
    /** 还没有结局的当前行（PAUSED / QUEUED / TRANSFERRING / FAILED）。 */
    val unfinished: Long = 0L,
    val lastSuccessAt: Long = 0L,
    /** 「已跳过 N 张（原图已删）」横幅：确认水位之后新出现的张数。 */
    val missingSourceUnacknowledged: Long = 0L,
    val missingSourceAcknowledged: Long = 0L,
    val fgsBlock: FgsBlockReason? = null,
) {
    companion object {
        /** 纯函数：从三个事实源拼出投影。 */
        fun of(
            store: OrderStore,
            status: LoopStatus,
            control: FlowControl,
            bucketIds: Set<Long>?,
            inScopeTotal: Long?,
        ): FlowProjection {
            val scoped = store.countCurrentByState(bucketIds)
            val all = if (bucketIds == null) scoped else store.countCurrentByState(null)
            val ackAt = control.missingSourceAckAt()
            return FlowProjection(
                confirmed = scoped[OrderState.CONFIRMED] ?: 0L,
                inScopeTotal = inScopeTotal,
                current = status.current.takeIf { status.running },
                waitReason = status.waitReason ?: control.fgsBlock()?.let { WaitReason.FGS_BLOCKED },
                paused = control.paused(),
                failed = all[OrderState.FAILED] ?: 0L,
                running = status.running,
                unfinished = OrderState.entries.filter { it.isOpen }.sumOf { all[it] ?: 0L },
                lastSuccessAt = store.lastConfirmedAtMs(),
                missingSourceUnacknowledged = store.countSourceMissingSkipped(afterMs = ackAt),
                missingSourceAcknowledged = if (ackAt > 0) store.countSourceMissingSkipped(afterMs = 0L, upToMs = ackAt) else 0L,
                fgsBlock = control.fgsBlock(),
            )
        }
    }
}

/**
 * 投影 → 首页现有的状态机（最小兼容映射，#418 会重做）。暂停压过一切；在传显示当前文件；
 * 等条件显示等待；有 FAILED 且没在跑显示 Trouble（点击 = 立即重试一次）；全部确认显示 AllSafe。
 */
fun backupUiStateOf(p: FlowProjection): BackupUiState {
    val total = p.inScopeTotal?.toInt() ?: (p.confirmed + p.unfinished).toInt()
    return when {
        p.paused -> BackupUiState.Paused
        p.running -> BackupUiState.Sending(done = p.confirmed.toInt(), total = total, currentFile = p.current?.fileName.orEmpty())
        p.waitReason != null && p.waitReason != WaitReason.NOT_PAIRED -> BackupUiState.WaitingForConstraints
        p.failed > 0 -> BackupUiState.Trouble("${p.failed} photos failed; the next check retries them")
        p.confirmed > 0 && p.unfinished == 0L && (p.inScopeTotal == null || p.confirmed >= p.inScopeTotal) ->
            BackupUiState.AllSafe(ingested = p.confirmed.toInt(), duplicates = 0)
        else -> BackupUiState.Idle
    }
}

/** MOB-51: the durable command behind the single hero button click — routed on the same projection. */
enum class FlowCommand { Pause, Continue, Retry, Wake }

fun flowCommandOf(p: FlowProjection): FlowCommand = when {
    p.paused -> FlowCommand.Continue
    p.running -> FlowCommand.Pause
    p.failed > 0 -> FlowCommand.Retry
    else -> FlowCommand.Wake
}

/** A phone-deleted source was skipped; it is informative and never retryable. */
data class MissingSourceNotice(val count: Int)

fun flowMissingSourceNotice(p: FlowProjection): MissingSourceNotice? =
    p.missingSourceUnacknowledged.takeIf { it > 0 }?.let { MissingSourceNotice(it.toInt()) }

/**
 * MOB-59 的「已跳过的照片」恢复入口。#415 裁决 4：SKIPPED_BY_USER 这次**不提供恢复入口**，
 * 所以投影恒为 null（类型保留给 HomeScreen，#418 决定去留）。
 */
data class CancelledRoundNotice(val count: Int)

/** 首页进度条：#413「已确认的 order 数 / 范围内的照片总数」。 */
data class RoundProgress(val done: Long, val total: Long)

fun roundProgressOf(p: FlowProjection): RoundProgress? =
    p.inScopeTotal?.let { RoundProgress(done = p.confirmed.coerceAtMost(it), total = it) }
