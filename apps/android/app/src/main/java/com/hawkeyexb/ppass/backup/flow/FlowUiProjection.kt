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
 * - [confirmed]：范围内当前行为 CONFIRMED、且原图还在的 order 数（读 order 表）。只在待办还没算出来时兜底；
 *   英雄区与「全部完成」读 [done]。
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

    /**
     * 英雄区的 m（#413 裁定：与待办同一套现算差集）= 范围内总数 n − 待办 − 范围内已跳过。不依赖 `source_missing` /
     * bucket 变化的写入：原图删了就不在 n 里，挪出范围也不在 n 里，所以 m 永远不会比 n 大。
     * n 或待办还不知道时退回 order 表的 [confirmed]。
     */
    val done: Long
        get() {
            val n = inScopeTotal ?: return confirmed
            val k = remaining ?: return confirmed
            return (n - k - skippedByUser).coerceIn(0L, n)
        }

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
         * 旧签名（AndroidFlowRuntime.flowProjection() 与 Rig 测试用）：由运行态 + 持久的暂停 / 等待原因 + [remaining]
         * 拼出与 [FlowEngine.view] 同一口径的视图。[remaining] == null → 视图未知。
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
                engineViewOf(status, ViewFacts(paused = control.paused(), waitReason = control.waitReason(), pending = it.toInt()))
            },
        )
    }
}


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
    flowAllDone(p) -> BackupUiState.AllSafe(ingested = p.done.toInt(), duplicates = 0)
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
    // 待办算出来了：它就是唯一口径（范围外的在途行、封顶的失败行已由待办自己决定算不算）。
    p.remaining?.let { k -> if (p.inScopeTotal != null) return k == 0L && p.done > 0 }
    if (p.confirmed <= 0 || p.unfinished != 0L) return false
    return p.remaining?.let { it == 0L } ?: (p.inScopeTotal == null || p.confirmed >= p.inScopeTotal)
}

/**
 * 英雄区三元组。m = [FlowProjection.done]（n − 待办 − 范围内已跳过），n = 范围内总数，K = 待办（[EngineView.pending]；还没算出来时退回 n − m）。
 * bucketIds == null（还没选过范围）或 n 读不到 → null，英雄区说「读不到」。
 */
fun flowTripletOf(p: FlowProjection, bucketIds: Set<Long>?): BackupTriplet? {
    if (bucketIds == null) return null
    val n = p.inScopeTotal ?: return null
    return tripletOf(
        n = n,
        confirmedCount = p.done,
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

// ---------------------------------------------------------------- #250 / #251：当前这一张的那一块
//
// #250：进度条早就是这一张的字节进度（原生 `Progress.end_offset` → 等待循环 500ms 读一次 → 变了才 onProgress →
// LoopStatusCell 每秒最多发一次），但界面上没有文件大小、没有「已传多少」，更没有「字节停了」这件事——
// 慢传输和真停滞看起来一模一样。
// #251：文件名嵌在一整句话里、不限行数，长名字换行，整块区域跟着上下跳。
//
// 这里全是纯函数：停滞判据（标记 + 裁决）、文件名中间截断、字节数文案。时钟由调用方传入（单调时钟）。

/**
 * 字节多久不前进就说「没有新数据」：15 秒。依据：
 *  - 正常传输时，首页看到的字节数最多隔 本地读取 500ms（[LOCAL_STATUS_RECHECK_MS]）+ 刷新节流 1s
 *    （[STATUS_REFRESH_MIN_INTERVAL_MS]）变一次；连接断了走 status 兜底时，读取间隔封顶 8s。15s 在这些
 *    正常空档之上，健康的传输不会闪出「没有新数据」；
 *  - 与等待循环自己「多久没动静就去问桌面」的门槛 [LOCAL_IDLE_STALL_THRESHOLD_MS] 是同一个数——两处对「可疑」
 *    的定义一致；
 *  - 远低于断开重来的门槛 [BYTE_STALL_THRESHOLD_MS]（3 分钟）：引擎放弃之前很久，用户就能看到「在等」，不必去点暂停试探。
 */
internal const val TRANSFER_SLOW_AFTER_MS = LOCAL_IDLE_STALL_THRESHOLD_MS

/**
 * 当前项文件名最多占多少「宽度单位」（ASCII 算 1，中日韩 / 全角 / emoji 算 2）。
 * 首页这一行约 210dp 宽（S24 约 384dp − 卡片内边距 − 右侧「暂停」按钮），13.5sp 的拉丁字符平均约 7dp → 约 30 个；
 * 取 26 留出余量。真超出时 Text 的尾部省略兜底，高度照样不变（单行）。
 */
internal const val TRANSFER_FILE_NAME_MAX_UNITS = 26

/** 停滞判据的标记：这一张（[orderId]）的字节数上一次变成 [bytesSent] 是在 [atMs]（单调时钟）。 */
data class TransferMark(val orderId: Long, val bytesSent: Long, val atMs: Long)

/**
 * 标记的推进。换了一张、第一次看到（包括 App 刚打开、传输早已在进行）、或字节数变了 → 以 [nowMs] 重新打点；
 * 字节数没变 → 原样保留（计时继续累积）。没在传 → null。
 */
fun advanceTransferMark(previous: TransferMark?, current: CurrentItem?, nowMs: Long): TransferMark? {
    val item = current ?: return null
    if (previous == null || previous.orderId != item.orderId || previous.bytesSent != item.bytesSent) {
        return TransferMark(item.orderId, item.bytesSent, nowMs)
    }
    return previous
}

/**
 * 这一张此刻的节奏：
 *  - [MOVING]：字节在前进（或不动还没满 [TRANSFER_SLOW_AFTER_MS]）；
 *  - [SLOW]：字节已经 ≥ 门槛没有前进，但还没传完——界面上必须和正常传输看得出不同（#250 验收 3）；
 *  - [FINISHING]：字节已经全部发出，在等电脑确认收下（算 BLAKE3、入库）——此时字节不动是正常的，不算慢。
 */
enum class TransferPace { MOVING, SLOW, FINISHING }

fun transferPaceOf(
    current: CurrentItem,
    mark: TransferMark?,
    nowMs: Long,
    slowAfterMs: Long = TRANSFER_SLOW_AFTER_MS,
): TransferPace {
    if (current.totalBytes > 0 && current.bytesSent >= current.totalBytes) return TransferPace.FINISHING
    val m = mark?.takeIf { it.orderId == current.orderId && it.bytesSent == current.bytesSent }
        ?: return TransferPace.MOVING
    return if (nowMs - m.atMs >= slowAfterMs) TransferPace.SLOW else TransferPace.MOVING
}

/**
 * 首页「当前这一张」那一块显示的全部东西。
 * - [fileName]：已做中间截断（保住扩展名），单行；
 * - [bytesText]：「12.3 / 189 MB」；总字节未知 → null；
 * - [pace] / [quietSeconds]：节奏，以及字节已经多少秒没动（只在 [TransferPace.SLOW] 时显示）。
 */
data class TransferRow(
    val fileName: String,
    val bytesText: String?,
    val pace: TransferPace,
    val quietSeconds: Int,
)

fun transferRowOf(current: CurrentItem?, mark: TransferMark?, nowMs: Long): TransferRow? {
    val item = current ?: return null
    val quiet = mark?.takeIf { it.orderId == item.orderId && it.bytesSent == item.bytesSent }
        ?.let { ((nowMs - it.atMs).coerceAtLeast(0) / 1000).toInt() } ?: 0
    return TransferRow(
        fileName = middleEllipsize(item.fileName),
        bytesText = bytesProgressText(item.bytesSent, item.totalBytes),
        pace = transferPaceOf(item, mark, nowMs),
        quietSeconds = quiet,
    )
}

private const val ELLIPSIS = "…"

/** 一个码点占几个宽度单位：中日韩 / 谚文 / 全角 / emoji 算 2，其余算 1。 */
internal fun displayUnits(codePoint: Int): Int = when (codePoint) {
    in 0x1100..0x115F, in 0x2E80..0xA4CF, in 0xAC00..0xD7A3, in 0xF900..0xFAFF, in 0xFE30..0xFE4F,
    in 0xFF00..0xFF60, in 0xFFE0..0xFFE6, in 0x1F300..0x1FAFF, in 0x20000..0x3FFFD -> 2
    else -> 1
}

internal fun displayUnits(s: String): Int = s.codePoints().toArray().sumOf { displayUnits(it) }

/**
 * 文件名的中间截断（#251）。Compose 1.7（BOM 2024.12.01，ui-text 1.7.6）的 TextOverflow 只有尾部省略，
 * 没有 MiddleEllipsis；尾部省略会把 `.mp4` / `_161635` 这些信息量最大的部分吃掉，所以在这里按码点截。
 *
 * 规则：不超过 [maxUnits] 原样返回；否则 头 +「…」+ 尾。头尾按剩余宽度对半分（多出的一个单位给尾部）；
 * 扩展名（`.` 之后 1–8 个字符）比半边还长时，尾部放宽到正好装下扩展名。按码点截，不会切开代理对 / emoji。
 */
fun middleEllipsize(name: String, maxUnits: Int = TRANSFER_FILE_NAME_MAX_UNITS): String {
    if (displayUnits(name) <= maxUnits) return name
    val cps = name.codePoints().toArray()
    val budget = (maxUnits - 1).coerceAtLeast(2) // 一个单位留给「…」
    val dot = name.lastIndexOf('.')
    val extUnits = if (dot > 0 && name.length - dot - 1 in 1..8) displayUnits(name.substring(dot)) else 0
    var tailBudget = budget - budget / 2
    if (extUnits > tailBudget && extUnits <= budget - 1) tailBudget = extUnits
    val headBudget = budget - tailBudget

    val head = StringBuilder()
    var used = 0
    for (cp in cps) {
        val w = displayUnits(cp)
        if (used + w > headBudget) break
        head.appendCodePoint(cp)
        used += w
    }
    val tail = ArrayDeque<Int>()
    used = 0
    for (k in cps.indices.reversed()) {
        val w = displayUnits(cps[k])
        if (used + w > tailBudget) break
        tail.addFirst(cps[k])
        used += w
    }
    val tailText = StringBuilder().also { sb -> tail.forEach { sb.appendCodePoint(it) } }
    return "$head$ELLIPSIS$tailText"
}

/**
 * 「已传 / 总大小」（#250），例如「12.3 / 189 MB」。单位按**总大小**选、两边同一个单位（不说「900 KB / 189 MB」）；
 * 十进制（1 MB = 1000 × 1000 字节），与 Android 系统显示文件大小的口径一致（API 26 起 `Formatter` 用 SI）。
 * 数值小于 100 保留一位小数，否则取整；0 就写「0」。总大小未知 → null。
 */
fun bytesProgressText(bytesSent: Long, totalBytes: Long): String? {
    if (totalBytes <= 0) return null
    val (divisor, unit) = when {
        totalBytes >= 1_000_000_000L -> 1e9 to "GB"
        totalBytes >= 1_000_000L -> 1e6 to "MB"
        else -> 1e3 to "KB"
    }
    fun fmt(v: Long): String {
        if (v <= 0) return "0"
        val x = v / divisor
        return String.format(java.util.Locale.ROOT, if (x >= 100) "%.0f" else "%.1f", x)
    }
    return "${fmt(bytesSent.coerceIn(0, totalBytes))} / ${fmt(totalBytes)} $unit"
}
