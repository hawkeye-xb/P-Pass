// ARCH-13 (#417) → ARCH-14 (#418): 逐张循环的 UI 投影。取代 DiscoveryLedgerSnapshot → UI 的那一套。
//
// 事实源只有四个：order 表（计数）、循环的运行态（当前这一张、等待原因）、FlowControl（暂停、FGS 受阻），
// 以及引擎按 [FlowEngine.countRemaining] 现算的「还没有结局的张数」。本文件全是纯函数，JVM 单测直接可跑；
// HomeScreen / 前台服务通知只做「裁决 → 颜色 / 字符串资源」的映射。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.BackupTriplet
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.backup.order.OrderStore
import com.hawkeyexb.ppass.backup.tripletOf
import com.hawkeyexb.ppass.ui.BackupUiState

/**
 * 首页需要的全部事实。
 *
 * - [confirmed]：范围内（[FlowProjection.of] 的 bucketIds）当前行为 CONFIRMED、且原图还在的 order 数。
 *   原图删了的 CONFIRMED 行（`source_missing`，#416 裁决 2）不算：它已不在 [inScopeTotal] 里。
 * - [inScopeTotal]：范围内照片总数（MediaStore 实时计数，由调用方传入；null = 读不到）
 * - [current]：当前这一张的进度（字节）；null = 没在传
 * - [waitReason]：等待原因；null = 没在等
 * - [paused]：用户暂停
 * - [failed]：当前行为 FAILED 的 order 数（全量口径，不随范围收窄——UI-16 规则 G4）
 * - [remaining]：「取消剩余 N 张」的 N，也是英雄区的「待备份 K」——与引擎取消时写 SKIPPED_BY_USER 的
 *   是同一个函数（范围内还没有 order 的照片 + 还没结局的当前行，含 FAILED）。null = 还没算出来。
 * - [skippedByUser]：范围内当前行为 SKIPPED_BY_USER 的张数（「照片都存好了」的闸门 S3）。
 * - [skippedByUserTotal]：全部当前行为 SKIPPED_BY_USER 的张数（设置卡「已跳过的照片 N 张」，
 *   与「点击恢复」删掉的是同一批行）。
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
    /** 「无法恢复：N 张照片已从手机相册删除」横幅：确认水位之后新出现的张数。 */
    val missingSourceUnacknowledged: Long = 0L,
    val missingSourceAcknowledged: Long = 0L,
    val fgsBlock: FgsBlockReason? = null,
    val skippedByUser: Long = 0L,
    val remaining: Long? = null,
    val skippedByUserTotal: Long = 0L,
) {
    companion object {
        /** 纯函数：从事实源拼出投影。 */
        fun of(
            store: OrderStore,
            status: LoopStatus,
            control: FlowControl,
            bucketIds: Set<Long>?,
            inScopeTotal: Long?,
            remaining: Long? = null,
        ): FlowProjection {
            val scoped = store.countCurrentByState(bucketIds)
            val all = if (bucketIds == null) scoped else store.countCurrentByState(null)
            val ackAt = control.missingSourceAckAt()
            return FlowProjection(
                confirmed = store.countConfirmedPresent(bucketIds),
                inScopeTotal = inScopeTotal,
                current = status.current.takeIf { status.running },
                // 循环自己报的等待原因优先：Wi‑Fi 与 FGS 受阻同时成立时，说的是正在挡路的那一个。
                waitReason = status.waitReason ?: control.fgsBlock()?.let { WaitReason.FGS_BLOCKED },
                paused = control.paused(),
                failed = all[OrderState.FAILED] ?: 0L,
                running = status.running,
                unfinished = OrderState.entries.filter { it.isOpen }.sumOf { all[it] ?: 0L },
                lastSuccessAt = store.lastConfirmedAtMs(),
                missingSourceUnacknowledged = store.countSourceMissingSkipped(afterMs = ackAt),
                missingSourceAcknowledged = if (ackAt > 0) store.countSourceMissingSkipped(afterMs = 0L, upToMs = ackAt) else 0L,
                fgsBlock = control.fgsBlock(),
                skippedByUser = scoped[OrderState.SKIPPED_BY_USER] ?: 0L,
                remaining = remaining,
                skippedByUserTotal = all[OrderState.SKIPPED_BY_USER] ?: 0L,
            )
        }
    }
}

/**
 * 投影 → 首页状态机。暂停压过一切；在传显示当前文件；等条件显示等待；有 FAILED 且没在跑显示
 * Trouble（点击 = 立即重试一次）；范围内每一张都有了结局显示 AllSafe。
 *
 * Sending 的 done 是「正在传的这一张是第几张」= 已确认 + 1（封顶到总数），不是旧的「本轮第 x 张」。
 */
fun backupUiStateOf(p: FlowProjection): BackupUiState {
    val total = p.inScopeTotal ?: (p.confirmed + p.unfinished)
    return when {
        p.paused -> BackupUiState.Paused
        p.running -> BackupUiState.Sending(
            done = (p.confirmed + 1).coerceAtMost(total).toInt(),
            total = total.toInt(),
            currentFile = p.current?.fileName.orEmpty(),
        )
        p.waitReason != null && p.waitReason != WaitReason.NOT_PAIRED -> BackupUiState.WaitingForConstraints
        // 技术标记，只进「查看技术详情」；主文案是 run_failed（troubleTextOf 是唯一渲染闸门）。
        p.failed > 0 -> BackupUiState.Trouble("flow.failed=${p.failed}")
        flowAllDone(p) -> BackupUiState.AllSafe(ingested = p.confirmed.toInt(), duplicates = 0)
        else -> BackupUiState.Idle
    }
}

/**
 * 「范围内每一张都有了结局」。[FlowProjection.remaining] 算出来之后以它为准（0 = 没有待传的）；
 * 还没算出来时退回计数比较。无论哪条路，都要求至少确认过一张、且没有未完成的行。
 */
internal fun flowAllDone(p: FlowProjection): Boolean {
    if (p.confirmed <= 0 || p.unfinished != 0L) return false
    return p.remaining?.let { it == 0L } ?: (p.inScopeTotal == null || p.confirmed >= p.inScopeTotal)
}

/**
 * 英雄区三元组。m = 原图还在的已确认数，n = 范围内总数，K = [FlowProjection.remaining]
 * （还没算出来时退回 n − m）。bucketIds == null（还没选过范围）或 n 读不到 → null，英雄区说「读不到」。
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
 * 当前这一张的字节进度（千分比）。首页进度条与前台服务通知的进度条共用这一个函数。
 * null = 没在传，或者总字节数未知（通知里画不确定进度条）。
 */
fun transferPermilleOf(current: CurrentItem?): Int? {
    val item = current ?: return null
    if (item.totalBytes <= 0) return null
    return ((item.bytesSent.coerceIn(0, item.totalBytes) * 1000) / item.totalBytes).toInt()
}

/**
 * 设置页「取消剩余 N 张」那一行的 N。null = 这一行不渲染：N 还没算出来、没有剩余、或配对已失效
 * （配对失效时出路是重新扫码，不是取消）。
 */
fun cancelRemainingRowCount(p: FlowProjection?, pairingLost: Boolean): Long? =
    p?.remaining?.takeIf { it > 0 && !pairingLost }

/**
 * 设置卡「已跳过的照片 N 张 · 点击恢复」那一行的 N（用户取消过的张数）。null = 没有，不渲染。
 * 配对失效时照样显示：它是账目，恢复只改本机 order 表，不需要连着电脑。
 */
fun skippedRowCount(p: FlowProjection?): Long? = p?.skippedByUserTotal?.takeIf { it > 0 }

/**
 * FGS 受阻的人话。只在循环此刻确实因为 FGS 受阻而等待时给出（[WaitReason.FGS_BLOCKED]）：
 * Wi‑Fi 不满足时不说额度的事；用户暂停时暂停压过一切。
 */
fun fgsBlockWaitNoticeRes(p: FlowProjection): Int? =
    p.fgsBlock?.takeIf { p.waitReason == WaitReason.FGS_BLOCKED && !p.paused }?.let(::fgsBlockNoticeRes)
