// REBUILD-03 / ARCH-13 (#417) → #413: phone-side adapter from one order to a Desktop receipt.
//
// #417 的改动：
// - queue_sequence / lease_token 由 order 行 id 填（线协议不改）。
// - 回调风格改成挂起函数，结局按 #410 分类返回（路径 / 单张 / 对端），不再是一种「失败」。
// - #410 参数：15 秒没人来连 → 去问桌面，回 active 就继续等；3 分钟没有新的文件字节 → 主动断开，路径失败。
// - 不直接碰 android.util.Log / SystemClock：日志和时钟都注入，整条等待循环能在 JVM 上用虚拟时间测。
//
// #413 的改动（契约 §5）：
// - 暂停 / FGS 被收 / 断网（协程取消）改发 `flow.suspend`：同步、不可取消、限时约 3 秒。**不再发 `flow.cancel`**
//   ——它让桌面把 grant 标成 cancelled，半截失去 GC 保护。丢弃半截只走 [NativeFlowDeliveryPort.discardPartial]
//   （`flow.cancel_tuple`）。
// - 推送订阅每轮一条（[NativeFlowDeliveryPort.session]）：首张 offer 前限时等订阅就绪，缓冲无界，按 tuple 过滤。
// - 错误码按契约重新分类：storage_full / library_unavailable / storage_failed → 对端失败；fetch_failed → 路径失败；
//   provider 上线超时 → 路径失败；导入 hash 与声明的对不上 → 源已删（不计失败）。
// - offer 带 `size_bytes`，桌面按它预检剩余空间。
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
import com.hawkeyexb.ppass.proto.HelloHealth
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.transport.CallTrace
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PeerAddrParts
import java.util.concurrent.TimeoutException
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
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
     * DIAG-A：`hello` 探测，把这次往返的逐阶段记录交给 [trace]（只有真实客户端有）。
     * #413：顺带带回桌面健康（契约 §5 的 `health`；旧桌面没有 → null）。
     */
    suspend fun probeHello(trace: (CallTrace) -> Unit): Hello = Hello(pairingEpoch = currentPairingEpoch())

    /**
     * NET-24: returns the same [FlowStatusReply] a [status] call issued right now would return.
     * `state == "active"` is the genuinely-async case (go wait); a terminal state means the daemon
     * already finished (NET-20 content dedup or NET-22 rebind).
     */
    suspend fun offer(request: FlowFetchRequest): FlowStatusReply

    /** NET-06: read-only control-plane query for one exact tuple. */
    suspend fun status(tuple: FlowTupleRef): FlowStatusReply

    /** NET-06 / #413：`flow.suspend`——打断桌面的拉取任务，grant 保持 active（半截受保护，续传只补缺的）。 */
    suspend fun suspendFetch(tuple: FlowTupleRef)
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

    override suspend fun probeHello(trace: (CallTrace) -> Unit): Hello {
        val response = client.callTraced(peer, Methods.HELLO, buildJsonObject {}, trace)
        if (!response.ok) throw DesktopRejectedException(response.error?.msgKey, "hello")
        return ProtoJson.decodeFromJsonElement(Hello.serializer(), checkNotNull(response.result))
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

    override suspend fun suspendFetch(tuple: FlowTupleRef) = client.flowSuspend(peer, tuple)
}

/** `hello` 的 `health` → 共享类型。旧桌面不带 → null（视为健康）。 */
internal fun desktopHealthOf(health: HelloHealth?): DesktopHealth? =
    health?.let { DesktopHealth(freeBytes = it.freeBytes, libraryWritable = it.libraryWritable, indexOk = it.indexOk) }

/**
 * #413 契约 §5：桌面失败码（`flow.failed` 推送的 code、offer 被拒的 msgKey）的分类。
 * - `storage_full` / `library_unavailable` / `storage_failed` → 对端失败：退出循环，不计次数，原因带回手机显示。
 * - `fetch_failed`（拉不到——relay 限流、断网、对端忙）→ 路径失败：保持可续传，不计次数。
 * - 其它（含旧桌面的 `materialize_*`）→ null，由调用方当单张失败（计次数、有上限——不会无限重试）。
 */
internal fun classifyDesktopCode(code: String?): DeliveryOutcome? = when (code) {
    "storage_full" -> DeliveryOutcome.PeerFailure(PeerFailureKind.STORAGE_FULL, code)
    "library_unavailable" -> DeliveryOutcome.PeerFailure(PeerFailureKind.LIBRARY_UNAVAILABLE, code)
    "storage_failed" -> DeliveryOutcome.PeerFailure(PeerFailureKind.STORAGE_ERROR, code)
    "fetch_failed" -> DeliveryOutcome.PathFailure(code)
    else -> null
}

/** 推送的 `flow.failed`。 */
internal fun classifyPushedFailure(code: String): DeliveryOutcome =
    classifyDesktopCode(code) ?: DeliveryOutcome.ItemFailure("pushed:$code")

/**
 * 传输过程中抛出的异常的分类。桌面可达且明确拒绝（[DesktopRejectedException]）不是路径问题：
 * 当路径失败会让一条坏请求每次都把循环停下、且永不计次数。
 */
internal fun classifyDeliveryFailure(failure: Throwable): DeliveryOutcome = when {
    failure is DesktopRejectedException && failure.msgKey?.let(::isPairingLostText) == true -> DeliveryOutcome.PairingLost
    failure is DesktopRejectedException -> classifyDesktopCode(failure.msgKey) ?: DeliveryOutcome.ItemFailure("rejected:${failure.msgKey}")
    failure is FlowPushedFailureException -> classifyPushedFailure(failure.code)
    failure is IllegalArgumentException || failure is IllegalStateException ->
        DeliveryOutcome.ItemFailure("invalid:${failure.javaClass.simpleName}")
    else -> DeliveryOutcome.PathFailure("network:${failure.javaClass.simpleName}")
}

/**
 * 原生 provider 供数（导入 / 出 ticket）失败的分类：
 * - 原图没了；或导入出来的 hash 与这张 order 记的对不上（导入之后又被编辑）→ 源已删，不计失败。
 * - provider 端点在限时内没上线（`wait_online`）→ 路径失败：网络问题，不是这张照片的问题。
 * - 其它 → 单张失败。
 */
internal fun classifyProviderFailure(failure: Throwable): DeliveryOutcome {
    val message = failure.message.orEmpty()
    return when {
        failure is SourceMissingException || failure is SourceChangedException -> DeliveryOutcome.SourceMissing
        message.contains("does not match its declared content hash") -> DeliveryOutcome.SourceMissing
        failure is ProviderOfflineException || failure is TimeoutException -> DeliveryOutcome.PathFailure("provider_offline")
        message.contains("did not become online") -> DeliveryOutcome.PathFailure("provider_offline")
        else -> DeliveryOutcome.ItemFailure("provider:${failure.javaClass.simpleName}")
    }
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
    /**
     * NET-14 push subscription (`timeline.subscribe`); suspends until the stream ends.
     * 第二个参数在订阅确认帧到达时调用（DIAG-B：区分「连上了」和「还在连」）。
     * 实现要自己保证客户端已 bind：它在每轮开头就起，不一定排在某次 [desktopFor] 之后。
     */
    private val subscribe: suspend (Pairing, () -> Unit, (String, JsonObject) -> Unit) -> Unit,
    /** NET-06: `flow.cancel_tuple` for discarding a partial. */
    private val cancelTuple: suspend (Pairing, FlowTupleRef) -> Unit,
    /**
     * 这一张的 ticket：#413 契约 §4，准备阶段已由 [MediaImporter.import] 导入，这里只以这张 order 的 lease 供数
     * （生产是 `importer.serve(lease)`，它把 lease 设为桥的当前 lease——[IrohBlobsProviderBridge.transferStatus] /
     * [IrohBlobsProviderBridge.pause] 靠它）。
     */
    private val serve: (ProviderLease, DeliveryRequest) -> String = { lease, _ -> bridge.serve(lease) },
    /** 已确认（含桌面「已有」）：放掉供数占用与导入。不许抛。 */
    private val release: (ProviderLease) -> Unit = { lease ->
        runCatching { bridge.releaseRetention(lease) }
        runCatching { bridge.release(lease.contentHash) }
    },
    private val log: FlowLogger = FlowLogger { },
    /** 单调时钟（ms）。生产是 SystemClock.elapsedRealtime。 */
    private val clock: () -> Long = System::nanoTime.let { nano -> { nano() / 1_000_000 } },
    /** 发给桌面的控制面请求（suspend / cancel_tuple）跑在这里，调用方只有界地等结果。 */
    private val sideEffects: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val idleStallThresholdMs: Long = LOCAL_IDLE_STALL_THRESHOLD_MS,
    private val byteStallThresholdMs: Long = BYTE_STALL_THRESHOLD_MS,
    private val subscriptionRetryDelaysMs: LongArray = SUBSCRIPTION_RETRY_DELAYS_MS,
    private val subscriptionReadyTimeoutMs: Long = SUBSCRIPTION_READY_TIMEOUT_MS,
    private val controlCallTimeoutMs: Long = CONTROL_CALL_TIMEOUT_MS,
) : ItemDelivery {
    private val epochGuard = FlowDeliveryEpochGuard(pairing)

    /** 一轮的推送订阅：缓冲无界（整轮共用，旧 tuple 的推送不许把要等的那条挤掉），按 tuple 过滤。 */
    private class Round(val pairing: Pairing) {
        val events = Channel<Pair<String, JsonObject>>(Channel.UNLIMITED)
        val connected = CompletableDeferred<Unit>()

        /** 首张 offer 之前等过订阅就绪了没有（只等一次）。 */
        var readyAwaited = false
    }

    @Volatile private var round: Round? = null

    override suspend fun <T> session(block: suspend () -> T): T {
        val currentPairing = pairing() ?: return block()
        return coroutineScope {
            val r = Round(currentPairing)
            // 推送只是加速，不是唯一路径：订阅失败不致命，本地信号 + status() 兜底。断了按退避重建。
            val subscription = launch { keepSubscribed(r) }
            round = r
            try {
                block()
            } finally {
                if (round === r) round = null
                subscription.cancel()
            }
        }
    }

    override suspend fun deliver(request: DeliveryRequest, onProgress: (Long) -> Unit): DeliveryOutcome {
        // 没有外层会话（单测直接调、或调用方没开轮）：这一张自己开一条订阅。
        val r = round ?: return session { deliverIn(checkNotNull(round), request, onProgress) }
        return deliverIn(r, request, onProgress)
    }

    private suspend fun deliverIn(r: Round, request: DeliveryRequest, onProgress: (Long) -> Unit): DeliveryOutcome {
        val currentPairing = pairing() ?: return DeliveryOutcome.PairingLost
        if (currentPairing.pairingEpoch != request.pairingEpoch.value) return DeliveryOutcome.PathFailure("epoch_changed")
        val lease = ProviderLease(request.orderId, request.leaseToken, request.contentHash)
        val ticket = try {
            serve(lease, request)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            return classifyProviderFailure(failure).also {
                log.log("order ${request.orderId}: provider serve failed -> $it (${failure.javaClass.simpleName}: ${failure.message})")
            }
        }
        // 大文件的导入会阻塞很久：它返回之后、offer 之前再看一眼是不是已经被暂停 / 取消了。
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
            sizeBytes = request.details.sizeBytes.coerceAtLeast(0L),
        )
        val tuple = FlowTupleRef(queueSequence = fetch.queueSequence, pairingEpoch = fetch.pairingEpoch, leaseToken = fetch.leaseToken)
        var desktop: FlowReceiptClient? = null
        return try {
            val client = desktopFor(currentPairing).also { desktop = it }
            if (!r.readyAwaited) {
                // 推送可能早于订阅建立，桌面的 broadcast 不重放：首张 offer 之前限时等订阅就绪（超时照样继续，status 兜底）。
                r.readyAwaited = true
                val ready = withTimeoutOrNull(subscriptionReadyTimeoutMs) { r.connected.await() } != null
                if (!ready) log.log("Flow push subscription not ready within ${subscriptionReadyTimeoutMs}ms; offering anyway")
            }
            // 整轮共用一条订阅：offer 之前积压的都是别的 tuple / 上一次尝试的，丢掉。
            while (r.events.tryReceive().isSuccess) Unit
            val offerAt = clock()
            log.log("Flow offer sent seq=${fetch.queueSequence} sizeBytes=${fetch.sizeBytes}")
            val offerReply = client.offer(fetch)
            log.log("Flow offer replied seq=${fetch.queueSequence} state=${offerReply.state} inMs=${clock() - offerAt}")
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
            waitForCompletion(r, client, fetch, tuple, lease, request.pairingEpoch, onProgress)
        } catch (cancelled: CancellationException) {
            // 暂停 / FGS 被收走 / 断网：停掉原生传输，再同步、有界地告诉桌面「先停，别丢」（flow.suspend）。
            // 半截在桌面保持受保护，续传只补缺的。取消本身照样抛出去。
            withContext(NonCancellable) {
                runCatching { bridge.pause(lease) }
                desktop?.let { d -> boundedControlCall("flow.suspend", fetch.queueSequence) { d.suspendFetch(tuple) } }
            }
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

    /**
     * 控制面请求只**有界地**等：`DaemonClient.call` 是阻塞 FFI + 15 秒连接超时，直接包 withTimeout 不一定按时返回。
     * 所以请求跑在 [sideEffects] 上，这里只限时等它的结果；超时就不等了（请求自己跑完或失败）。
     */
    private suspend fun boundedControlCall(label: String, seq: Long, call: suspend () -> Unit) {
        val job = sideEffects.async { runCatching { call() } }
        val result = withTimeoutOrNull(controlCallTimeoutMs) { job.await() }
        when {
            result == null -> log.log("$label seq=$seq: no reply within ${controlCallTimeoutMs}ms; not waiting")
            result.isFailure -> log.log("$label seq=$seq failed: ${result.exceptionOrNull()?.javaClass?.simpleName}: ${result.exceptionOrNull()?.message}")
            else -> log.log("$label seq=$seq sent")
        }
    }

    private suspend fun waitForCompletion(
        r: Round,
        desktop: FlowReceiptClient,
        fetch: FlowFetchRequest,
        tuple: FlowTupleRef,
        lease: ProviderLease,
        epoch: PairingEpoch,
        onProgress: (Long) -> Unit,
    ): DeliveryOutcome {
        // NET-06/NET-14: priority order — push, then local iroh-blobs signal, then a bounded status() check.
        val seq = fetch.queueSequence
        var pollDelayIndex = 0
        var consecutiveStatusFailures = 0
        var lastBytes = -1L
        val attemptStartedAt = clock()
        var localDoneAt: Long? = null
        while (true) {
            if (!epochGuard.isCurrent(epoch)) {
                bridge.pause(lease)
                return DeliveryOutcome.PathFailure("epoch_changed")
            }
            // 按 tuple 过滤：不是这一张的推送直接丢（整轮共用一条订阅）。
            var pushed: FlowPushOutcome? = null
            while (pushed == null) {
                val (kind, data) = r.events.tryReceive().getOrNull() ?: break
                pushed = parseFlowPushOutcome(kind, data, tuple)
                log.log("Flow push received kind=$kind seq=$seq matched=${pushed != null} elapsedMs=${clock() - attemptStartedAt}")
            }
            val local = bridge.transferStatus()
            // #413：引用的原图在供数期间被删 / 被改。桌面那边只会报 fetch_failed（流被重置），所以要先看这里，
            // 否则会被误判为路径失败、下一轮又续传同一份坏内容。桌面已经回了完整回执的除外（它按 BLAKE3 校验过）。
            val fault = (local as? TransferStatus.Aborted)?.source ?: (local as? TransferStatus.InProgress)?.source
            if (fault != null && pushed !is FlowPushOutcome.Delivered) {
                log.log("order $seq: source ${fault.name.lowercase()} while serving; abandoning as source missing")
                bridge.pause(lease)
                return DeliveryOutcome.SourceMissing
            }
            if (localDoneAt == null && (local is TransferStatus.Completed || local is TransferStatus.Aborted)) {
                localDoneAt = clock()
                log.log("Flow local transfer ended seq=$seq local=$local elapsedMs=${localDoneAt - attemptStartedAt}; waiting for desktop receipt")
            }
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
                        log.log("Flow resolved by=push seq=$seq")
                        return accept(outcome.receipt, fetch, lease)
                    }
                    FlowStatusPollOutcome.Cancelled -> {
                        bridge.pause(lease)
                        return DeliveryOutcome.PathFailure("cancelled")
                    }
                    FlowStatusPollOutcome.KeepPolling -> continue
                }
                is FlowWaitStep.Failed -> {
                    bridge.pause(lease)
                    return classifyPushedFailure(step.code)
                }
                FlowWaitStep.Stalled -> {
                    // #410：连接还在、3 分钟没有新的文件字节 → 主动断开，路径失败。
                    log.log("order $seq: no new file bytes for ${byteStallThresholdMs}ms; disconnecting")
                    bridge.pause(lease)
                    return DeliveryOutcome.PathFailure("byte_stall")
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
                        log.log("Flow status poll failed seq=$seq #$consecutiveStatusFailures (${failure.javaClass.simpleName}: ${failure.message})")
                        if (consecutiveStatusFailures >= STATUS_POLL_MAX_CONSECUTIVE_FAILURES) throw failure
                        delay(nextStatusPollDelayMs(pollDelayIndex++))
                        continue
                    }
                    consecutiveStatusFailures = 0
                    when (val outcome = flowStatusPollOutcome(reply)) {
                        is FlowStatusPollOutcome.Completed -> {
                            val sinceLocal = localDoneAt?.let { clock() - it }
                            log.log("Flow resolved by=status seq=$seq local=$local elapsedMs=$elapsed sinceLocalDoneMs=${sinceLocal ?: "-"} subscription=${subscriptionState.name}")
                            return accept(outcome.receipt, fetch, lease)
                        }
                        FlowStatusPollOutcome.Cancelled -> {
                            bridge.pause(lease)
                            return DeliveryOutcome.PathFailure("cancelled")
                        }
                        // #410：桌面回 active 就继续等，不判失败（字节停滞由 Stalled 兜底）。
                        FlowStatusPollOutcome.KeepPolling -> {
                            val next = nextStatusPollDelayMs(pollDelayIndex++)
                            log.log("Flow status poll seq=$seq state=${reply.state} elapsedMs=$elapsed local=$local subscription=${subscriptionState.name} nextInMs=$next")
                            delay(next)
                        }
                    }
                }
            }
        }
    }

    /** DIAG-B：订阅此刻的状态，写进 status 兜底那几行日志——推送丢了的时候一眼看出订阅在不在。 */
    private enum class SubscriptionState { CONNECTING, CONNECTED, DOWN }

    @Volatile private var subscriptionState = SubscriptionState.DOWN

    /**
     * DIAG-B：保持这一轮的推送订阅一直在。订阅流结束（正常结束或抛错）就按 [subscriptionRetryDelaysMs]
     * 退避重建，直到 [session] 结束取消它。建立 / 断开 / 重建各一行日志。
     * 取消必须原样抛出：吞掉它等于这一轮结束了还在后台一直重连。
     */
    private suspend fun keepSubscribed(r: Round) {
        var attempt = 0
        val roundStartedAt = clock()
        while (true) {
            if (attempt > 0) log.log("Flow push subscription rebuild #$attempt")
            val startedAt = clock()
            subscriptionState = SubscriptionState.CONNECTING
            val reason = try {
                subscribe(r.pairing, {
                    subscriptionState = SubscriptionState.CONNECTED
                    r.connected.complete(Unit)
                    log.log("Flow push subscription connected attempt=$attempt inMs=${clock() - startedAt} sinceRoundStartMs=${clock() - roundStartedAt}")
                }) { kind, data -> r.events.trySend(kind to data) }
                "stream_ended"
            } catch (cancelled: CancellationException) {
                subscriptionState = SubscriptionState.DOWN
                throw cancelled
            } catch (failure: Throwable) {
                "${failure.javaClass.simpleName}: ${failure.message}"
            }
            subscriptionState = SubscriptionState.DOWN
            val retryIn = subscriptionRetryDelaysMs.getOrElse(attempt) { subscriptionRetryDelaysMs.last() }
            log.log("Flow push subscription closed attempt=$attempt afterMs=${clock() - startedAt} reason=$reason; retry in ${retryIn}ms")
            delay(retryIn)
            attempt++
        }
    }

    private fun accept(receipt: FlowCompletionReceipt, fetch: FlowFetchRequest, lease: ProviderLease): DeliveryOutcome {
        val completed = relayFlowCompletion(receipt, fetch)
        // BLOB-03: release provider retention only at the validated success boundary.
        runCatching { release(lease) }
        return DeliveryOutcome.Confirmed(completed)
    }

    override suspend fun discardPartial(orderId: Long, pairingEpoch: PairingEpoch) {
        val currentPairing = pairing() ?: return
        val tuple = FlowTupleRef(queueSequence = orderId, pairingEpoch = pairingEpoch.value, leaseToken = leaseTokenFor(orderId))
        withContext(NonCancellable) { boundedControlCall("flow.cancel_tuple", orderId) { cancelTuple(currentPairing, tuple) } }
    }
}

/** `hello` 探测（有超时）：桌面可达吗、它现在的配对代号是什么、它健不健康（#413 契约 §5）。 */
internal class DaemonDesktopProbe(
    private val pairing: () -> Pairing?,
    private val desktopFor: suspend (Pairing) -> FlowReceiptClient,
    private val timeoutMs: Long = PROBE_TIMEOUT_MS,
    private val log: FlowLogger = FlowLogger { },
    private val clock: () -> Long = System::nanoTime.let { nano -> { nano() / 1_000_000 } },
) : DesktopProbe {
    /**
     * DIAG-A：每次探测一行 `Flow probe result=…`：总耗时、`desktopFor`（含 endpoint bind）耗时，以及
     * 真实客户端给的逐阶段记录（[CallTrace.render]）。注意实际上限通常是 DaemonClient 自己的 15 秒
     * （`CONNECT_TIMEOUT_MS`，抛 DaemonUnreachableException），不是这里的 [timeoutMs]。
     */
    override suspend fun probe(): ProbeResult {
        val current = pairing() ?: return ProbeResult.PairingLost
        val started = clock()
        var bindMs: Long? = null
        var trace: CallTrace? = null
        fun report(result: String, failure: Throwable?) {
            val cause = failure?.let { " error=${it.javaClass.simpleName}: ${it.message}" }.orEmpty()
            log.log("Flow probe result=$result totalMs=${clock() - started} bindMs=${bindMs ?: "-"} ${trace?.render() ?: "trace=-"}$cause")
        }
        return try {
            withTimeout(timeoutMs) {
                val client = desktopFor(current)
                bindMs = clock() - started
                val hello = client.probeHello { trace = it }
                ProbeResult.Reachable(hello.pairingEpoch, desktopHealthOf(hello.health))
            }.also { report("reachable", null) }
        } catch (rejected: DesktopRejectedException) {
            report("rejected:${rejected.msgKey}", rejected)
            if (rejected.msgKey?.let(::isPairingLostText) == true) ProbeResult.PairingLost else ProbeResult.Unreachable
        } catch (cancelled: CancellationException) {
            // withTimeout 的超时也是 CancellationException——区分「我被取消了」与「对端没回」。
            currentCoroutineContext().ensureActive()
            report("unreachable:probe_timeout_${timeoutMs}ms", cancelled)
            ProbeResult.Unreachable
        } catch (failure: Throwable) {
            report("unreachable", failure)
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

/** DIAG-B：推送订阅断开后的重建退避（封顶 10s，不无限增长）。 */
internal val SUBSCRIPTION_RETRY_DELAYS_MS = longArrayOf(1_000, 2_000, 5_000, 10_000)

/** NET-14: how often the wait loop re-reads the local iroh-blobs signal (local field read, no network). */
internal const val LOCAL_STATUS_RECHECK_MS = 500L

/** #413：每轮首张 offer 之前最多等订阅就绪多久（超时照样 offer，status 兜底）。 */
internal const val SUBSCRIPTION_READY_TIMEOUT_MS = 2_000L

/** #413：`flow.suspend` / `flow.cancel_tuple` 这类控制面请求最多等多久（暂停不能被一次 15 秒的连接超时卡住）。 */
internal const val CONTROL_CALL_TIMEOUT_MS = 3_000L
