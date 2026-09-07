// UI-10: PhotosScreen's "仅本机" attribution filter's data source, which was
// reading the LEGACY ConfirmedStore (no production writer since REBUILD-00
// froze the batch pipeline). New Flow-delivered photos were misjudged as
// "家人的" because ConfirmedStore never saw them.
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.flow.DeliveryState
import com.hawkeyexb.ppass.backup.flow.DiscoveryLedgerStore
import com.hawkeyexb.ppass.backup.flow.PairingEpoch
import com.hawkeyexb.ppass.backup.flow.ScopeRevision
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

class PhotosScreenAttributionTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-ui10-$case").toFile()

    @Test
    fun flow_confirmed_hashes_reads_the_durable_ledger_not_legacy_confirmed_store() {
        val root = tempDir("flow-attribution")
        val flowStateRoot = File(root, "flow-state")
        val daemonDir = File(flowStateRoot, "daemon-node-1").apply { mkdirs() }
        val ledger = DiscoveryLedgerStore(daemonDir)
        val discovery = com.hawkeyexb.ppass.backup.flow.DiscoveryCandidate(
            sourceRef = "content://media/external/images/media/1",
            sourceVersion = "generation-1",
            bucketId = 1L,
            fileName = "a.jpg",
        )
        ledger.commitDiscoveryPage(
            listOf(discovery),
            com.hawkeyexb.ppass.backup.flow.DiscoveryCursor(1L, 1L),
        )
        // Manually confirm the item with a known content hash (mirrors what
        // CompletionAndScope.acceptCompletionReceipt does in production).
        ledger.update { snapshot ->
            snapshot.copy(
                items = snapshot.items.map {
                    it.copy(deliveryState = DeliveryState.CONFIRMED, contentHash = "abc123")
                },
            )
        }

        val mine = flowConfirmedHashesUnder(flowStateRoot)
        assertEquals(
            "UI-10: attribution must read CONFIRMED Flow ledger items, not the frozen legacy store",
            setOf("abc123"),
            mine,
        )

        // The LEGACY path must NOT see this hash — proves the two sources
        // are genuinely independent (the bug was reading the wrong one).
        val legacy = confirmedHashesUnder(File(root, "backup-state"))
        assertEquals(emptySet<String>(), legacy)
    }

    @Test
    fun flow_confirmed_hashes_excludes_non_confirmed_items() {
        val root = tempDir("flow-attribution-pending")
        val flowStateRoot = File(root, "flow-state")
        val daemonDir = File(flowStateRoot, "daemon-node-1").apply { mkdirs() }
        val ledger = DiscoveryLedgerStore(daemonDir)
        ledger.commitDiscoveryPage(
            listOf(
                com.hawkeyexb.ppass.backup.flow.DiscoveryCandidate(
                    sourceRef = "content://media/external/images/media/2",
                    sourceVersion = "generation-1",
                    bucketId = 1L,
                    fileName = "b.jpg",
                ),
            ),
            com.hawkeyexb.ppass.backup.flow.DiscoveryCursor(1L, 2L),
        )
        // Still QUEUED — not yet confirmed, must not count as "mine".
        val mine = flowConfirmedHashesUnder(flowStateRoot)
        assertEquals(emptySet<String>(), mine)
    }
}
