// ARCH-06: persistent boundary for replacing the paired Desktop.
package com.hawkeyexb.ppass.backup.flow

class PairingEpochController(private val ledger: DiscoveryLedgerStore) {
    fun ensureCurrentEpoch(nextEpoch: PairingEpoch) {
        if (ledger.load().pairingEpoch != nextEpoch) replaceDesktop(nextEpoch)
    }

    fun replaceDesktop(nextEpoch: PairingEpoch) {
        require(nextEpoch != PairingEpoch.INITIAL) { "a paired Desktop requires an epoch" }
        ledger.update { snapshot ->
            val replaced = snapshot.copy(
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
                currentRoundId = null,
            )
            // AUDIT-01: the very first epoch adoption (INITIAL -> real epoch,
            // right after a fresh pairing) invalidates nothing — there was no
            // previous authority to retire. Only a genuine replacement of an
            // already-current epoch is a durable "old grants are void" fact.
            if (snapshot.pairingEpoch == PairingEpoch.INITIAL) {
                replaced
            } else {
                replaced.appendAudit(
                    AuditKinds.EPOCH_INVALIDATED,
                    payload = mapOf("previousEpoch" to snapshot.pairingEpoch.value),
                )
            }
        }
    }
}
