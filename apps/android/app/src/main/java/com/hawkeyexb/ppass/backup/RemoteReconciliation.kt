// ARCH-07: durable remote-reconciliation facts without transfer side effects.
package com.hawkeyexb.ppass.backup

class RemoteReconciliation(private val ledger: DiscoveryLedgerStore) {
    fun recordRemotePresent(contentHash: String) {
        ledger.update { snapshot ->
            snapshot.copy(
                items = snapshot.items.map { item ->
                    if (
                        item.pairingEpoch == snapshot.pairingEpoch &&
                        item.deliveryState == DeliveryState.CONFIRMED &&
                        item.contentHash == contentHash
                    ) {
                        item.copy(
                            remotePresence = RemotePresence.PRESENT,
                            sourcePresence = SourcePresence.UNKNOWN,
                            disposition = RecoveryDisposition.NONE,
                        )
                    } else {
                        item
                    }
                },
            )
        }
    }

    fun recordRemoteMissing(contentHash: String, sourcePresence: SourcePresence) {
        val disposition = when (sourcePresence) {
            SourcePresence.PRESENT -> RecoveryDisposition.NEEDS_DECISION
            SourcePresence.MISSING -> RecoveryDisposition.UNRECOVERABLE
            SourcePresence.UNKNOWN -> error("a missing remote requires a source-presence result")
        }
        ledger.update { snapshot ->
            snapshot.copy(
                items = snapshot.items.map { item ->
                    if (
                        item.pairingEpoch == snapshot.pairingEpoch &&
                        item.deliveryState == DeliveryState.CONFIRMED &&
                        item.contentHash == contentHash
                    ) {
                        item.copy(
                            remotePresence = RemotePresence.MISSING,
                            sourcePresence = sourcePresence,
                            disposition = disposition,
                        )
                    } else {
                        item
                    }
                },
            )
        }
    }
}
