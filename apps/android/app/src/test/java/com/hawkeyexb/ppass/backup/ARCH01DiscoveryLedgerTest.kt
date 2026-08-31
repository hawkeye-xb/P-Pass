// ARCH-02: ARCH-01 P0 discovery contract.
// These tests deliberately start before the ledger implementation exists.
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ARCH01DiscoveryLedgerTest {
    private class SimulatedDiscoveryCrash : RuntimeException()

    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-arch01-discovery-$case").toFile()

    private fun candidates(count: Int): List<DiscoveryCandidate> =
        (1..count).map { id ->
            DiscoveryCandidate(
                sourceRef = "content://media/external/images/media/$id",
                sourceVersion = "generation-7",
                bucketId = 42L,
            )
        }

    @Test
    fun d01_committing_500_candidates_makes_pending_items_and_cursor_visible_together() {
        val dir = tempDir("d01")
        val store = DiscoveryLedgerStore(dir)
        val cursor = DiscoveryCursor(lastGeneration = 7L, lastMediaId = 500L)

        store.commitDiscoveryPage(candidates(500), cursor)

        val snapshot = DiscoveryLedgerStore(dir).load()
        assertEquals("D-01 must admit the entire page", 500, snapshot.items.size)
        assertEquals("D-01 must advance the cursor in the same committed snapshot", cursor, snapshot.cursor)
        assertEquals("D-01 must preserve the current scope fact", ScopeRevision(), snapshot.scopeRevision)
        assertEquals("ARCH-02 must persist an unclaimed upload cursor boundary", UploadCursor.INITIAL, snapshot.uploadCursor)
        assertEquals("ARCH-02 must persist an open consumer gate boundary", ConsumerGate.OPEN, snapshot.consumerGate)
        assertEquals("ARCH-02 must persist no fetch lease before a consumer starts", null, snapshot.fetchLease)
        assertTrue("D-01 candidates must be pending", snapshot.items.all { it.deliveryState == DeliveryState.QUEUED })
        dir.deleteRecursively()
    }

    @Test
    fun d02_crash_before_local_commit_keeps_queue_and_cursor_unchanged_and_retry_finds_page() {
        val dir = tempDir("d02")
        val cursor = DiscoveryCursor(lastGeneration = 7L, lastMediaId = 500L)
        val page = candidates(500)
        val store = DiscoveryLedgerStore(dir)

        try {
            store.commitDiscoveryPage(page, cursor) {
                throw SimulatedDiscoveryCrash()
            }
            throw AssertionError("D-02 must inject a crash before the local commit")
        } catch (_: SimulatedDiscoveryCrash) {
            // Expected crash boundary: no durable fact may have moved yet.
        }

        val restarted = DiscoveryLedgerStore(dir)
        val afterCrash = restarted.load()
        assertTrue("D-02 crash must not leave a partial queue", afterCrash.items.isEmpty())
        assertEquals("D-02 crash must not advance the cursor", DiscoveryCursor.INITIAL, afterCrash.cursor)

        restarted.commitDiscoveryPage(page, cursor)
        val afterRetry = DiscoveryLedgerStore(dir).load()
        assertEquals("D-02 restart must rediscover the entire page", 500, afterRetry.items.size)
        assertEquals(cursor, afterRetry.cursor)
        dir.deleteRecursively()
    }

    @Test
    fun d03_replaying_a_committed_page_after_restart_does_not_duplicate_media_versions() {
        val dir = tempDir("d03")
        val cursor = DiscoveryCursor(lastGeneration = 7L, lastMediaId = 500L)
        val page = candidates(500)

        DiscoveryLedgerStore(dir).commitDiscoveryPage(page, cursor)
        DiscoveryLedgerStore(dir).commitDiscoveryPage(page, cursor)

        val snapshot = DiscoveryLedgerStore(dir).load()
        assertEquals("D-03 must retain one TransferItem per stable media version", 500, snapshot.items.size)
        assertEquals(
            "D-03 stable identities must be unique after replay",
            500,
            snapshot.items.map { it.stableId }.toSet().size,
        )
        dir.deleteRecursively()
    }

    @Test
    fun d04_active_cancellation_round_admits_candidates_as_cancelled_and_advances_cursor() {
        val dir = tempDir("d04")
        val store = DiscoveryLedgerStore(dir)
        val cursor = DiscoveryCursor(lastGeneration = 7L, lastMediaId = 500L)
        store.startCancellationRound("round-1")

        store.commitDiscoveryPage(candidates(500), cursor)

        val snapshot = DiscoveryLedgerStore(dir).load()
        assertEquals("D-04 must still persist every discovered candidate", 500, snapshot.items.size)
        assertEquals("D-04 must still advance the discovery cursor", cursor, snapshot.cursor)
        assertTrue(
            "D-04 candidates admitted during an active cancellation round must be terminally cancelled",
            snapshot.items.all { it.deliveryState == DeliveryState.CANCELLED_BY_USER_ROUND },
        )
        assertFalse(
            "D-04 candidates admitted during cancellation must never enter the transferable queue",
            snapshot.items.any { it.deliveryState == DeliveryState.QUEUED },
        )
        dir.deleteRecursively()
    }
}
