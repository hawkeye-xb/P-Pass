// ARCH-02: durable phone-side facts for discovery admission.
// A page of candidates and its DiscoveryCursor always live in one snapshot:
// write a replacement file, then atomically rename it into place.
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class DiscoveryCursor(
    val lastGeneration: Long,
    val lastMediaId: Long,
) {
    companion object {
        val INITIAL = DiscoveryCursor(lastGeneration = 0L, lastMediaId = 0L)
    }
}

@Serializable
data class ScopeRevision(val value: Long = 1L)

@Serializable
data class PairingEpoch(val value: String) {
    companion object {
        val INITIAL = PairingEpoch("")
    }
}

@Serializable
data class CancellationRound(val id: String)

// AUDIT-01: audit_event v2 is the sole long-term audit source. A phone-side
// fact that must be audited is written into this durable outbox in the SAME
// atomic snapshot as the fact itself — never as a separate "append after
// commit" step, which is exactly the crash window this replaces (see card).
// The event id is generated once and persists; it is the idempotency key the
// Desktop repository uniques on, so retransmission never duplicates.
object AuditKinds {
    const val ROUND_CONTROLLED = "flow.round.controlled"
    const val SCOPE_CHANGED = "flow.scope.changed"
    const val EPOCH_INVALIDATED = "flow.epoch.invalidated"
    const val ROUND_FINISHED = "flow.round.finished"
    const val ITEM_ATTENTION = "flow.item.attention"
    const val RECONCILIATION_RESOLVED = "flow.reconciliation.resolved"
    /** AUDIT-04: per-item confirmation evidence, generated in the same
     *  atomic snapshot as [CompletionAndScope.acceptCompletionReceipt] —
     *  the durable "object证据" a `flow.round.finished` summary must be
     *  able to point to (card acceptance criterion #1/#2). Never
     *  projected to the activity page (normal success is not long-term
     *  activity noise); only queryable through the operation it belongs to. */
    const val ITEM_CONFIRMED = "flow.item.confirmed"
    /** AUDIT-04: a discovered source vanished before it could be sent
     *  (case matrix §3 "有源图消失"). Previously this terminal fact wrote
     *  no audit trail at all — [StrictConsumer.skipMissingSource] now
     *  emits this in the same atomic snapshot as the state transition. */
    const val ITEM_SOURCE_MISSING = "flow.item.source_missing"
}

@Serializable
data class AuditOutboxEvent(
    val eventId: String,
    val kind: String,
    val roundId: String? = null,
    val occurredAtMs: Long = 0L,
    val payload: Map<String, String> = emptyMap(),
)

/**
 * AUDIT-01: append one durable outbox event to this snapshot. Callers pass
 * the pre-mutation `this` receiver from inside a `ledger.update { ... }`
 * transform, so the audit fact commits in the exact same atomic write as the
 * state change it describes — never a second, separate write.
 */
internal fun DiscoveryLedgerSnapshot.appendAudit(
    kind: String,
    roundId: String? = null,
    payload: Map<String, String> = emptyMap(),
): DiscoveryLedgerSnapshot = copy(
    auditOutbox = auditOutbox + AuditOutboxEvent(
        eventId = UUID.randomUUID().toString(),
        kind = kind,
        roundId = roundId,
        occurredAtMs = System.currentTimeMillis(),
        payload = payload,
    ),
)

@Serializable
data class UploadCursor(val currentQueueSequence: Long? = null) {
    companion object {
        val INITIAL = UploadCursor()
    }
}

@Serializable
enum class ConsumerGate {
    OPEN,
    PAUSED_BY_USER,
}

@Serializable
enum class ConsumerStatus {
    IDLE,
    WAITING_FOR_CONSTRAINTS,
}

@Serializable
data class FetchLease(
    val queueSequence: Long,
    val leaseToken: String,
)

enum class DeliveryState {
    QUEUED,
    TRANSFERRING,
    FAILED_NEEDS_USER,
    CONFIRMED,
    /** The phone source vanished after discovery; no retry can recover it. */
    SKIPPED_SOURCE_MISSING,
    CANCELLED_BY_SCOPE,
    CANCELLED_BY_USER_ROUND,
}

@Serializable
enum class RemotePresence {
    UNKNOWN,
    PRESENT,
    MISSING,
}

@Serializable
enum class SourcePresence {
    UNKNOWN,
    PRESENT,
    MISSING,
}

@Serializable
enum class RecoveryDisposition {
    NONE,
    NEEDS_DECISION,
    UNRECOVERABLE,
}

@Serializable
data class DiscoveryCandidate(
    val sourceRef: String,
    val sourceVersion: String,
    val bucketId: Long,
    val fileName: String = "",
    val mediaType: String = "application/octet-stream",
    // DESK-12: MediaStore DATE_TAKEN as unix ms (0 = unknown/not queried).
    // Carried through to Desktop only as a fallback for files with no EXIF
    // — content that has EXIF keeps using it, unaffected by this field.
    val captureAtMs: Long = 0L,
) {
    val stableId: String
        get() = "$sourceRef\u0000$sourceVersion"
}

@Serializable
data class TransferItem(
    val stableId: String,
    val sourceRef: String,
    val sourceVersion: String,
    val bucketId: Long,
    val fileName: String = "",
    val mediaType: String = "application/octet-stream",
    val scopeRevision: ScopeRevision,
    val queueSequence: Long,
    val deliveryState: DeliveryState,
    val attemptCount: Int = 0,
    val partialRetained: Boolean = false,
    val completionReceiptId: String? = null,
    val contentHash: String? = null,
    val remotePresence: RemotePresence = RemotePresence.UNKNOWN,
    val sourcePresence: SourcePresence = SourcePresence.UNKNOWN,
    val disposition: RecoveryDisposition = RecoveryDisposition.NONE,
    val cancellationRoundId: String? = null,
    val pairingEpoch: PairingEpoch = PairingEpoch.INITIAL,
    /** UI-09: unix ms of the durable completion receipt (0 = never completed). */
    val completedAt: Long = 0L,
    /** DESK-12: MediaStore DATE_TAKEN as unix ms (0 = unknown), admitted from
     *  the discovering [DiscoveryCandidate.captureAtMs]. Sent on the wire so
     *  Desktop can use it as a fallback when the file has no EXIF. */
    val captureAtMs: Long = 0L,
    /** AUDIT-01: the persistent window this item was admitted into. Every
     *  ordinary window gets exactly one `flow.round.finished` summary keyed
     *  by this id once every item in the round reaches a terminal state. */
    val roundId: String? = null,
)

@Serializable
data class ScopeBackfillRequest(
    val scopeRevision: ScopeRevision,
    /** Progress within the historical scan; never replaces the live discovery cursor. */
    val cursor: DiscoveryCursor = DiscoveryCursor.INITIAL,
    /** Immutable upper bound captured when the scope grew. */
    val boundary: DiscoveryCursor = DiscoveryCursor.INITIAL,
)

@Serializable
data class DiscoveryLedgerSnapshot(
    val pairingEpoch: PairingEpoch = PairingEpoch.INITIAL,
    /** Trigger coalescing fact. Only the Flow runner consumes it into discovery. */
    val discoveryRequested: Boolean = false,
    val cursor: DiscoveryCursor = DiscoveryCursor.INITIAL,
    val scopeRevision: ScopeRevision = ScopeRevision(),
    val cancellationRound: CancellationRound? = null,
    val uploadCursor: UploadCursor = UploadCursor.INITIAL,
    val consumerGate: ConsumerGate = ConsumerGate.OPEN,
    val consumerStatus: ConsumerStatus = ConsumerStatus.IDLE,
    val fetchLease: FetchLease? = null,
    val backfillRequests: List<ScopeBackfillRequest> = emptyList(),
    val items: List<TransferItem> = emptyList(),
    val nextQueueSequence: Long = 1L,
    /** AUDIT-01: the currently-open window's persistent id, or null between
     *  windows (right after the previous one's `flow.round.finished` fired,
     *  before the next discovery admits new candidates). */
    val currentRoundId: String? = null,
    /** AUDIT-01: durable outbox of audit facts awaiting delivery to the
     *  daemon. A dispatcher drains it with [DiscoveryLedgerStore.acknowledgeAuditEvents]
     *  after a durable ack; entries are never mutated, only appended or removed. */
    val auditOutbox: List<AuditOutboxEvent> = emptyList(),
)

private val TERMINAL_DELIVERY_STATES = setOf(
    DeliveryState.CONFIRMED,
    DeliveryState.FAILED_NEEDS_USER,
    DeliveryState.SKIPPED_SOURCE_MISSING,
    DeliveryState.CANCELLED_BY_SCOPE,
    DeliveryState.CANCELLED_BY_USER_ROUND,
)

/**
 * Persists the ARCH-01 discovery boundary. The single snapshot is the commit
 * unit: a failed action before [beforeCommit] cannot advance the cursor, and a
 * successful replacement makes both the newly admitted items and cursor visible
 * together after restart.
 */
class DiscoveryLedgerStore(private val dir: File) {
    private val file = File(dir, "discovery-ledger.json")
    private val json = Json {
        encodeDefaults = true
        ignoreUnknownKeys = true
    }

    fun load(): DiscoveryLedgerSnapshot =
        if (!file.isFile) {
            DiscoveryLedgerSnapshot()
        } else {
            try {
                backfillMissingCompletedAt(json.decodeFromString(DiscoveryLedgerSnapshot.serializer(), file.readText()))
            } catch (_: Exception) {
                DiscoveryLedgerSnapshot()
            }
        }

    // MOB-53: items that reached CONFIRMED before UI-09 added `completedAt`
    // are terminal — no receipt will ever replay for them again — so a 0
    // default is not "not yet completed", it is "we never recorded when".
    // Stamp them once with the load-time clock (the only honest value left;
    // there is no earlier recoverable fact) and persist so the backfill runs
    // exactly once per item, matching CompletionAndScope's own "stamp once,
    // never overwrite" rule for completedAt.
    private fun backfillMissingCompletedAt(snapshot: DiscoveryLedgerSnapshot): DiscoveryLedgerSnapshot {
        var changed = false
        val backfilled = snapshot.items.map { item ->
            if (item.deliveryState == DeliveryState.CONFIRMED && item.completedAt <= 0L) {
                changed = true
                item.copy(completedAt = System.currentTimeMillis())
            } else {
                item
            }
        }
        if (!changed) return snapshot
        val migrated = snapshot.copy(items = backfilled)
        persist(migrated)
        return migrated
    }

    fun startCancellationRound(id: String) {
        val current = load()
        require(current.cancellationRound == null) { "a cancellation round is already active" }
        persist(current.copy(cancellationRound = CancellationRound(id)))
    }

    /** ARCH-03 consumer transitions use the same durable snapshot boundary. */
    fun update(transform: (DiscoveryLedgerSnapshot) -> DiscoveryLedgerSnapshot) {
        persist(transform(load()))
    }

    /**
     * AUDIT-01: drop acknowledged outbox events. Calling this twice with the
     * same ids (a repeated ack after the daemon confirmed receipt but the
     * phone crashed before recording it locally) is a no-op the second time
     * — idempotent by construction, since a missing id simply matches nothing.
     */
    fun acknowledgeAuditEvents(eventIds: Set<String>) {
        if (eventIds.isEmpty()) return
        update { snapshot -> snapshot.copy(auditOutbox = snapshot.auditOutbox.filterNot { it.eventId in eventIds }) }
    }

    fun commitDiscoveryPage(
        candidates: List<DiscoveryCandidate>,
        nextCursor: DiscoveryCursor,
        discoveryRequested: Boolean? = null,
        beforeCommit: () -> Unit = {},
    ) {
        require(candidates.size <= DISCOVERY_PAGE_SIZE) { "discovery page exceeds $DISCOVERY_PAGE_SIZE items" }
        val current = load()
        val byStableId = current.items.associateBy { it.stableId }.toMutableMap()
        var nextSequence = current.nextQueueSequence
        val state = if (current.cancellationRound == null) {
            DeliveryState.QUEUED
        } else {
            DeliveryState.CANCELLED_BY_USER_ROUND
        }
        val cancellationRoundId = current.cancellationRound?.id
        // AUDIT-01: every ordinary window carries one persistent roundId for
        // its whole lifetime. Admitting into an already-open window reuses
        // it; admitting into a closed/empty ledger opens a fresh one.
        var roundId = current.currentRoundId
        var admittedAny = false

        candidates.forEach { candidate ->
            if (candidate.stableId !in byStableId) {
                if (roundId == null) roundId = UUID.randomUUID().toString()
                admittedAny = true
                byStableId[candidate.stableId] = TransferItem(
                    stableId = candidate.stableId,
                    sourceRef = candidate.sourceRef,
                    sourceVersion = candidate.sourceVersion,
                    bucketId = candidate.bucketId,
                    fileName = candidate.fileName,
                    mediaType = candidate.mediaType,
                    scopeRevision = current.scopeRevision,
                    pairingEpoch = current.pairingEpoch,
                    queueSequence = nextSequence++,
                    deliveryState = state,
                    cancellationRoundId = cancellationRoundId,
                    captureAtMs = candidate.captureAtMs,
                    roundId = roundId,
                )
            }
        }

        val next = current.copy(
            discoveryRequested = discoveryRequested ?: current.discoveryRequested,
            cursor = nextCursor,
            items = byStableId.values.sortedBy { it.queueSequence },
            nextQueueSequence = nextSequence,
            currentRoundId = if (admittedAny) roundId else current.currentRoundId,
        )
        beforeCommit()
        persist(next)
    }

    /**
     * Appends one historical scope-expansion page without moving the live
     * discovery cursor or disturbing the current strict head.
     */
    fun commitScopeBackfill(request: ScopeBackfillRequest, page: ScopeBackfillPage) {
        val current = load()
        val index = current.backfillRequests.indexOf(request)
        require(index >= 0) { "scope backfill request is no longer active" }
        val byStableId = current.items.associateBy { it.stableId }.toMutableMap()
        var nextSequence = current.nextQueueSequence
        val state = if (current.cancellationRound == null) {
            DeliveryState.QUEUED
        } else {
            DeliveryState.CANCELLED_BY_USER_ROUND
        }
        val cancellationRoundId = current.cancellationRound?.id
        var roundId = current.currentRoundId
        var admittedAny = false
        page.candidates.forEach { candidate ->
            if (candidate.stableId !in byStableId) {
                if (roundId == null) roundId = UUID.randomUUID().toString()
                admittedAny = true
                byStableId[candidate.stableId] = TransferItem(
                    stableId = candidate.stableId,
                    sourceRef = candidate.sourceRef,
                    sourceVersion = candidate.sourceVersion,
                    bucketId = candidate.bucketId,
                    fileName = candidate.fileName,
                    mediaType = candidate.mediaType,
                    scopeRevision = request.scopeRevision,
                    pairingEpoch = current.pairingEpoch,
                    queueSequence = nextSequence++,
                    deliveryState = state,
                    cancellationRoundId = cancellationRoundId,
                    captureAtMs = candidate.captureAtMs,
                    roundId = roundId,
                )
            }
        }
        val requests = current.backfillRequests.toMutableList()
        if (page.complete) {
            requests.removeAt(index)
        } else {
            require(page.nextCursor != request.cursor) { "incomplete scope backfill must advance" }
            requests[index] = request.copy(cursor = page.nextCursor)
        }
        persist(
            current.copy(
                backfillRequests = requests,
                items = byStableId.values.sortedBy { it.queueSequence },
                nextQueueSequence = nextSequence,
                currentRoundId = if (admittedAny) roundId else current.currentRoundId,
            ),
        )
    }

    /**
     * AUDIT-01: once every item in the currently-open window reaches a
     * terminal delivery state, close the window with exactly one
     * `flow.round.finished` summary and free `currentRoundId` so the next
     * discovered window gets a fresh persistent id. Runs on every persisted
     * snapshot so it fires exactly once, from whichever call site drove the
     * last item to a terminal state.
     */
    private fun finalizeRoundIfComplete(snapshot: DiscoveryLedgerSnapshot): DiscoveryLedgerSnapshot {
        val roundId = snapshot.currentRoundId ?: return snapshot
        val roundItems = snapshot.items.filter { it.roundId == roundId }
        if (roundItems.isEmpty() || !roundItems.all { it.deliveryState in TERMINAL_DELIVERY_STATES }) {
            return snapshot
        }
        val summary = mapOf(
            "confirmed" to roundItems.count { it.deliveryState == DeliveryState.CONFIRMED }.toString(),
            "failed" to roundItems.count { it.deliveryState == DeliveryState.FAILED_NEEDS_USER }.toString(),
            "cancelled" to roundItems.count {
                it.deliveryState == DeliveryState.CANCELLED_BY_USER_ROUND || it.deliveryState == DeliveryState.CANCELLED_BY_SCOPE
            }.toString(),
            "skippedSourceMissing" to roundItems.count { it.deliveryState == DeliveryState.SKIPPED_SOURCE_MISSING }.toString(),
        )
        return snapshot.copy(currentRoundId = null)
            .appendAudit(AuditKinds.ROUND_FINISHED, roundId = roundId, payload = summary)
    }

    private fun persist(snapshot: DiscoveryLedgerSnapshot) {
        val finalized = finalizeRoundIfComplete(snapshot)
        dir.mkdirs()
        val temporary = File(dir, "${file.name}.tmp")
        temporary.writeText(json.encodeToString(DiscoveryLedgerSnapshot.serializer(), finalized))
        check(temporary.renameTo(file)) { "cannot atomically persist discovery ledger" }
    }

    private companion object {
        const val DISCOVERY_PAGE_SIZE = 500
    }
}
