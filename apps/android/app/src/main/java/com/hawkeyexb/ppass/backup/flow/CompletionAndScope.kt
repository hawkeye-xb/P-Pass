// ARCH-04: completion evidence and ScopeRevision transitions.
package com.hawkeyexb.ppass.backup.flow

import java.util.UUID

data class CompletionReceipt(
    val queueSequence: Long,
    val receiptId: String,
    val pairingEpoch: PairingEpoch = PairingEpoch.INITIAL,
    val contentHash: String? = null,
    val leaseToken: String = "",
)

class CompletionAndScope(private val ledger: DiscoveryLedgerStore) {
    fun recordTransferStarted(queueSequence: Long) {
        ledger.update { snapshot ->
            snapshot.copy(
                uploadCursor = UploadCursor(queueSequence),
                fetchLease = FetchLease(queueSequence, "lease-$queueSequence"),
                items = snapshot.items.map { item ->
                    if (item.queueSequence == queueSequence) item.copy(deliveryState = DeliveryState.TRANSFERRING) else item
                },
            )
        }
    }

    fun acceptCompletionReceipt(receipt: CompletionReceipt) {
        ledger.update { snapshot ->
            if (receipt.pairingEpoch != snapshot.pairingEpoch) return@update snapshot
            // REBUILD-05: a lease only blocks a receipt when it is a *different*,
            // still-active attempt for this exact queue slot (a genuine
            // supersession). A cleared lease (Pause / user-cancel already ran)
            // is not a competing attempt — it must not silently drop Desktop's
            // durable completion evidence, or Desktop ends up with a completed
            // grant the phone can never reconcile against (REBUILD-05 finding).
            val lease = snapshot.fetchLease
            val supersededByActiveLease = receipt.leaseToken.isNotEmpty() &&
                lease != null &&
                lease.queueSequence == receipt.queueSequence &&
                lease.leaseToken != receipt.leaseToken
            if (supersededByActiveLease) return@update snapshot
            val item = snapshot.items.singleOrNull {
                it.queueSequence == receipt.queueSequence && it.pairingEpoch == receipt.pairingEpoch
            } ?: return@update snapshot
            if (receipt.contentHash != null && item.contentHash != null && item.contentHash != receipt.contentHash) return@update snapshot
            if (item.deliveryState == DeliveryState.CANCELLED_BY_SCOPE) return@update snapshot
            val items = snapshot.items.map {
                if (it.queueSequence == receipt.queueSequence) {
                    it.copy(
                        deliveryState = DeliveryState.CONFIRMED,
                        completionReceiptId = receipt.receiptId,
                        contentHash = receipt.contentHash,
                        partialRetained = false,
                        // A user-cancel round raced Desktop's already-in-flight
                        // completion; the durable receipt wins, so this item no
                        // longer belongs to that round.
                        cancellationRoundId = null,
                    )
                } else it
            }
            val next = items.firstOrNull { it.deliveryState == DeliveryState.QUEUED }?.queueSequence
            snapshot.copy(
                uploadCursor = UploadCursor(next),
                fetchLease = null,
                items = items,
            )
        }
    }

    fun reduceScopeTo(nextRevision: ScopeRevision) {
        ledger.update { snapshot ->
            require(nextRevision.value > snapshot.scopeRevision.value) { "scope revision must increase" }
            snapshot.copy(
                scopeRevision = nextRevision,
                uploadCursor = UploadCursor.INITIAL,
                consumerGate = ConsumerGate.PAUSED_BY_USER,
                fetchLease = null,
                items = snapshot.items.map { item ->
                    if (item.deliveryState == DeliveryState.CONFIRMED) item
                    else item.copy(deliveryState = DeliveryState.CANCELLED_BY_SCOPE)
                },
            )
        }
    }

    fun requestScopeBackfill(scopeRevision: ScopeRevision) {
        ledger.update { snapshot ->
            require(scopeRevision.value > snapshot.scopeRevision.value) { "scope revision must increase" }
            snapshot.copy(
                scopeRevision = scopeRevision,
                backfillRequests = snapshot.backfillRequests + ScopeBackfillRequest(
                    scopeRevision = scopeRevision,
                    boundary = snapshot.cursor,
                ),
            )
        }
    }

    fun cancelCurrentRound() {
        ledger.update { snapshot ->
            snapshot.copy(cancellationRound = CancellationRound(UUID.randomUUID().toString()))
        }
    }
}
