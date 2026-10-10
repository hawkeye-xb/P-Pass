// SYNC-06: 订阅连接生命周期上提到 App 前台级别——脱钩 tab 切换。
//
// 旧实现（SYNC-04）：订阅连接绑在 PhotosScreen 的组合可见性上——切到
// "设置" tab 时 PhotosScreen 被移出组合树，订阅跟着断，切回来又要重新
// 建立，还会错过这期间到达的信号。2026-08-13 用户 review 指出这不合理。
//
// 本文件把订阅相关的状态（items/next/loading/error/subscribeAttempt/
// subscribeExhausted/subscribeConnected/subscribeHadFailure）和驱动订阅
// 的循环抽成 TimelineSubscriptionHolder，生命周期跟 ForegroundHeartbeat
// 对齐：ON_RESUME ~ ON_STOP 之间保持（App 前台期间不管显示哪个 tab），
// 退后台/锁屏即关（PRES-01"后台绝不心跳"红线同款判断），回前台重建并
// 整页刷新补齐后台期间错过的变化。PhotosScreen 只负责渲染这份状态，
// 不再自己创建/销毁订阅连接。
package com.hawkeyexb.ppass.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.hawkeyexb.ppass.proto.AssetMeta
import com.hawkeyexb.ppass.proto.TimelinePage
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.SubscribeRejectedException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * 配对变化轮询间隔——前台期间轻量检测重新配对/断开/换 token（读一次
 * pairing.json，跟 ForegroundHeartbeat 每 30s 读一次同族，只在
 * ON_RESUME~ON_STOP 之间跑）。
 */
internal const val SUBSCRIBE_MONITOR_POLL_MS = 2_000L

/**
 * SYNC-06: 订阅会话状态机的纯函数面（JVM 可测，不需要 Compose 测试环境）。
 *
 * 状态转换的唯一输入集 = 前台生命周期事件（ON_RESUME/ON_STOP）与用户动作
 * （手动重试）——**tab 切换不在输入集里**：切 tab 不产生任何转换，因此
 * 订阅发起次数（[SubscriptionSessionState.subscriptionsStarted]）和退避
 * 档位（[SubscriptionSessionState.subscribeAttempt]）在 tab 0→1→0 序列
 * 下保持 0 变化。退避决策复用 SYNC-04 的 nextSubscribeRetry（原样保留，
 * SubscribeRetryTest 5 条不动）。
 */
internal data class SubscriptionSessionState(
    val subscribeAttempt: Int = 0,
    val subscribeExhausted: Boolean = false,
    val subscribeConnected: Boolean = false,
    val subscribeHadFailure: Boolean = false,
    /** 订阅被发起的次数——tab 切换不得使其 +1（SYNC-06 验收断言面）。 */
    val subscriptionsStarted: Int = 0,
)

/** 一次订阅发起——旧实现里等价于 LaunchedEffect 重新进入组合树（每次切
 *  回照片 tab 都重新连一次）；新实现只在 ON_RESUME/手动重试/换配对时触发。 */
internal fun onSubscriptionSessionStarted(s: SubscriptionSessionState): SubscriptionSessionState =
    s.copy(
        subscribeConnected = false,
        subscriptionsStarted = s.subscriptionsStarted + 1,
    )

/** 订阅真正连上（读到第一帧）。 */
internal fun onSubscriptionConnected(s: SubscriptionSessionState): SubscriptionSessionState =
    s.copy(subscribeConnected = true, subscribeHadFailure = false)

internal data class SubscriptionEndedResult(
    val state: SubscriptionSessionState,
    /** 非空 = 退避等待这个时长后重连；null = 已耗尽，停止静默重试。 */
    val delayMs: Long?,
)

/** 订阅结束（对端关闭/连接异常）——正常返回和抛异常是同一件事，都走退避。 */
internal fun onSubscriptionEnded(
    s: SubscriptionSessionState,
    wasLive: Boolean,
    retry: (attempt: Int, wasLive: Boolean) -> SubscribeRetryDecision = ::nextSubscribeRetry,
): SubscriptionEndedResult {
    val decision = retry(s.subscribeAttempt, wasLive)
    return SubscriptionEndedResult(
        state = s.copy(
            subscribeConnected = false,
            subscribeHadFailure = true,
            subscribeAttempt = decision.nextAttempt,
            subscribeExhausted = decision.exhausted,
        ),
        delayMs = decision.delayMs,
    )
}

/** 用户手动重试——退避清零重来（UX-11：有界等待→亮错误→交给用户）。 */
internal fun onSubscriptionManualRetry(s: SubscriptionSessionState): SubscriptionSessionState =
    s.copy(subscribeAttempt = 0, subscribeExhausted = false)

/**
 * #474: 前台心跳确认桌面可达（hello 成功）。只有退避已耗尽（停在「重试」按钮上）
 * 才重启会话，效果同手动重试；正在重连或已连上时返回 null，什么都不做。
 * 心跳每 30s 成功一次就调一次，靠这个守卫保证幂等：重启会同步清掉 exhausted，
 * 后面的心跳全部落到 null 分支，不会重复起会话。
 */
internal fun onSubscriptionDesktopReachable(s: SubscriptionSessionState): SubscriptionSessionState? =
    if (s.subscribeExhausted) onSubscriptionManualRetry(s) else null

/**
 * SYNC-06: holder 对 timeline 通道的依赖面——生产实现包 TimelineLoader，
 * 测试注入计数 fake（不走网络）。协议层（SYNC-03/04）原样不动。
 */
internal interface TimelineChannel {
    /** PhotosScreen 用户交互（翻页/缩略图/查看器下载）共用的 loader。 */
    val loader: TimelineLoader?

    suspend fun loadPage(cursor: String?): TimelinePage

    suspend fun subscribe(
        onConnected: suspend () -> Unit = {},
        onInvalidated: suspend () -> Unit,
    )

    fun onRefreshed(hashes: Set<String>)

    fun onAppended(hashes: Set<String>)
}

/** 生产实现：TimelineLoader 的薄包装。 */
internal class LoaderTimelineChannel(private val l: TimelineLoader) : TimelineChannel {
    override val loader: TimelineLoader get() = l
    override suspend fun loadPage(cursor: String?): TimelinePage = l.page(cursor)
    override suspend fun subscribe(
        onConnected: suspend () -> Unit,
        onInvalidated: suspend () -> Unit,
    ) = l.subscribe(onConnected, onInvalidated)
    override fun onRefreshed(hashes: Set<String>) = l.onTimelineRefreshed(hashes)
    override fun onAppended(hashes: Set<String>) = l.onTimelineAppended(hashes)
}

/**
 * SYNC-06: 订阅连接的生命周期与状态——跟 ForegroundHeartbeat 同一层
 * （MainActivity 持有，ON_RESUME 起 / ON_STOP 停）。App 前台期间不管
 * 显示哪个 tab 都保持订阅；只有退后台/锁屏/进程被杀才断开。回前台重建
 * 订阅并整页刷新补齐后台期间可能错过的变化。
 *
 * 只负责"什么时候创建/销毁订阅 + 这份订阅驱动的时间线状态"，不改变订阅
 * 本身怎么工作（SYNC-03/04 协议层不动，nextSubscribeRetry 原样）。
 */
internal class TimelineSubscriptionHolder(
    private val scope: CoroutineScope,
    /** 当前配对（null = 未配对/已断开）——生产 = { pairings.load() }。 */
    private val currentPairing: () -> Pairing?,
    /** 给配对建 timeline 通道（生产 = LoaderTimelineChannel(TimelineLoader(...))）。 */
    private val channelFor: (Pairing) -> TimelineChannel,
    /** #474: 订阅生命周期日志（建立/断开/放弃/自动恢复各一行）——生产 = PLog.i("PPassTimeline", …)。 */
    private val log: (String) -> Unit = {},
) {
    var state by mutableStateOf(SubscriptionSessionState())
        private set

    var items by mutableStateOf<List<AssetMeta>>(emptyList())
        private set

    var next by mutableStateOf<String?>(null)
        private set

    var loading by mutableStateOf(false)
        private set

    var error by mutableStateOf<String?>(null)
        private set

    /** PhotosScreen 用户交互（翻页/缩略图/查看器）共用的 loader——换配对时重建。 */
    var loader by mutableStateOf<TimelineLoader?>(null)
        private set

    private var job: Job? = null
    private var sessionJob: Job? = null
    private var pollerJob: Job? = null
    private var active = false
    private var targetPairing: Pairing? = null
    private var channel: TimelineChannel? = null

    /** 前台开始（ON_RESUME）：开启配对监视 + 订阅会话 + 60s 兜底轮询。
     *  幂等——重复调用（如多次 ON_RESUME）不重启连接。 */
    fun start() {
        if (active) return
        active = true
        // 新前台会话：退避/失败标志清零（旧实现里每次重建组合树 = 全新状态）。
        state = SubscriptionSessionState()
        targetPairing = null // 强制 monitor 首轮按当前配对重建会话
        job = scope.launch { monitorLoop() }
        pollerJob = scope.launch { pollerLoop() }
    }

    /** 退后台/锁屏（ON_STOP）：跟心跳一样停止——订阅主动关闭，
     *  不产生任何后台网络活动（PRES-01 红线）。 */
    fun stop() {
        active = false
        job?.cancel()
        job = null
        sessionJob?.cancel()
        sessionJob = null
        pollerJob?.cancel()
        pollerJob = null
        state = state.copy(subscribeConnected = false)
    }

    /** 手动重试（退避耗尽后 UI 亮"连不上"+重试入口）——重新发起一次会话。 */
    fun retry() {
        if (!active) return
        state = onSubscriptionManualRetry(state)
        sessionJob?.cancel()
        sessionJob = null
        launchSession()
    }

    /**
     * #474: 前台心跳 hello 成功时调用。退避耗尽后桌面回来了，不用等用户点「重试」。
     * 非耗尽状态直接返回，见 [onSubscriptionDesktopReachable]。
     */
    fun onDesktopReachable() {
        if (!active) return
        if (onSubscriptionDesktopReachable(state) == null) return
        log("subscribe: auto-resume (desktop reachable after exhausted)")
        retry()
    }

    /**
     * 配对监视：前台期间轮询配对存储，发现配对变化（新配对/断开/换 token）
     * 就重建会话。未配对时保持空闲（跟心跳"无存储端可拍就静默跳过"一致）。
     */
    private suspend fun CoroutineScope.monitorLoop() {
        while (isActive && active) {
            val pairing = currentPairing()
            if (pairing != targetPairing) {
                sessionJob?.cancel()
                sessionJob = null
                targetPairing = pairing
                channel = null
                loader = null
                items = emptyList()
                next = null
                error = null
                state = SubscriptionSessionState()
                if (pairing != null) {
                    val ch = channelFor(pairing)
                    channel = ch
                    loader = ch.loader
                    loading = true
                    launchSession()
                } else {
                    loading = false
                }
            }
            delay(SUBSCRIBE_MONITOR_POLL_MS)
        }
    }

    private fun launchSession() {
        val ch = channel ?: return
        sessionJob = scope.launch { sessionLoop(ch) }
    }

    /**
     * 一次订阅会话：初始整页加载 → 前台常驻订阅（收到信号 = 整页覆盖刷新，
     * 删除可见性核心）→ 断线有限退避重连（nextSubscribeRetry 原样）；
     * 退避耗尽停止静默重试，等用户手动重试。CancellationException 必须
     * 向上传播（REV-01 #4）——stop()/换配对/销毁时真的要停下来。
     */
    private suspend fun CoroutineScope.sessionLoop(ch: TimelineChannel) {
        try {
            if (items.isEmpty()) loading = true
            refreshFullPage(ch)
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            error = t.message
        } finally {
            loading = false
        }
        if (!isActive || !active) return

        var connectedAt: Long? = null
        while (isActive && active && !state.subscribeExhausted) {
            state = onSubscriptionSessionStarted(state)
            connectedAt = null
            try {
                ch.subscribe(
                    onConnected = {
                        state = onSubscriptionConnected(state)
                        connectedAt = System.currentTimeMillis()
                        log("subscribe: connected")
                    },
                ) {
                    try {
                        refreshFullPage(ch)
                    } catch (e: CancellationException) {
                        throw e // REV-01 #4: 取消不能被当成普通失败吞掉。
                    } catch (_: Throwable) {
                        // 这一次刷新失败——不动 items，等下一次信号/兜底轮询。
                    }
                }
                // 正常返回（对端 finish 了发送方向，比如设备被吊销）和抛异常
                // 是同一件事：这次订阅结束了，都走下面的退避重连。
                log("subscribe: ended (peer closed)")
            } catch (e: CancellationException) {
                throw e // REV-01 #4: 同上——stop()/换配对时真的停下来。
            } catch (rejected: SubscribeRejectedException) {
                // #522：桌面明确拒绝（撤销后是 NOT_AUTHORIZED）——不是断线，也从没连上过。退避照旧。
                log("subscribe: rejected by the desktop (${rejected.code}: ${rejected.msgKey})")
            } catch (t: Throwable) {
                // 连接异常——同样走退避重连。
                log("subscribe: ended (${t::class.simpleName}: ${t.message})")
            }
            val wasLive = connectedAt?.let {
                System.currentTimeMillis() - it >= SUBSCRIBE_WAS_LIVE_MS
            } ?: false
            val ended = onSubscriptionEnded(state, wasLive)
            state = ended.state
            if (ended.state.subscribeExhausted) {
                log("subscribe: exhausted (backoff used up), waiting for manual retry or desktop reachable")
            }
            ended.delayMs?.let { delay(it) }
        }
    }

    /**
     * 整页重载——首次加载、订阅信号、重连后补齐都走这一条路径。成功即清
     * error：订阅恢复后"连不上"必须能自己消掉（旧实现靠切 tab 重建状态
     * 才能恢复，现在 tab 切换不再重建了，不清会永久卡在错误屏）。
     */
    private suspend fun refreshFullPage(ch: TimelineChannel) {
        val page = ch.loadPage(null)
        items = page.items
        next = page.next
        ch.onRefreshed(page.items.map { it.hash }.toSet())
        error = null
    }

    /**
     * 翻页追加（PhotosScreen 的 pager 触发）——只增不逐：后页照片仍在库中，
     * 不触发 onRefreshed（缓存逐出是整页覆盖的职责）。失败把游标清掉，
     * pager 停在这里不再重复拉同一页（跟旧实现 LaunchedEffect 的
     * catch 语义一致）。CancellationException 向上传播（pager 离开组合树
     * 时要真的停下来）。
     */
    suspend fun appendNextPage(cursor: String) {
        val ch = channel ?: run {
            next = null
            return
        }
        try {
            val page = ch.loadPage(cursor)
            items = items + page.items
            next = page.next
            ch.onAppended(page.items.map { it.hash }.toSet())
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            next = null
        }
    }

    /**
     * 60s 兜底轮询——"仅追加"语义（REV-01 #2）：订阅是主通道（整页覆盖），
     * 这层只是防真实丢事件的保险丝，不动已加载内容/翻页游标，不触发
     * onRefreshed（缓存逐出是整页覆盖的职责）。
     */
    private suspend fun CoroutineScope.pollerLoop() {
        while (isActive && active) {
            delay(FULL_REFRESH_FALLBACK_MS)
            if (currentPairing() == null) continue
            val ch = channel ?: continue
            try {
                val page = ch.loadPage(null)
                val known = items.map { it.hash }.toSet()
                val fresh = page.items.filter { it.hash !in known }
                if (fresh.isNotEmpty()) {
                    items = fresh + items
                    ch.onAppended(fresh.map { it.hash }.toSet())
                }
            } catch (_: Throwable) {
                // 静默——下一轮再试，不用错误态打断正在看的照片。
            }
        }
    }
}
