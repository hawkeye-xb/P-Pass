// REBUILD-03 / ARCH-13 (#417): phone-side adapter from one order to a Desktop receipt.
//
// #417 的改动：
// - queue_sequence / lease_token 由 order 行 id 填（线协议不改）。
// - 回调风格改成挂起函数，结局按 #410 分类返回（路径 / 单张 / 对端），不再是一种「失败」。
// - `FlowPushedFailureException.code` 终于被读：storage_failed = 对端失败，fetch_failed = 路径失败。
// - #410 参数：15 秒没人来连 → 去问桌面，回 active 就继续等；3 分钟没有新的文件字节 → 主动断开，路径失败。
// - 不直接碰 android.util.Log / SystemClock：日志和时钟都注入，整条等待循环能在 JVM 上用虚拟时间测。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.isPairingLostText
import com.hawkeyexb.ppass.backup.order.AuditRecord
import com.hawkeyexb.ppass.backup.order.OrderStore
import com.hawkeyexb.ppass.proto.FlowAuditAccepted
import com.hawkeyexb.ppass.proto.FlowAuditEvent
import com.hawkeyexb.ppass.proto.FlowAuditSubmit
import com.hawkeyexb.ppass.proto.FlowCompletionReceipt
import com.hawkeyexb.ppass.proto.FlowFetchRequest
import com.hawkeyexb.ppass.proto.FlowStatusReply
import com.hawkeyexb.ppass.proto.FlowTupleRef
import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PeerAddrParts
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/** 桌面对一条请求回了 `ok=false`：对端**可达**、明确拒绝——不是路径问题。 */
internal class DesktopRejectedException(val msgKey: String?, method: String) :
    IllegalStateException("$method: $msgKey")

/** The only Desktop interaction accepted by the Android Flow delivery port. */
internal interface FlowReceiptClient {
    suspend fun currentPairingEpoch(): String?

    /**
     * NET-24: returns the same [FlowStatusReply] a [status] call issued right now would return.
     * `state == "active"` is the genuinely-async case (go wait); a terminal state means the daemon
     * already finished (NET-20 content dedup or NET-22 rebind).
     */
    suspend fun offer(request: FlowFetchRequest): FlowStatusReply

    /** NET-06: read-only control-plane query for one exact tuple. */
    suspend fun status(tuple: FlowTupleRef): FlowStatusReply
    suspend fun cancel(request: FlowFetchRequest)
}

/** AUDIT-01: the one daemon interaction the audit outbox dispatcher needs. */
internal interface FlowAuditTransport {
    suspend fun submit(events: List<AuditRecord>): FlowAuditAccepted
}

/** Ctrl-plane adapter for [FlowAuditTransport] — no native transport involved. */
internal class DaemonFlowAuditTransport(
    private val client: DaemonClient,
    private val peer: PeerAddrParts,
) : FlowAuditTransport {
    override suspend fun submit(events: List<AuditRecord>): FlowAuditAccepted {
        val response = client.call(
            peer,
            Methods.FLOW_AUDIT_SUBMIT,
            ProtoJson.encodeToJsonElement(
                FlowAuditSubmit.serializer(),
                FlowAuditSubmit(
                    events = events.map {
                        FlowAuditEvent(
                            eventId = it.eventId,
                            kind = it.kind,
                            roundId = it.roundId,
                            occurredAtMs = it.occurredAtMs,
                            payload = it.payload,
                        )
                    },
                ),
            ),
        )
        check(response.ok) { "flow.audit.submit: ${response.error?.msgKey}" }
        return ProtoJson.decodeFromJsonElement(FlowAuditAccepted.serializer(), checkNotNull(response.result))
    }
}

/**
 * AUDIT-01: drains the order store's durable audit outbox to the daemon over `flow.audit.submit`,
 * acknowledging exactly the event ids the daemon confirmed durable. Anything not confirmed stays for
 * the next flush (never drop on send, only on confirmed daemon receipt).
 */
internal class AuditOutboxDispatcher(
    private val outbox: () -> List<AuditRecord>,
    private val pairing: () -> Pairing?,
    private val transportFor: suspend (Pairing) -> FlowAuditTransport,
    /** MOB-88: 删已确认事件这一步回到单写者上执行。 */
    private val acknowledgeEvents: (Set<String>) -> Unit,
) {
    constructor(
        store: OrderStore,
        pairing: () -> Pairing?,
        transportFor: suspend (Pairing) -> FlowAuditTransport,
        acknowledgeEvents: (Set<String>) -> Unit,
    ) : this({ store.pendingAudit(AUDIT_BATCH) }, pairing, transportFor, acknowledgeEvents)

    /** Best-effort: any failure (offline, unpaired, IO) leaves the outbox untouched. */
    suspend fun flush() {
        val events = outbox()
        if (events.isEmpty()) return
        val currentPairing = pairing() ?: return
        runCatching { transportFor(currentPairing).submit(events) }
            .onSuccess { accepted -> if (accepted.eventIds.isNotEmpty()) acknowledgeEvents(accepted.eventIds.toSet()) }
    }

    private companion object {
        const val AUDIT_BATCH = 200
    }
}

/** Keeps an in-flight delivery from crossing into a newly paired Desktop epoch. */
internal class FlowDeliveryEpochGuard(private val pairing: () -> Pairing?) {
    fun isCurrent(expectedEpoch: PairingEpoch): Boolean = pairing()?.pairingEpoch == expectedEpoch.value
}

/** Process-local pairing-loss fact from an authenticated Flow delivery rejection. */
internal class FlowDeliveryPairingLoss {
    @Volatile private var lostEpoch: String? = null

    fun record(epoch: PairingEpoch, failure: Throwable) {
        if (failure.message?.let(::isPairingLostText) == true) {
            lostEpoch = epoch.value
        }
    }

    fun isLost(epoch: PairingEpoch): Boolean = lostEpoch == epoch.value
}

internal val flowDeliveryPairingLoss = FlowDeliveryPairingLoss()

/** Validates a Desktop receipt against the exact request before it may confirm an order. */
internal fun relayFlowCompletion(receipt: FlowCompletionReceipt, request: FlowFetchRequest): CompletionReceipt {
    require(receipt.queueSequence == request.queueSequence)
    require(receipt.pairingEpoch == request.pairingEpoch)
    require(receipt.leaseToken == request.leaseToken)
    require(receipt.contentHash == request.contentHash)
    return CompletionReceipt(
        queueSequence = receipt.queueSequence,
        receiptId = receipt.receiptId,
        pairingEpoch = PairingEpoch(receipt.pairingEpoch),
        leaseToken = receipt.leaseToken,
        contentHash = receipt.contentHash,
    )
}

/** Ctrl-plane adapter; data stays on native iroh-blobs through the ticket. */
internal class DaemonFlowReceiptClient(
    private val client: DaemonClient,
    private val peer: PeerAddrParts,
) : FlowReceiptClient {
    override suspend fun currentPairingEpoch(): String? {
        val response = client.call(peer, Methods.HELLO, buildJsonObject {})
        if (!response.ok) throw DesktopRejectedException(response.error?.msgKey, "hello")
        return ProtoJson.decodeFromJsonElement(Hello.serializer(), checkNotNull(response.result)).pairingEpoch
    }

    override suspend fun offer(request: FlowFetchRequest): FlowStatusReply {
        val response = client.call(peer, Methods.FLOW_OFFER, ProtoJson.encodeToJsonElement(FlowFetchRequest.serializer(), request))
        if (!response.ok) throw DesktopRejectedException(response.error?.msgKey, "flow.offer")
        // NET-24: a null result means the peer daemon predates NET-24. Fail loudly.
        val result = response.result
        check(result != null && result !is JsonNull) {
            "flow.offer: empty reply — peer daemon predates NET-24 and cannot report terminal state on offer"
        }
        return ProtoJson.decodeFromJsonElement(FlowStatusReply.serializer(), result)
    }

    override suspend fun status(tuple: FlowTupleRef): FlowStatusReply {
        val response = client.call(peer, Methods.FLOW_STATUS, ProtoJson.encodeToJsonElement(FlowTupleRef.serializer(), tuple))
        if (!response.ok) throw DesktopRejectedException(response.error?.msgKey, "flow.status")
        return ProtoJson.decodeFromJsonElement(FlowStatusReply.serializer(), checkNotNull(response.result))
    }

    override suspend fun cancel(request: FlowFetchRequest) {
        val response = client.call(peer, Methods.FLOW_CANCEL, ProtoJson.encodeToJsonElement(FlowFetchRequest.serializer(), request))
        if (!response.ok) throw DesktopRejectedException(response.error?.msgKey, "flow.cancel")
    }
}

/**
 * #410 / #415 裁决 3：桌面推来的 `flow.failed` code 的分类。
 * - `storage_failed`（存不下）→ 对端失败：退出循环，不计次数。
 * - `fetch_failed`（拉不到——relay 限流、断网、对端忙）→ 路径失败：保持可续传，不计次数。
 * - 其它 / 旧版对端的未知 code → 单张失败：计次数、有上限——保守的那一侧（不会因此无限重试）。
 */
internal fun classifyPushedFailure(code: String): DeliveryOutcome = when (code) {
    "storage_failed" -> DeliveryOutcome.PeerFailure(code)
    "fetch_failed" -> DeliveryOutcome.PathFailure(code)
    else -> DeliveryOutcome.ItemFailure("pushed:$code")
}

/**
 * 传输过程中抛出的异常的分类。桌面可达且明确拒绝（[DesktopRejectedException]）不是路径问题：
 * 当路径失败会让一条坏请求每次都把循环停下、且永不计次数。
 */
internal fun classifyDeliveryFailure(failure: Throwable): DeliveryOutcome = when {
    failure is DesktopRejectedException && failure.msgKey?.let(::isPairingLostText) == true -> DeliveryOutcome.PairingLost
    failure is DesktopRejectedException -> DeliveryOutcome.ItemFailure("rejected:${failure.msgKey}")
    failure is FlowPushedFailureException -> classifyPushedFailure(failure.code)
    failure is IllegalArgumentException || failure is IllegalStateException ->
        DeliveryOutcome.ItemFailure("invalid:${failure.javaClass.simpleName}")
    else -> DeliveryOutcome.PathFailure("network:${failure.javaClass.simpleName}")
}

/**
 * Registers exactly one order with Android's native provider, then asks Desktop to offer and fetch
 * that exact ticket. Receipt fields are checked again before they may confirm the order.
 */
internal class NativeFlowDeliveryPort(
    private val bridge: IrohBlobsProviderBridge,
    private val pairing: () -> Pairing?,
    /** Seam for tests: production binds the real client and builds a [DaemonFlowReceiptClient]. */
    private val desktopFor: suspend (Pairing) -> FlowReceiptClient,
    /** NET-14 push subscription (`timeline.subscribe`); suspends until the stream ends. */
    private val subscribe: suspend (Pairing, (String, JsonObject) -> Unit) -> Unit,
    /** NET-06: best-effort `flow.cancel_tuple` for discarding a partial. */
    private val cancelTuple: suspend (Pairing, FlowTupleRef) -> Unit,
    private val log: FlowLogger = FlowLogger { },
    /** 单调时钟（ms）。生产是 SystemClock.elapsedRealtime。 */
    private val clock: () -> Long = System::nanoTime.let { nano -> { nano() / 1_000_000 } },
    private val sideEffects: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val idleStallThresholdMs: Long = LOCAL_IDLE_STALL_THRESHOLD_MS,
    private val byteStallThresholdMs: Long = BYTE_STALL_THRESHOLD_MS,
) : ItemDelivery {
    private val epochGuard = FlowDeliveryEpochGuard(pairing)

    override suspend fun deliver(request: DeliveryRequest, onProgress: (Long) -> Unit): DeliveryOutcome {
        val currentPairing = pairing() ?: return DeliveryOutcome.PairingLost
        if (currentPairing.pairingEpoch != request.pairingEpoch.value) return DeliveryOutcome.PathFailure("epoch_changed")
        val lease = ProviderLease(request.orderId, request.leaseToken, request.contentHash)
        val ticket = try {
            bridge.register(lease, request.details.uri)
        } catch (missing: SourceMissingException) {
            return DeliveryOutcome.SourceMissing
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            // 原生导入失败：多半是文件在 hash 之后又被改了（声明的 hash 对不上）——这一张的问题。
            log.log("order ${request.orderId}: native register failed (${failure.message})")
            return DeliveryOutcome.ItemFailure("register:${failure.javaClass.simpleName}")
        }
        // 大文件的 register 会阻塞很久：它返回之后、offer 之前再看一眼是不是已经被暂停 / 取消了。
        try {
            currentCoroutineContext().ensureActive()
        } catch (cancelled: CancellationException) {
            withContext(NonCancellable) { runCatching { bridge.pause(lease) } }
            throw cancelled
        }
        val fetch = FlowFetchRequest(
            queueSequence = request.orderId,
            pairingEpoch = request.pairingEpoch.value,
            leaseToken = request.leaseToken,
            contentHash = request.contentHash,
            fileName = request.details.fileName.ifBlank { request.details.uri.substringAfterLast('/') },
            mediaType = request.details.mimeType,
            provider = ticket,
            captureAtMs = request.details.captureAtMs,
        )
        var desktop: FlowReceiptClient? = null
        return try {
            val client = desktopFor(currentPairing).also { desktop = it }
            val offerReply = client.offer(fetch)
            // NET-24: terminal state may already ride back on the offer reply (dedup / rebind).
            when (val immediate = flowStatusPollOutcome(offerReply)) {
                is FlowStatusPollOutcome.Completed -> {
                    log.log("Flow resolved by=offer_reply seq=${fetch.queueSequence}")
                    return accept(immediate.receipt, fetch, lease)
                }
                FlowStatusPollOutcome.Cancelled -> {
                    bridge.pause(lease)
                    return DeliveryOutcome.PathFailure("offer_cancelled")
                }
                FlowStatusPollOutcome.KeepPolling -> Unit
            }
            waitForCompletion(client, currentPairing, fetch, lease, request.pairingEpoch, onProgress)
        } catch (cancelled: CancellationException) {
            // 暂停 / 取消 / FGS 被收走：停掉原生传输（部分数据在桌面保留，续传只补缺的），
            // 顺带告诉桌面这次不等了。不等回声（NET-06 原则 1）。
            withContext(NonCancellable) { runCatching { bridge.pause(lease) } }
            desktop?.let { d -> sideEffects.launch { runCatching { d.cancel(fetch) } } }
            throw cancelled
        } catch (failure: Throwable) {
            runCatching { bridge.pause(lease) }
            if (!epochGuard.isCurrent(request.pairingEpoch)) return DeliveryOutcome.PathFailure("epoch_changed")
            flowDeliveryPairingLoss.record(request.pairingEpoch, failure)
            classifyDeliveryFailure(failure).also {
                log.log("order ${request.orderId}: delivery ended with $it (${failure.javaClass.simpleName}: ${failure.message})")
            }
        }
    }

    private suspend fun waitForCompletion(
        desktop: FlowReceiptClient,
        currentPairing: Pairing,
        fetch: FlowFetchRequest,
        lease: ProviderLease,
        epoch: PairingEpoch,
        onProgress: (Long) -> Unit,
    ): DeliveryOutcome = coroutineScope {
        // NET-06/NET-14: priority order — push, then local iroh-blobs signal, then a bounded status() check.
        val tuple = FlowTupleRef(queueSequence = fetch.queueSequence, pairingEpoch = fetch.pairingEpoch, leaseToken = fetch.leaseToken)
        val pushChannel = Channel<Pair<String, JsonObject>>(capacity = 8)
        val subscription = launch {
            // 推送只是加速，不是唯一路径：订阅失败不致命，本地信号 + status() 兜底。
            runCatching { subscribe(currentPairing) { kind, data -> pushChannel.trySend(kind to data) } }
        }
        try {
            var pollDelayIndex = 0
            var consecutiveStatusFailures = 0
            var lastBytes = -1L
            val attemptStartedAt = clock()
            while (true) {
                if (!epochGuard.isCurrent(epoch)) {
                    bridge.pause(lease)
                    return@coroutineScope DeliveryOutcome.PathFailure("epoch_changed")
                }
                val pushed = pushChannel.tryReceive().getOrNull()?.let { (kind, data) -> parseFlowPushOutcome(kind, data, tuple) }
                val local = bridge.transferStatus()
                (local as? TransferStatus.InProgress)?.bytesSent?.let { sent ->
                    if (sent != lastBytes) {
                        lastBytes = sent
                        onProgress(sent)
                    }
                }
                val elapsed = clock() - attemptStartedAt
                when (val step = flowWaitStep(pushed, local, idleStallThresholdMs, byteStallThresholdMs, elapsed)) {
                    is FlowWaitStep.Resolved -> when (val outcome = step.outcome) {
                        is FlowStatusPollOutcome.Completed -> {
                            log.log("Flow resolved by=push seq=${fetch.queueSequence}")
                            return@coroutineScope accept(outcome.receipt, fetch, lease)
                        }
                        FlowStatusPollOutcome.Cancelled -> {
                            bridge.pause(lease)
                            return@coroutineScope DeliveryOutcome.PathFailure("cancelled")
                        }
                        FlowStatusPollOutcome.KeepPolling -> continue
                    }
                    is FlowWaitStep.Failed -> {
                        bridge.pause(lease)
                        return@coroutineScope classifyPushedFailure(step.code)
                    }
                    FlowWaitStep.Stalled -> {
                        // #410：连接还在、3 分钟没有新的文件字节 → 主动断开，路径失败。
                        log.log("order ${fetch.queueSequence}: no new file bytes for ${byteStallThresholdMs}ms; disconnecting")
                        bridge.pause(lease)
                        return@coroutineScope DeliveryOutcome.PathFailure("byte_stall")
                    }
                    FlowWaitStep.KeepWaitingForPush -> delay(LOCAL_STATUS_RECHECK_MS)
                    FlowWaitStep.CheckStatusNow -> {
                        val reply = try {
                            desktop.status(tuple)
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (failure: DesktopRejectedException) {
                            throw failure
                        } catch (failure: Throwable) {
                            consecutiveStatusFailures += 1
                            if (consecutiveStatusFailures >= STATUS_POLL_MAX_CONSECUTIVE_FAILURES) throw failure
                            delay(nextStatusPollDelayMs(pollDelayIndex++))
                            continue
                        }
                        consecutiveStatusFailures = 0
                        when (val outcome = flowStatusPollOutcome(reply)) {
                            is FlowStatusPollOutcome.Completed -> {
                                log.log("Flow resolved by=status seq=${fetch.queueSequence} local=$local elapsedMs=$elapsed")
                                return@coroutineScope accept(outcome.receipt, fetch, lease)
                            }
                            FlowStatusPollOutcome.Cancelled -> {
                                bridge.pause(lease)
                                return@coroutineScope DeliveryOutcome.PathFailure("cancelled")
                            }
                            // #410：桌面回 active 就继续等，不判失败（字节停滞由 Stalled 兜底）。
                            FlowStatusPollOutcome.KeepPolling -> delay(nextStatusPollDelayMs(pollDelayIndex++))
                        }
                    }
                }
            }
            @Suppress("UNREACHABLE_CODE")
            error("unreachable")
        } finally {
            subscription.cancel()
        }
    }

    private fun accept(receipt: FlowCompletionReceipt, fetch: FlowFetchRequest, lease: ProviderLease): DeliveryOutcome {
        val completed = relayFlowCompletion(receipt, fetch)
        // BLOB-03: release provider retention only at the validated success boundary.
        runCatching { bridge.releaseRetention(lease) }
        return DeliveryOutcome.Confirmed(completed)
    }

    override fun discardPartial(orderId: Long, pairingEpoch: PairingEpoch) {
        val currentPairing = pairing() ?: return
        sideEffects.launch {
            runCatching {
                cancelTuple(currentPairing, FlowTupleRef(queueSequence = orderId, pairingEpoch = pairingEpoch.value, leaseToken = leaseTokenFor(orderId)))
            }
        }
    }
}

/** `hello` 探测（有超时）：桌面可达吗、它现在的配对代号是什么。 */
internal class DaemonDesktopProbe(
    private val pairing: () -> Pairing?,
    private val desktopFor: suspend (Pairing) -> FlowReceiptClient,
    private val timeoutMs: Long = PROBE_TIMEOUT_MS,
) : DesktopProbe {
    override suspend fun probe(): ProbeResult {
        val current = pairing() ?: return ProbeResult.PairingLost
        return try {
            withTimeout(timeoutMs) { ProbeResult.Reachable(desktopFor(current).currentPairingEpoch()) }
        } catch (rejected: DesktopRejectedException) {
            if (rejected.msgKey?.let(::isPairingLostText) == true) ProbeResult.PairingLost else ProbeResult.Unreachable
        } catch (cancelled: CancellationException) {
            // withTimeout 的超时也是 CancellationException——区分「我被取消了」与「对端没回」。
            currentCoroutineContext().ensureActive()
            ProbeResult.Unreachable
        } catch (_: Throwable) {
            ProbeResult.Unreachable
        }
    }

    private companion object {
        const val PROBE_TIMEOUT_MS = 20_000L
    }
}

/** NET-06: pure decision over one [FlowStatusReply]. "not_found" is a genuine inconsistency. */
internal sealed interface FlowStatusPollOutcome {
    data class Completed(val receipt: FlowCompletionReceipt) : FlowStatusPollOutcome
    object Cancelled : FlowStatusPollOutcome
    object KeepPolling : FlowStatusPollOutcome
}

internal fun flowStatusPollOutcome(reply: FlowStatusReply): FlowStatusPollOutcome =
    when (reply.state) {
        "completed" -> FlowStatusPollOutcome.Completed(reply.receipt ?: error("flow.status: completed with no receipt"))
        "cancelled" -> FlowStatusPollOutcome.Cancelled
        "not_found" -> error("flow.status: daemon has no record of our own grant")
        else -> FlowStatusPollOutcome.KeepPolling
    }

/** NET-14: a `flow.delivered`/`flow.failed` push matched against this attempt's exact tuple. */
internal sealed interface FlowPushOutcome {
    data class Delivered(val receipt: FlowCompletionReceipt) : FlowPushOutcome
    data class Failed(val code: String) : FlowPushOutcome
}

/** The daemon pushed a terminal failure for this exact tuple; [code] is now classified (#410). */
internal class FlowPushedFailureException(val code: String) :
    Exception("desktop pushed a terminal flow.failed: $code")

internal fun parseFlowPushOutcome(kind: String, data: JsonObject, tuple: FlowTupleRef): FlowPushOutcome? {
    val queueSequence = (data["queue_sequence"] as? JsonPrimitive)?.content?.toLongOrNull() ?: return null
    val pairingEpoch = (data["pairing_epoch"] as? JsonPrimitive)?.content ?: return null
    val leaseToken = (data["lease_token"] as? JsonPrimitive)?.content ?: return null
    if (queueSequence != tuple.queueSequence || pairingEpoch != tuple.pairingEpoch || leaseToken != tuple.leaseToken) {
        return null
    }
    return when (kind) {
        "flow.delivered" -> {
            val receiptElement = data["receipt"] ?: return null
            FlowPushOutcome.Delivered(ProtoJson.decodeFromJsonElement(FlowCompletionReceipt.serializer(), receiptElement))
        }
        "flow.failed" -> FlowPushOutcome.Failed((data["code"] as? JsonPrimitive)?.content ?: "unknown")
        else -> null
    }
}

/** NET-14 / #410: the wait loop's next action. */
internal sealed interface FlowWaitStep {
    data class Resolved(val outcome: FlowStatusPollOutcome) : FlowWaitStep
    data class Failed(val code: String) : FlowWaitStep
    /** #410：3 分钟没有新的文件字节——主动断开，路径失败。 */
    object Stalled : FlowWaitStep
    object KeepWaitingForPush : FlowWaitStep
    object CheckStatusNow : FlowWaitStep
}

/**
 * - push 优先：Delivered → 结账；Failed(code) → 按 code 分类。
 * - 本地终态（Completed / Aborted / NoLease）→ 问桌面要持久回执，绝不拿本地信号当回执。
 * - 进行中：
 *   - 字节停滞 ≥ [byteStallThresholdMs]（从最后一次字节前进算；还没有字节就从这次尝试开始算）→ [FlowWaitStep.Stalled]。
 *     连接类事件不刷新这个计时（原生侧保证），relay 限流时字节仍在走，不会误杀。
 *     执行方裁定：「没人来连、桌面一直说 active」也受这条约束——否则 FGS 可以无上限地挂着一张不动的照片。
 *   - 连着 → 安静等推送。
 *   - 没连着且空闲 ≥ [idleStallThresholdMs]（15s）→ 问桌面；回 active 就继续等。
 */
internal fun flowWaitStep(
    pushed: FlowPushOutcome?,
    localStatus: TransferStatus,
    idleStallThresholdMs: Long,
    byteStallThresholdMs: Long,
    attemptElapsedMs: Long,
): FlowWaitStep {
    when (pushed) {
        is FlowPushOutcome.Delivered -> return FlowWaitStep.Resolved(FlowStatusPollOutcome.Completed(pushed.receipt))
        is FlowPushOutcome.Failed -> return FlowWaitStep.Failed(pushed.code)
        null -> {}
    }
    return when (localStatus) {
        is TransferStatus.Completed, is TransferStatus.Aborted -> FlowWaitStep.CheckStatusNow
        TransferStatus.NoLease -> FlowWaitStep.CheckStatusNow
        is TransferStatus.InProgress -> {
            val sinceBytes = localStatus.byteIdleForMs ?: attemptElapsedMs
            when {
                sinceBytes >= byteStallThresholdMs -> FlowWaitStep.Stalled
                localStatus.connected -> FlowWaitStep.KeepWaitingForPush
                (localStatus.idleForMs ?: attemptElapsedMs) >= idleStallThresholdMs -> FlowWaitStep.CheckStatusNow
                else -> FlowWaitStep.KeepWaitingForPush
            }
        }
    }
}

/** NET-06: status-poll backoff — starts fast, settles at the ceiling, never grows unbounded. */
internal fun nextStatusPollDelayMs(pollIndex: Int): Long =
    STATUS_POLL_DELAYS_MS.getOrElse(pollIndex) { STATUS_POLL_DELAYS_MS.last() }

private val STATUS_POLL_DELAYS_MS = longArrayOf(1_000, 2_000, 3_000, 5_000, 8_000)

/** A run of this many consecutive status round-trip failures gives up on this attempt (path failure). */
internal const val STATUS_POLL_MAX_CONSECUTIVE_FAILURES = 5

/** #410：没人来连多久就去问桌面（原 30s 降到 15s）。 */
internal const val LOCAL_IDLE_STALL_THRESHOLD_MS = 15_000L

/** #410：连接还在但多久没有新的文件字节就判路径失败。 */
internal const val BYTE_STALL_THRESHOLD_MS = 180_000L

/** NET-14: how often the wait loop re-reads the local iroh-blobs signal (local field read, no network). */
internal const val LOCAL_STATUS_RECHECK_MS = 500L
