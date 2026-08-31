// ARCH-02: durable phone-side facts for discovery admission.
// A page of candidates and its DiscoveryCursor always live in one snapshot:
// write a replacement file, then atomically rename it into place.
package com.hawkeyexb.ppass.backup

import java.io.File
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
data class CancellationRound(val id: String)

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
    CANCELLED_BY_SCOPE,
    CANCELLED_BY_USER_ROUND,
}

@Serializable
data class DiscoveryCandidate(
    val sourceRef: String,
    val sourceVersion: String,
    val bucketId: Long,
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
    val scopeRevision: ScopeRevision,
    val queueSequence: Long,
    val deliveryState: DeliveryState,
    val attemptCount: Int = 0,
    val partialRetained: Boolean = false,
    val completionReceiptId: String? = null,
)

@Serializable
data class ScopeBackfillRequest(val scopeRevision: ScopeRevision)

@Serializable
data class DiscoveryLedgerSnapshot(
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
                json.decodeFromString(DiscoveryLedgerSnapshot.serializer(), file.readText())
            } catch (_: Exception) {
                DiscoveryLedgerSnapshot()
            }
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

    fun commitDiscoveryPage(
        candidates: List<DiscoveryCandidate>,
        nextCursor: DiscoveryCursor,
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

        candidates.forEach { candidate ->
            if (candidate.stableId !in byStableId) {
                byStableId[candidate.stableId] = TransferItem(
                    stableId = candidate.stableId,
                    sourceRef = candidate.sourceRef,
                    sourceVersion = candidate.sourceVersion,
                    bucketId = candidate.bucketId,
                    scopeRevision = current.scopeRevision,
                    queueSequence = nextSequence++,
                    deliveryState = state,
                )
            }
        }

        val next = current.copy(
            cursor = nextCursor,
            items = byStableId.values.sortedBy { it.queueSequence },
            nextQueueSequence = nextSequence,
        )
        beforeCommit()
        persist(next)
    }

    private fun persist(snapshot: DiscoveryLedgerSnapshot) {
        dir.mkdirs()
        val temporary = File(dir, "${file.name}.tmp")
        temporary.writeText(json.encodeToString(DiscoveryLedgerSnapshot.serializer(), snapshot))
        check(temporary.renameTo(file)) { "cannot atomically persist discovery ledger" }
    }

    private companion object {
        const val DISCOVERY_PAGE_SIZE = 500
    }
}
