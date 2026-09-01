// ARCH-04: completion evidence and ScopeRevision transitions.
package com.hawkeyexb.ppass.backup

import java.util.UUID

data class CompletionReceipt(
    val queueSequence: Long,
    val receiptId: String,
    val pairingEpoch: PairingEpoch = PairingEpoch.INITIAL,
    val contentHash: String? = null,
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
            val item = snapshot.items.singleOrNull {
                it.queueSequence == receipt.queueSequence && it.pairingEpoch == receipt.pairingEpoch
            } ?: return@update snapshot
            if (item.deliveryState == DeliveryState.CANCELLED_BY_SCOPE) return@update snapshot
            val items = snapshot.items.map {
                if (it.queueSequence == receipt.queueSequence) {
                    it.copy(
                        deliveryState = DeliveryState.CONFIRMED,
                        completionReceiptId = receipt.receiptId,
                        contentHash = receipt.contentHash,
                        partialRetained = false,
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
            snapshot.copy(backfillRequests = snapshot.backfillRequests + ScopeBackfillRequest(scopeRevision))
        }
    }

    fun cancelCurrentRound() {
        ledger.update { snapshot ->
            snapshot.copy(cancellationRound = CancellationRound(UUID.randomUUID().toString()))
        }
    }
}
