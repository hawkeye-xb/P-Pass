// ARCH-09: coordinate one bounded reconciliation page without transfer side effects.
package com.hawkeyexb.ppass.backup

class ReconciliationCoordinator(private val ledger: DiscoveryLedgerStore) {
    suspend fun reconcilePage(
        remoteMissing: suspend (List<String>) -> Set<String>,
        sourcePresence: suspend (String) -> SourcePresence,
    ) {
        val snapshot = ledger.load()
        val page = snapshot.items
            .asSequence()
            .filter { item ->
                item.pairingEpoch == snapshot.pairingEpoch &&
                    item.deliveryState == DeliveryState.CONFIRMED &&
                    item.contentHash != null
            }
            .sortedBy { it.queueSequence }
            .take(REMOTE_PRESENCE_PAGE_SIZE)
            .toList()
        if (page.isEmpty()) return

        val hashes = page.mapNotNull { it.contentHash }.distinct()
        val missing = remoteMissing(hashes)
        val reconciliation = RemoteReconciliation(ledger)
        page.forEach { item ->
            val hash = checkNotNull(item.contentHash)
            if (hash in missing) {
                reconciliation.recordRemoteMissing(hash, sourcePresence(item.sourceRef))
            } else {
                reconciliation.recordRemotePresent(hash)
            }
        }
    }
}
