// #418 回归：FGS 通知与首页英雄区的刷新闸门。
//
// 之前：每个进度回调都直接 `foreground.update(...)`，而进度回调跟着等待循环 500ms 一拍的本地读取走——
// 传输期间约 2 次/秒 `notify(2026, …)`，首页投影（要读 order 表计数）也跟着 2 次/秒重算。
// 现在：引擎的运行态只在「值变了」时才往外发，而且只有一个出口（[LoopStatusCell.display]）：
//  - 阶段 / 当前是哪张 / 等待原因变了 → 立即发；
//  - 只有「这一张的字节数」变了 → 每 [STATUS_REFRESH_MIN_INTERVAL_MS] 最多发一次，窗口内被压下的那次
//    在窗口结束时补发最新值（否则字节停下时通知会停在旧进度上）；
//  - 值没变 → 不发。
// 通知（FGS）与首页都读这个出口，两处的刷新语义是同一个。
package com.hawkeyexb.ppass.backup.flow

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** 字节进度刷新的最小间隔：通知与首页每秒最多刷新一次字节数。 */
internal const val STATUS_REFRESH_MIN_INTERVAL_MS = 1_000L

/** 刷新闸门的纯判定。不持有线程、不碰时钟，时间由调用方传进来。 */
internal class StatusRefreshGate(
    private val minIntervalMs: Long = STATUS_REFRESH_MIN_INTERVAL_MS,
    initial: LoopStatus = LoopStatus(),
) {
    sealed interface Decision {
        /** 与上一次发出去的值相同：不刷新。 */
        data object Skip : Decision

        data object Now : Decision

        /** 只有字节数变了、还在节流窗口里：[delayMs] 之后再看。 */
        data class Later(val delayMs: Long) : Decision
    }

    private var published: LoopStatus = initial
    private var publishedAtMs: Long? = null

    fun offer(next: LoopStatus, nowMs: Long): Decision {
        val last = published
        if (next == last) return Decision.Skip
        if (!isBytesOnlyChange(last, next)) return Decision.Now
        val since = publishedAtMs ?: return Decision.Now
        val wait = since + minIntervalMs - nowMs
        return if (wait <= 0) Decision.Now else Decision.Later(wait)
    }

    fun markPublished(status: LoopStatus, nowMs: Long) {
        published = status
        publishedAtMs = nowMs
    }
}

/** 同一阶段、同一张、同一等待原因，只有 bytesSent 不同。 */
internal fun isBytesOnlyChange(a: LoopStatus, b: LoopStatus): Boolean {
    val ca = a.current ?: return false
    val cb = b.current ?: return false
    return a.phase == b.phase && a.waitReason == b.waitReason && ca.copy(bytesSent = 0) == cb.copy(bytesSent = 0)
}

/**
 * 引擎运行态的存放处：[value] / [update] 写原始值（引擎内部判断用，[raw] 每次都是最新），
 * 写完经 [StatusRefreshGate] 决定是否发到 [display] 并调 [publish]（FGS 通知）。
 *
 * 线程：写入可能来自写者线程（阶段切换）也可能来自 IO 线程（进度回调），所以判定与发布整体加锁。
 * 补发任务跑在 [scope] 上；任何一次立即发布都会取消它，旧的 RUNNING 快照不会在 IDLE 之后落地。
 */
internal class LoopStatusCell(
    private val scope: CoroutineScope,
    private val publish: (LoopStatus) -> Unit,
    private val now: () -> Long,
    minIntervalMs: Long = STATUS_REFRESH_MIN_INTERVAL_MS,
) {
    private val rawFlow = MutableStateFlow(LoopStatus())
    private val shown = MutableStateFlow(LoopStatus())
    private val gate = StatusRefreshGate(minIntervalMs)
    private val lock = Any()
    private var trailing: Job? = null

    val raw: StateFlow<LoopStatus> = rawFlow.asStateFlow()
    val display: StateFlow<LoopStatus> = shown.asStateFlow()

    var value: LoopStatus
        get() = rawFlow.value
        set(next) {
            rawFlow.value = next
            refresh()
        }

    fun update(transform: (LoopStatus) -> LoopStatus) {
        rawFlow.update(transform)
        refresh()
    }

    private fun refresh() {
        synchronized(lock) {
            val latest = rawFlow.value
            val at = now()
            when (val decision = gate.offer(latest, at)) {
                StatusRefreshGate.Decision.Skip -> Unit
                StatusRefreshGate.Decision.Now -> {
                    trailing?.cancel()
                    trailing = null
                    gate.markPublished(latest, at)
                    shown.value = latest
                    publish(latest)
                }
                is StatusRefreshGate.Decision.Later -> {
                    if (trailing?.isActive != true) {
                        trailing = scope.launch {
                            delay(decision.delayMs)
                            synchronized(lock) { trailing = null }
                            refresh()
                        }
                    }
                }
            }
        }
    }
}
