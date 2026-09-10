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
            if (item.deliveryState == DeliveryState.CANCELLED_BY_SCOPE ||
                item.deliveryState == DeliveryState.SKIPPED_SOURCE_MISSING
            ) return@update snapshot
            // AUDIT-04: a replayed receipt for an item already CONFIRMED must
            // not mint a second audit_item_evidence fact — the guard is the
            // pre-transition state, checked once, before the copy below.
            val firstConfirmation = item.deliveryState != DeliveryState.CONFIRMED
            val items = snapshot.items.map { item ->
                if (item.queueSequence == receipt.queueSequence) {
                    item.copy(
                        deliveryState = DeliveryState.CONFIRMED,
                        completionReceiptId = receipt.receiptId,
                        contentHash = receipt.contentHash,
                        partialRetained = false,
                        // UI-09: the single clock for "last success" is the
                        // moment the durable ledger first accepts a receipt
                        // for this item; a REBUILD-06 receipt replay keeps the
                        // original stamp instead of drifting it forward.
                        completedAt = item.completedAt.takeIf { stamped -> stamped > 0L }
                            ?: System.currentTimeMillis(),
                        // A user-cancel round raced Desktop's already-in-flight
                        // completion; the durable receipt wins, so this item no
                        // longer belongs to that round.
                        cancellationRoundId = null,
                    )
                } else item
            }
            val next = items.firstOrNull { it.deliveryState == DeliveryState.QUEUED }?.queueSequence
            val pausedRoundDrained = snapshot.consumerGate == ConsumerGate.PAUSED_BY_USER &&
                items.none {
                    it.deliveryState == DeliveryState.QUEUED ||
                        it.deliveryState == DeliveryState.TRANSFERRING
                }
            val updated = snapshot.copy(
                uploadCursor = UploadCursor(next),
                // MOB-63: Pause may have already returned this final item to
                // QUEUED when an in-flight Desktop receipt arrives. Once the
                // receipt persists and no deliverable item remains, preserve
                // the existing Idle ledger semantics instead of a false Resume.
                consumerGate = if (pausedRoundDrained) ConsumerGate.OPEN else snapshot.consumerGate,
                consumerStatus = if (pausedRoundDrained) ConsumerStatus.IDLE else snapshot.consumerStatus,
                fetchLease = null,
                items = items,
            )
            // AUDIT-04: object confirmation evidence commits in the SAME
            // atomic snapshot as the state transition (card acceptance
            // criterion #1) — never a separate "append after commit" step.
            if (firstConfirmation) {
                updated.appendAudit(
                    AuditKinds.ITEM_CONFIRMED,
                    roundId = item.roundId,
                    payload = mapOf(
                        "itemRef" to item.sourceRef,
                        "sourceVersion" to item.sourceVersion,
                        "contentHash" to (receipt.contentHash ?: item.contentHash ?: ""),
                        "receiptRef" to receipt.receiptId,
                        "queueSequence" to receipt.queueSequence.toString(),
                    ),
                )
            } else {
                updated
            }
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
            ).appendAudit(
                AuditKinds.SCOPE_CHANGED,
                roundId = snapshot.currentRoundId,
                payload = mapOf("scopeRevision" to nextRevision.value.toString()),
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
