// ARCH-03: strict single-head consumer over ARCH-02's durable ledger facts.
package com.hawkeyexb.ppass.backup.flow

/** A controllable seam for the later native fetch adapter. */
interface DeliveryPort {
    fun start(item: TransferItem, resumePartial: Boolean, lease: FetchLease)
    fun stop(queueSequence: Long): PartialDisposition
}

enum class PartialDisposition {
    RETAINED,
    DISCARDED,
}

/**
 * Consumes exactly one queued item at a time. Scheduler wakes call [wake]; they
 * never decide Pause/Continue semantics or bypass the durable upload cursor.
 */
class StrictConsumer(
    private val ledger: DiscoveryLedgerStore,
    private val delivery: DeliveryPort,
) {
    fun wake(constraintsSatisfied: Boolean) {
        val current = ledger.load()
        if (current.consumerGate == ConsumerGate.PAUSED_BY_USER) return

        if (!constraintsSatisfied) {
            waitForConstraints(current)
            return
        }

        if (current.fetchLease != null) return
        val head = headOf(current) ?: run {
            ledger.update { it.copy(consumerStatus = ConsumerStatus.IDLE) }
            return
        }
        val lease = FetchLease(queueSequence = head.queueSequence, leaseToken = "lease-${head.queueSequence}")
        ledger.update { snapshot ->
            snapshot.copy(
                uploadCursor = UploadCursor(head.queueSequence),
                consumerStatus = ConsumerStatus.IDLE,
                fetchLease = lease,
                items = snapshot.items.map { item ->
                    if (item.queueSequence == head.queueSequence) {
                        item.copy(deliveryState = DeliveryState.TRANSFERRING)
                    } else {
                        item
                    }
                },
            )
        }
        delivery.start(head, resumePartial = head.partialRetained, lease = lease)
    }

    fun pauseByUser() {
        val current = ledger.load()
        val lease = current.fetchLease ?: run {
            ledger.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
            return
        }
        val partial = delivery.stop(lease.queueSequence)
        ledger.update { snapshot ->
            snapshot.copy(
                consumerGate = ConsumerGate.PAUSED_BY_USER,
                consumerStatus = ConsumerStatus.IDLE,
                fetchLease = null,
                items = snapshot.items.map { item ->
                    if (item.queueSequence == lease.queueSequence) {
                        item.copy(
                            deliveryState = DeliveryState.QUEUED,
                            partialRetained = partial == PartialDisposition.RETAINED,
                        )
                    } else {
                        item
                    }
                },
            )
        }
    }

    fun continueByUser() {
        ledger.update { it.copy(consumerGate = ConsumerGate.OPEN, consumerStatus = ConsumerStatus.IDLE) }
        wake(constraintsSatisfied = true)
    }

    fun recordPermanentFailure() {
        val current = ledger.load()
        val lease = current.fetchLease ?: return
        ledger.update { snapshot ->
            val currentItem = snapshot.items.single { it.queueSequence == lease.queueSequence }
            val attempts = currentItem.attemptCount + 1
            val terminal = attempts >= MAX_PERMANENT_ATTEMPTS
            val items = snapshot.items.map { item ->
                if (item.queueSequence == lease.queueSequence) {
                    item.copy(
                        deliveryState = if (terminal) DeliveryState.FAILED_NEEDS_USER else DeliveryState.QUEUED,
                        attemptCount = attempts,
                    )
                } else {
                    item
                }
            }
            val nextCursor = if (terminal) {
                items.firstOrNull { it.deliveryState == DeliveryState.QUEUED }
                    ?.let { UploadCursor(it.queueSequence) }
                    ?: UploadCursor.INITIAL
            } else {
                snapshot.uploadCursor
            }
            snapshot.copy(
                uploadCursor = nextCursor,
                consumerStatus = ConsumerStatus.IDLE,
                fetchLease = null,
                items = items,
            )
        }
    }

    private fun waitForConstraints(current: DiscoveryLedgerSnapshot) {
        val lease = current.fetchLease
        val partial = lease?.let { delivery.stop(it.queueSequence) }
        ledger.update { snapshot ->
            snapshot.copy(
                consumerStatus = ConsumerStatus.WAITING_FOR_CONSTRAINTS,
                fetchLease = null,
                items = snapshot.items.map { item ->
                    if (lease != null && item.queueSequence == lease.queueSequence) {
                        item.copy(
                            deliveryState = DeliveryState.QUEUED,
                            partialRetained = partial == PartialDisposition.RETAINED,
                        )
                    } else {
                        item
                    }
                },
            )
        }
    }

    private fun headOf(snapshot: DiscoveryLedgerSnapshot): TransferItem? {
        val cursor = snapshot.uploadCursor.currentQueueSequence
        return if (cursor != null) {
            snapshot.items.singleOrNull {
                it.queueSequence == cursor && it.deliveryState == DeliveryState.QUEUED
            }
        } else {
            snapshot.items.firstOrNull { it.deliveryState == DeliveryState.QUEUED }
        }
    }

    private companion object {
        const val MAX_PERMANENT_ATTEMPTS = 3
    }
}
