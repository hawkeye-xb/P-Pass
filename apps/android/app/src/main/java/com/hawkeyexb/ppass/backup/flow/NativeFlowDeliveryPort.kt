// REBUILD-03: phone-side adapter from one leased Flow item to Desktop receipt.
package com.hawkeyexb.ppass.backup.flow

import android.content.ContentResolver
import android.net.Uri
import android.util.Log
import com.hawkeyexb.ppass.backup.isPairingLostText
import com.hawkeyexb.ppass.proto.FlowCompletionReceipt
import com.hawkeyexb.ppass.proto.FlowAuditAccepted
import com.hawkeyexb.ppass.proto.FlowAuditEvent
import com.hawkeyexb.ppass.proto.FlowAuditSubmit
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
import io.github.rctcwyvrn.blake3.Blake3
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.channels.Channel
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import java.io.FileNotFoundException

/** A discovered MediaStore URI disappeared; retrying cannot recreate it. */
internal class SourceMissingException(cause: Throwable? = null) : Exception(cause)

/** The only Desktop interaction accepted by the Android Flow delivery port. */
internal interface FlowReceiptClient {
    suspend fun currentPairingEpoch(): String?
    suspend fun offer(request: FlowFetchRequest)
    /**
     * NET-06: read-only control-plane query for one exact tuple. Every
     * network condition answers within the ordinary control RPC timeout
     * — this never waits on the data plane, unlike the old blocking
     * [fetch]. [NativeFlowDeliveryPort] polls this instead of betting an
     * entire transfer's outcome on one long round trip returning in time
     * (NET-01's root cause).
     */
    suspend fun status(tuple: FlowTupleRef): FlowStatusReply
    suspend fun fetch(request: FlowFetchRequest): FlowCompletionReceipt
    suspend fun cancel(request: FlowFetchRequest)
}

/** AUDIT-01: the one daemon interaction the audit outbox dispatcher needs. */
internal interface FlowAuditTransport {
    suspend fun submit(events: List<AuditOutboxEvent>): FlowAuditAccepted
}

/** Ctrl-plane adapter for [FlowAuditTransport] — no native transport involved. */
internal class DaemonFlowAuditTransport(
    private val client: DaemonClient,
    private val peer: PeerAddrParts,
) : FlowAuditTransport {
    override suspend fun submit(events: List<AuditOutboxEvent>): FlowAuditAccepted {
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
 * AUDIT-01: the phone-side delivery leg for the durable ledger audit
 * outbox. Drains [DiscoveryLedgerStore]'s `auditOutbox` to the daemon over
 * `flow.audit.submit`, acknowledging exactly the event ids the daemon
 * confirmed durable — anything the daemon didn't report back (network
 * failure, malformed event, connection never established) is left in the
 * outbox for the next flush to retry, per the card's durable-outbox
 * contract (never drop on send, only on confirmed daemon receipt).
 */
internal class AuditOutboxDispatcher(
    private val ledger: DiscoveryLedgerStore,
    private val pairing: () -> Pairing?,
    private val identityKey: () -> ByteArray,
    private val client: DaemonClient,
    /** Seam for tests: production binds the real client and builds a
     *  [DaemonFlowAuditTransport]; tests supply a fake transport without
     *  ever touching [DaemonClient.bind] (which opens a real iroh
     *  endpoint and is unsafe to call unconditionally in a JVM test). */
    private val transportFor: suspend (Pairing) -> FlowAuditTransport = { currentPairing ->
        client.bind(identityKey())
        DaemonFlowAuditTransport(client, parsePeerAddrToken(currentPairing.daemonAddrToken))
    },
) {
    /** Best-effort: any failure (offline, unpaired, IO) leaves the outbox
     *  untouched — there is always a next trigger to retry from. */
    suspend fun flush() {
        val outbox = ledger.load().auditOutbox
        if (outbox.isEmpty()) return
        val currentPairing = pairing() ?: return
        runCatching {
            transportFor(currentPairing).submit(outbox)
        }.onSuccess { accepted ->
            if (accepted.eventIds.isNotEmpty()) {
                ledger.acknowledgeAuditEvents(accepted.eventIds.toSet())
            }
        }
        // A failed flush (offline, transient daemon error, epoch stale)
        // intentionally logs nothing here: the outbox is untouched and the
        // next trigger retries it, so there is no new fact to record. This
        // also keeps the method callable from a JVM unit test without a
        // mocked android.util.Log.
    }
}

/** Keeps an in-flight delivery from crossing into a newly paired Desktop epoch. */
internal class FlowDeliveryEpochGuard(private val pairing: () -> Pairing?) {
    fun isCurrent(expectedEpoch: PairingEpoch): Boolean = pairing()?.pairingEpoch == expectedEpoch.value

    fun refreshedEpoch(advertisedEpoch: String?): PairingEpoch? {
        val currentEpoch = pairing()?.pairingEpoch ?: return null
        return advertisedEpoch?.takeIf { it.isNotBlank() && it != currentEpoch }?.let(::PairingEpoch)
    }
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

/** Validates a Desktop receipt then routes it through the owning Flow runner. */
internal fun relayFlowCompletion(
    receipt: FlowCompletionReceipt,
    request: FlowFetchRequest,
    onReceipt: (CompletionReceipt) -> Unit,
) {
    require(receipt.queueSequence == request.queueSequence)
    require(receipt.pairingEpoch == request.pairingEpoch)
    require(receipt.leaseToken == request.leaseToken)
    require(receipt.contentHash == request.contentHash)
    onReceipt(
        CompletionReceipt(
            queueSequence = receipt.queueSequence,
            receiptId = receipt.receiptId,
            pairingEpoch = PairingEpoch(receipt.pairingEpoch),
            leaseToken = receipt.leaseToken,
            contentHash = receipt.contentHash,
        ),
    )
}

/** Ctrl-plane adapter; data stays on native iroh-blobs through the ticket. */
internal class DaemonFlowReceiptClient(
    private val client: DaemonClient,
    private val peer: PeerAddrParts,
) : FlowReceiptClient {
    override suspend fun currentPairingEpoch(): String? {
        val response = client.call(peer, Methods.HELLO, buildJsonObject {})
        check(response.ok) { "hello: ${response.error?.msgKey}" }
        return ProtoJson.decodeFromJsonElement(Hello.serializer(), checkNotNull(response.result)).pairingEpoch
    }

    override suspend fun offer(request: FlowFetchRequest) {
        val response = client.call(peer, Methods.FLOW_OFFER, ProtoJson.encodeToJsonElement(FlowFetchRequest.serializer(), request))
        check(response.ok) { "flow.offer: ${response.error?.msgKey}" }
    }

    override suspend fun status(tuple: FlowTupleRef): FlowStatusReply {
        val response = client.call(peer, Methods.FLOW_STATUS, ProtoJson.encodeToJsonElement(FlowTupleRef.serializer(), tuple))
        check(response.ok) { "flow.status: ${response.error?.msgKey}" }
        return ProtoJson.decodeFromJsonElement(FlowStatusReply.serializer(), checkNotNull(response.result))
    }

    override suspend fun fetch(request: FlowFetchRequest): FlowCompletionReceipt {
        val response = client.call(peer, Methods.FLOW_FETCH, ProtoJson.encodeToJsonElement(FlowFetchRequest.serializer(), request))
        check(response.ok) { "flow.fetch: ${response.error?.msgKey}" }
        return ProtoJson.decodeFromJsonElement(FlowCompletionReceipt.serializer(), checkNotNull(response.result))
    }

    override suspend fun cancel(request: FlowFetchRequest) {
        val response = client.call(peer, Methods.FLOW_CANCEL, ProtoJson.encodeToJsonElement(FlowFetchRequest.serializer(), request))
        check(response.ok) { "flow.cancel: ${response.error?.msgKey}" }
    }
}

/**
 * Registers precisely the strict head with Android's native provider, then asks
 * Desktop to offer and fetch that exact ticket. Receipt fields are checked again
 * before they are allowed to mutate the ledger.
 */
internal class NativeFlowDeliveryPort(
    private val ledger: DiscoveryLedgerStore,
    private val bridge: IrohBlobsProviderBridge,
    private val resolver: ContentResolver,
    private val pairing: () -> Pairing?,
    private val identityKey: () -> ByteArray,
    private val client: DaemonClient,
    private val onMissingSource: () -> Unit,
    private val onPermanentFailure: () -> Unit,
    private val onReceipt: (CompletionReceipt) -> Unit,
    private val onPairingEpochRefreshed: (PairingEpoch) -> Unit,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    /** Seam for tests: production binds the real client and builds a
     *  [DaemonFlowReceiptClient]; tests supply a fake that never touches
     *  [DaemonClient.bind] (which opens a real iroh endpoint and is unsafe
     *  to call unconditionally in a JVM test). Same pattern as
     *  [AuditOutboxDispatcher.transportFor]. */
    private val desktopFor: suspend (Pairing) -> FlowReceiptClient = { currentPairing ->
        client.bind(identityKey())
        DaemonFlowReceiptClient(client, parsePeerAddrToken(currentPairing.daemonAddrToken))
    },
) : DeliveryPort {
    private var active: ActiveDelivery? = null
    private val epochGuard = FlowDeliveryEpochGuard(pairing)

    override fun start(item: TransferItem, resumePartial: Boolean, lease: FetchLease) {
        val currentPairing = requireNotNull(pairing()) { "Flow delivery requires an active pairing" }
        val epoch = PairingEpoch(currentPairing.pairingEpoch)
        require(epoch == item.pairingEpoch) { "item is not in the current pairing epoch" }
        val hashed: TransferItem
        val ticket: String
        try {
            hashed = item.copy(contentHash = item.contentHash ?: hashSource(item.sourceRef))
            ledger.update { snapshot ->
                snapshot.copy(items = snapshot.items.map { candidate ->
                    if (candidate.queueSequence == item.queueSequence) hashed else candidate
                })
            }
            ticket = bridge.register(hashed, epoch, lease)
        } catch (_: SourceMissingException) {
            Log.i("PPassFlow", "Flow source disappeared before it could be sent; skipping strict head")
            onMissingSource()
            return
        } catch (failure: Throwable) {
            Log.e("PPassFlow", "Could not prepare native Flow delivery; preserving the strict head for retry", failure)
            onPermanentFailure()
            return
        }
        val request = FlowFetchRequest(
            queueSequence = hashed.queueSequence,
            pairingEpoch = epoch.value,
            leaseToken = lease.leaseToken,
            contentHash = requireNotNull(hashed.contentHash),
            fileName = hashed.fileName.ifBlank { hashed.sourceRef.substringAfterLast('/') },
            mediaType = hashed.mediaType,
            provider = ticket,
            captureAtMs = hashed.captureAtMs,
        )
        active = ActiveDelivery(lease, request)
        scope.launch {
            try {
                require(epochGuard.isCurrent(epoch)) { "Flow delivery pairing epoch changed before offer" }
                val desktop = desktopFor(currentPairing)
                val advertisedEpoch = desktop.currentPairingEpoch()
                val refreshedEpoch = epochGuard.refreshedEpoch(advertisedEpoch)
                Log.i(
                    "PPassFlow",
                    "Flow epoch preflight: advertised=${!advertisedEpoch.isNullOrBlank()} refresh=${refreshedEpoch != null}",
                )
                refreshedEpoch?.let {
                    bridge.pause(lease)
                    active = null
                    onPairingEpochRefreshed(it)
                    return@launch
                }
                desktop.offer(request)
                // NET-06/NET-14: offer() spawns the background transfer on
                // the daemon and returns immediately. This attempt now
                // waits for one of three signals, in priority order:
                //   1. A `flow.delivered`/`flow.failed` push over a
                //      dedicated timeline.subscribe connection opened just
                //      for this attempt (primary signal — no network call
                //      per check).
                //   2. The phone's OWN local iroh-blobs sender-side event
                //      state (bridge.transferStatus()) — ground truth for
                //      "is anyone still connected / did MY send finish",
                //      sourced from this device's own connection table,
                //      never a guess (NET-14 card).
                //   3. Only when local status shows no live connection and
                //      no push has arrived — a bounded `flow.status()`
                //      control-plane check, exactly the same call the old
                //      pure-polling loop used, kept as the fallback so a
                //      dropped push subscription or a desktop that hasn't
                //      wired events yet still resolves correctly.
                // This loop never calls offer() again, so a flaky network
                // never causes two competing grants for the same tuple.
                val tuple = FlowTupleRef(
                    queueSequence = request.queueSequence,
                    pairingEpoch = request.pairingEpoch,
                    leaseToken = request.leaseToken,
                )
                val pushChannel = Channel<Pair<String, JsonObject>>(capacity = 8)
                val subscriptionJob = launch {
                    runCatching {
                        client.subscribeTimeline(
                            parsePeerAddrToken(currentPairing.daemonAddrToken),
                            onFlowEvent = { kind, data -> pushChannel.trySend(kind to data) },
                            onInvalidated = {},
                        )
                    }
                    // A dropped/failed subscription is not fatal here — the
                    // local-status-driven fallback below still resolves
                    // this attempt; the daemon is just no longer able to
                    // hurry it along with a push (principle: 推送为加速，
                    // 不是唯一路径).
                }
                var pollDelayIndex = 0
                var consecutiveStatusFailures = 0
                lateinit var receipt: FlowCompletionReceipt
                try {
                    while (true) {
                        require(epochGuard.isCurrent(epoch)) { "Flow delivery pairing epoch changed while waiting for completion" }
                        val pushed = pushChannel.tryReceive().getOrNull()
                            ?.let { (kind, data) -> parseFlowPushOutcome(kind, data, tuple) }
                        val localStatus = bridge.transferStatus()
                        when (val step = flowWaitStep(pushed, localStatus, LOCAL_IDLE_STALL_THRESHOLD_MS)) {
                            is FlowWaitStep.Resolved -> {
                                when (val outcome = step.outcome) {
                                    is FlowStatusPollOutcome.Completed -> {
                                        receipt = outcome.receipt
                                    }
                                    FlowStatusPollOutcome.Cancelled -> {
                                        Log.i("PPassFlow", "Flow status reports cancelled; abandoning this delivery attempt")
                                        active = null
                                        return@launch
                                    }
                                    FlowStatusPollOutcome.KeepPolling -> continue
                                }
                            }
                            FlowWaitStep.KeepWaitingForPush -> {
                                // Cheap local-only wait — no network call,
                                // just re-check the local signal shortly.
                                delay(LOCAL_STATUS_RECHECK_MS)
                                continue
                            }
                            FlowWaitStep.CheckStatusNow -> {
                                val reply = try {
                                    desktop.status(tuple)
                                } catch (failure: Throwable) {
                                    // A dead connection or a daemon that is
                                    // momentarily unreachable is not the
                                    // same fact as "the transfer is over" —
                                    // only a bounded run of consecutive
                                    // failures gives up on THIS attempt.
                                    consecutiveStatusFailures += 1
                                    if (consecutiveStatusFailures >= STATUS_POLL_MAX_CONSECUTIVE_FAILURES) throw failure
                                    delay(nextStatusPollDelayMs(pollDelayIndex))
                                    pollDelayIndex += 1
                                    continue
                                }
                                consecutiveStatusFailures = 0
                                when (val outcome = flowStatusPollOutcome(reply)) {
                                    is FlowStatusPollOutcome.Completed -> {
                                        receipt = outcome.receipt
                                    }
                                    FlowStatusPollOutcome.Cancelled -> {
                                        Log.i("PPassFlow", "Flow status reports cancelled; abandoning this delivery attempt")
                                        active = null
                                        return@launch
                                    }
                                    FlowStatusPollOutcome.KeepPolling -> {
                                        delay(nextStatusPollDelayMs(pollDelayIndex))
                                        pollDelayIndex += 1
                                        continue
                                    }
                                }
                            }
                        }
                        break
                    }
                } finally {
                    subscriptionJob.cancel()
                }
                require(epochGuard.isCurrent(epoch)) { "Flow delivery pairing epoch changed before receipt" }
                acceptReceipt(receipt, request)
            } catch (failure: Throwable) {
                if (!epochGuard.isCurrent(epoch)) {
                    Log.i("PPassFlow", "Discarding stale Flow delivery after pairing epoch changed")
                    bridge.pause(lease)
                    active = null
                    return@launch
                }
                Log.e("PPassFlow", "Native Flow delivery failed; preserving the strict head for retry", failure)
                flowDeliveryPairingLoss.record(epoch, failure)
                onPermanentFailure()
            }
        }
    }

    override fun stop(queueSequence: Long): PartialDisposition {
        val current = active?.takeIf { it.lease.queueSequence == queueSequence } ?: return PartialDisposition.RETAINED
        bridge.pause(current.lease)
        scope.launch {
            runCatching {
                val currentPairing = pairing() ?: return@runCatching
                desktopFor(currentPairing).cancel(current.request)
            }
        }
        active = null
        return PartialDisposition.RETAINED
    }

    private fun acceptReceipt(receipt: FlowCompletionReceipt, request: FlowFetchRequest) {
        val current = active
        relayFlowCompletion(receipt, request) { completed ->
            // BLOB-03: the receipt's four fields are already validated by
            // relayFlowCompletion (a mismatch throws before this point), so
            // this is the exact safe success boundary. Release provider
            // retention of the served blob BEFORE the runner callback advances
            // strict head to the next item; the endpoint + ALPN handler stay
            // alive for connection reuse. A rejected/unvalidated receipt never
            // reaches here, so no success release fires on failure.
            current?.let { bridge.releaseRetention(it.lease) }
            onReceipt(completed)
        }
    }

    private fun hashSource(sourceRef: String): String {
        val hasher = Blake3.newInstance()
        try {
            resolver.openInputStream(Uri.parse(sourceRef)).use { input ->
                val presentInput = input ?: throw SourceMissingException()
                val buffer = ByteArray(256 * 1024)
                while (true) {
                    val count = presentInput.read(buffer)
                    if (count < 0) break
                    hasher.update(if (count == buffer.size) buffer else buffer.copyOf(count))
                }
            }
        } catch (failure: FileNotFoundException) {
            throw SourceMissingException(failure)
        }
        return hasher.hexdigest()
    }

    private data class ActiveDelivery(val lease: FetchLease, val request: FlowFetchRequest)
}

/**
 * NET-06: pure decision over one [FlowStatusReply] — extracted so the poll
 * loop's branching is JVM-testable without a coroutine dispatcher or a
 * fake DaemonClient. "not_found" is treated as a genuine failure (the
 * daemon has no record of a grant this same device just offered — that is
 * a real inconsistency, not a transient blip) by throwing, matching the
 * old inline `error(...)` behavior exactly.
 */
internal sealed interface FlowStatusPollOutcome {
    data class Completed(val receipt: FlowCompletionReceipt) : FlowStatusPollOutcome
    object Cancelled : FlowStatusPollOutcome
    object KeepPolling : FlowStatusPollOutcome
}

internal fun flowStatusPollOutcome(reply: FlowStatusReply): FlowStatusPollOutcome =
    when (reply.state) {
        "completed" -> FlowStatusPollOutcome.Completed(
            reply.receipt ?: error("flow.status: completed with no receipt"),
        )
        "cancelled" -> FlowStatusPollOutcome.Cancelled
        "not_found" -> error("flow.status: daemon has no record of our own grant")
        else -> FlowStatusPollOutcome.KeepPolling
    }

/**
 * NET-14: a `flow.delivered`/`flow.failed` push, decoded and matched
 * against the exact tuple this delivery attempt cares about. `null`
 * means "not for us" (kind unrecognized, or the tuple identity in the
 * push doesn't match this attempt's own tuple — e.g. a stale push for a
 * previous attempt still draining through a subscription this attempt
 * inherited) — the caller must keep waiting, not treat it as a signal.
 */
internal sealed interface FlowPushOutcome {
    data class Delivered(val receipt: FlowCompletionReceipt) : FlowPushOutcome
    data class Failed(val code: String) : FlowPushOutcome
}

/** Thrown when the daemon pushes a terminal failure for this exact tuple
 *  (as opposed to a transient status()/connect failure) — carries the
 *  daemon's fixed telemetry code so the log at least names the failure
 *  class instead of a bare generic message. */
internal class FlowPushedFailureException(val code: String) :
    Exception("desktop pushed a terminal flow.failed: $code")

internal fun parseFlowPushOutcome(kind: String, data: JsonObject, tuple: FlowTupleRef): FlowPushOutcome? {
    val queueSequence = (data["queue_sequence"] as? JsonPrimitive)?.content?.toLongOrNull() ?: return null
    val pairingEpoch = (data["pairing_epoch"] as? JsonPrimitive)?.content ?: return null
    val leaseToken = (data["lease_token"] as? JsonPrimitive)?.content ?: return null
    if (queueSequence != tuple.queueSequence ||
        pairingEpoch != tuple.pairingEpoch ||
        leaseToken != tuple.leaseToken
    ) {
        return null
    }
    return when (kind) {
        "flow.delivered" -> {
            val receiptElement = data["receipt"] ?: return null
            FlowPushOutcome.Delivered(
                ProtoJson.decodeFromJsonElement(FlowCompletionReceipt.serializer(), receiptElement),
            )
        }
        "flow.failed" -> FlowPushOutcome.Failed((data["code"] as? JsonPrimitive)?.content ?: "unknown")
        else -> null
    }
}

/**
 * NET-14: the wait loop's next action. Pushes are the primary signal
 * (default: [KeepWaitingForPush], no network call); [CheckStatusNow] is
 * the bounded fallback — taken only when the *local* iroh-blobs signal
 * itself shows no evidence of an in-flight connection, never on a fixed
 * clock. A slow-but-alive relay/large-file transfer must never be
 * mistaken for a stalled one just because a push hasn't arrived yet
 * (card principle: 本地判活优先于任何远端回声).
 */
internal sealed interface FlowWaitStep {
    data class Resolved(val outcome: FlowStatusPollOutcome) : FlowWaitStep
    object KeepWaitingForPush : FlowWaitStep
    object CheckStatusNow : FlowWaitStep
}

internal fun flowWaitStep(
    pushed: FlowPushOutcome?,
    localStatus: TransferStatus,
    idleStallThresholdMs: Long,
): FlowWaitStep {
    when (pushed) {
        is FlowPushOutcome.Delivered -> return FlowWaitStep.Resolved(FlowStatusPollOutcome.Completed(pushed.receipt))
        is FlowPushOutcome.Failed -> throw FlowPushedFailureException(pushed.code)
        null -> {}
    }
    return when (localStatus) {
        // The phone's own sender-side event already reached a terminal
        // fact — confirm it against the daemon's durable receipt (never
        // trust the local signal alone as a receipt substitute) instead
        // of waiting out the full push-timeout window for no reason.
        is TransferStatus.Completed, is TransferStatus.Aborted -> FlowWaitStep.CheckStatusNow
        // No lease registered locally is itself an inconsistency this
        // attempt should resolve via the daemon rather than sit on.
        TransferStatus.NoLease -> FlowWaitStep.CheckStatusNow
        is TransferStatus.InProgress -> when {
            localStatus.connected -> FlowWaitStep.KeepWaitingForPush
            localStatus.idleForMs != null && localStatus.idleForMs >= idleStallThresholdMs ->
                FlowWaitStep.CheckStatusNow
            else -> FlowWaitStep.KeepWaitingForPush
        }
    }
}

/**
 * NET-06: status-poll backoff for [NativeFlowDeliveryPort]. Card §期望行为⑤
 * calls for a 5-10s poll interval when no push event has arrived — this is
 * the pure decision function (JVM-testable without a coroutine dispatcher).
 * Starts fast (large files often finish inside the first couple of polls
 * for small items) and settles at the card's target ceiling, never
 * growing unbounded — an hours-long relay transfer must still be checked
 * on periodically, not effectively abandoned to a runaway backoff.
 */
internal fun nextStatusPollDelayMs(pollIndex: Int): Long =
    STATUS_POLL_DELAYS_MS.getOrElse(pollIndex) { STATUS_POLL_DELAYS_MS.last() }

private val STATUS_POLL_DELAYS_MS = longArrayOf(1_000, 2_000, 3_000, 5_000, 8_000)

/** A run of this many consecutive status round-trip failures (not "active"
 *  replies — genuine exceptions from [FlowReceiptClient.status] itself,
 *  e.g. the daemon is fully unreachable) gives up on this attempt and lets
 *  it fail up to the ordinary retry path, rather than polling forever
 *  against a daemon that may never come back for this app process's
 *  lifetime. */
internal const val STATUS_POLL_MAX_CONSECUTIVE_FAILURES = 5

/** NET-14: how long the local iroh-blobs signal may show "in progress,
 *  nobody connected yet" before this attempt gives up waiting on it and
 *  checks the daemon directly. This is NOT a transfer-duration timeout —
 *  a connected, actively-moving transfer never hits this regardless of
 *  how long it runs (card principle: 耐心给活着的传输，不给挂起的等待).
 *  30s mirrors NET-09's stall-watchdog window for the same reason: it is
 *  "no local evidence of life", not a size/speed-based guess. */
internal const val LOCAL_IDLE_STALL_THRESHOLD_MS = 30_000L

/** NET-14: how often the wait loop re-reads the local iroh-blobs signal
 *  while no push has arrived and no stall is detected. This never touches
 *  the network — it is a local field read — so it can be far more
 *  frequent than the network-bound status-poll backoff without any cost. */
internal const val LOCAL_STATUS_RECHECK_MS = 500L
