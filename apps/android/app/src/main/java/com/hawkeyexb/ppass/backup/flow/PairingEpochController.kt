// ARCH-06: persistent boundary for replacing the paired Desktop.
package com.hawkeyexb.ppass.backup.flow

class PairingEpochController(private val ledger: DiscoveryLedgerStore) {
    fun ensureCurrentEpoch(nextEpoch: PairingEpoch) {
        if (ledger.load().pairingEpoch != nextEpoch) replaceDesktop(nextEpoch)
    }

    fun replaceDesktop(nextEpoch: PairingEpoch) {
        require(nextEpoch != PairingEpoch.INITIAL) { "a paired Desktop requires an epoch" }
        ledger.update { snapshot ->
            snapshot.copy(
                pairingEpoch = nextEpoch,
                cursor = DiscoveryCursor.INITIAL,
                cancellationRound = null,
                uploadCursor = UploadCursor.INITIAL,
                consumerGate = ConsumerGate.OPEN,
                consumerStatus = ConsumerStatus.IDLE,
                fetchLease = null,
                backfillRequests = emptyList(),
                items = emptyList(),
                nextQueueSequence = 1L,
            )
        }
    }
}
