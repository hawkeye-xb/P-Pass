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

internal const val SUBSCRIBE_MONITOR_POLL_MS = 2_000L

internal data class SubscriptionSessionState(
    val subscribeAttempt: Int = 0,
    val subscribeExhausted: Boolean = false,
    val subscribeConnected: Boolean = false,
    val subscribeHadFailure: Boolean = false,
    val subscriptionsStarted: Int = 0,
)

internal fun onSubscriptionSessionStarted(s: SubscriptionSessionState): SubscriptionSessionState =
    s.copy(
        subscribeConnected = false,
        subscriptionsStarted = s.subscriptionsStarted + 1,
    )

internal fun onSubscriptionConnected(s: SubscriptionSessionState): SubscriptionSessionState =
    s.copy(subscribeConnected = true, subscribeHadFailure = false)

internal data class SubscriptionEndedResult(
    val state: SubscriptionSessionState,
    val delayMs: Long?,
)

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

internal fun onSubscriptionManualRetry(s: SubscriptionSessionState): SubscriptionSessionState =
    s.copy(subscribeAttempt = 0, subscribeExhausted = false)

internal fun onSubscriptionDesktopReachable(s: SubscriptionSessionState): SubscriptionSessionState? =
    if (s.subscribeExhausted) onSubscriptionManualRetry(s) else null

internal data class ConnectionState(
    val status: Status,
    val daysUnreachable: Int? = null,
) {
    enum class Status {
        PairingLost,
        Connected,
        Reconnecting,
        Offline,
        Unknown,
    }

    val isConnected: Boolean get() = status == Status.Connected
    val needsRepair: Boolean get() = status == Status.PairingLost
}

internal fun connectionStateOf(
    pairingLost: Boolean,
    state: SubscriptionSessionState,
    daysUnreachable: Int? = null,
): ConnectionState = ConnectionState(
    status = when {
        pairingLost -> ConnectionState.Status.PairingLost
        state.subscribeConnected -> ConnectionState.Status.Connected
        state.subscribeExhausted -> ConnectionState.Status.Offline
        state.subscribeHadFailure -> ConnectionState.Status.Reconnecting
        else -> ConnectionState.Status.Unknown
    },
    daysUnreachable = daysUnreachable,
)

internal interface TimelineChannel {
    val loader: TimelineLoader?

    suspend fun loadPage(cursor: String?): TimelinePage

    suspend fun subscribe(
        onConnected: suspend () -> Unit = {},
        onInvalidated: suspend () -> Unit,
    )

    fun onRefreshed(hashes: Set<String>)

    fun onAppended(hashes: Set<String>)
}

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

internal class TimelineSubscriptionHolder(
    private val scope: CoroutineScope,
    private val currentPairing: () -> Pairing?,
    private val channelFor: (Pairing) -> TimelineChannel,
    private val log: (String) -> Unit = {},
) {
    internal var state by mutableStateOf(SubscriptionSessionState())
        private set

    var items by mutableStateOf<List<AssetMeta>>(emptyList())
        private set

    var next by mutableStateOf<String?>(null)
        private set

    var loading by mutableStateOf(false)
        private set

    var error by mutableStateOf<String?>(null)
        private set

    var loader by mutableStateOf<TimelineLoader?>(null)
        private set

    private var job: Job? = null
    private var sessionJob: Job? = null
    private var pollerJob: Job? = null
    private var active = false
    private var targetPairing: Pairing? = null
    private var channel: TimelineChannel? = null

    internal fun connectionState(
        pairingLost: Boolean,
        daysUnreachable: Int? = null,
    ): ConnectionState = connectionStateOf(
        pairingLost = pairingLost,
        state = state,
        daysUnreachable = daysUnreachable,
    )

    fun start() {
        if (active) return
        active = true
        state = SubscriptionSessionState()
        targetPairing = null
        job = scope.launch { monitorLoop() }
        pollerJob = scope.launch { pollerLoop() }
    }

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

    fun retry() {
        if (!active) return
        state = onSubscriptionManualRetry(state)
        sessionJob?.cancel()
        sessionJob = null
        launchSession()
    }

    fun onDesktopReachable() {
        if (!active) return
        if (onSubscriptionDesktopReachable(state) == null) return
        log("subscribe: auto-resume (desktop reachable after exhausted)")
        retry()
    }

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
                        if (error != null) {
                            try {
                                refreshFullPage(ch)
                            } catch (e: CancellationException) {
                                throw e
                            } catch (_: Throwable) {
                            }
                        }
                    },
                ) {
                    try {
                        refreshFullPage(ch)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Throwable) {
                    }
                }
                log("subscribe: ended (peer closed)")
            } catch (e: CancellationException) {
                throw e
            } catch (rejected: SubscribeRejectedException) {
                log("subscribe: rejected by the desktop (${rejected.code}: ${rejected.reason})")
            } catch (t: Throwable) {
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

    private suspend fun refreshFullPage(ch: TimelineChannel) {
        val page = ch.loadPage(null)
        items = page.items
        next = page.next
        ch.onRefreshed(page.items.map { it.hash }.toSet())
        error = null
    }

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
            }
        }
    }
}
