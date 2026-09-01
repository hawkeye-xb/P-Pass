package com.hawkeyexb.ppass.backup.flow

import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ARCH01ReconciliationCoordinatorTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-arch01-coordinator-$case").toFile()

    @Test
    fun r01_present_remote_never_probes_source_and_missing_remote_uses_source_fact_without_requeueing() {
        runBlocking {
            val dir = tempDir("r01")
            val store = seededStore(dir)
            val sourceProbes = mutableListOf<String>()
            val queried = mutableListOf<List<String>>()

            ReconciliationCoordinator(store).reconcilePage(
                remoteMissing = { hashes ->
                    queried += hashes
                    setOf("b".repeat(64))
                },
                sourcePresence = { sourceRef ->
                    sourceProbes += sourceRef
                    SourcePresence.PRESENT
                },
            )

            val items = store.load().items
            assertEquals(listOf(listOf("a".repeat(64), "b".repeat(64))), queried)
            assertEquals(listOf("content://media/external/images/media/2"), sourceProbes)
            assertEquals(RemotePresence.PRESENT, items[0].remotePresence)
            assertEquals(RecoveryDisposition.NONE, items[0].disposition)
            assertEquals(RemotePresence.MISSING, items[1].remotePresence)
            assertEquals(RecoveryDisposition.NEEDS_DECISION, items[1].disposition)
            assertTrue(items.all { it.deliveryState == DeliveryState.CONFIRMED && it.attemptCount == 0 })
            dir.deleteRecursively()
        }
    }

    @Test
    fun r02_remote_and_source_missing_records_unrecoverable_without_requeueing() {
        runBlocking {
            val dir = tempDir("r02")
            val store = seededStore(dir)

            ReconciliationCoordinator(store).reconcilePage(
                remoteMissing = { setOf("b".repeat(64)) },
                sourcePresence = { SourcePresence.MISSING },
            )

            val item = store.load().items[1]
            assertEquals(RemotePresence.MISSING, item.remotePresence)
            assertEquals(SourcePresence.MISSING, item.sourcePresence)
            assertEquals(RecoveryDisposition.UNRECOVERABLE, item.disposition)
            assertEquals(DeliveryState.CONFIRMED, item.deliveryState)
            assertEquals(0, item.attemptCount)
            dir.deleteRecursively()
        }
    }

    private fun seededStore(dir: File): DiscoveryLedgerStore = DiscoveryLedgerStore(dir).also { store ->
        store.commitDiscoveryPage(
            listOf(
                DiscoveryCandidate("content://media/external/images/media/1", "g1", 42L),
                DiscoveryCandidate("content://media/external/images/media/2", "g1", 42L),
            ),
            DiscoveryCursor(1L, 2L),
        )
        CompletionAndScope(store).acceptCompletionReceipt(CompletionReceipt(1L, "r1", contentHash = "a".repeat(64)))
        CompletionAndScope(store).acceptCompletionReceipt(CompletionReceipt(2L, "r2", contentHash = "b".repeat(64)))
    }
}
