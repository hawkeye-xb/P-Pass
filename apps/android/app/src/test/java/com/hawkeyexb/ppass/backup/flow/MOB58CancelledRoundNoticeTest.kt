// MOB-58: X-05 was decided in ARCH-01 but never wired past
// CancellationRoundController's own JVM tests -- the ledger already carries
// the fact (`cancellationRoundId` tag on cancelled items); this locks the
// pure projection that reads it.
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MOB58CancelledRoundNoticeTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-mob58-notice-$case").toFile()

    private fun candidate(id: Long) = DiscoveryCandidate(
        sourceRef = "content://media/external/images/media/$id",
        sourceVersion = "generation-7",
        bucketId = 42L,
    )

    @Test
    fun no_cancellation_ever_happened_means_no_notice() {
        assertNull(flowCancelledRoundNotice(DiscoveryLedgerSnapshot()))
    }

    @Test
    fun a_cancelled_round_produces_a_notice_with_its_item_count() {
        val dir = tempDir("counts")
        val ledger = DiscoveryLedgerStore(dir)
        ledger.commitDiscoveryPage(listOf(candidate(1), candidate(2)), DiscoveryCursor(1L, 2L))
        ledger.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }

        CancellationRoundController(ledger).startPausedRound("round-1")

        val notice = flowCancelledRoundNotice(ledger.load())
        assertEquals("round-1", notice?.roundId)
        assertEquals(2, notice?.count)
        dir.deleteRecursively()
    }

    @Test
    fun restoring_the_round_clears_the_notice() {
        val dir = tempDir("restore-clears")
        val ledger = DiscoveryLedgerStore(dir)
        ledger.commitDiscoveryPage(listOf(candidate(1)), DiscoveryCursor(1L, 1L))
        ledger.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
        val cancellation = CancellationRoundController(ledger)
        cancellation.startPausedRound("round-1")
        assertEquals(1, flowCancelledRoundNotice(ledger.load())?.count)

        cancellation.restoreRound("round-1")

        assertNull(
            "once every tagged item is back to QUEUED, there is nothing left to decide",
            flowCancelledRoundNotice(ledger.load()),
        )
        dir.deleteRecursively()
    }

    @Test
    fun discarding_the_round_also_clears_the_notice_without_requeueing() {
        val dir = tempDir("discard-clears")
        val ledger = DiscoveryLedgerStore(dir)
        ledger.commitDiscoveryPage(listOf(candidate(1)), DiscoveryCursor(1L, 1L))
        ledger.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
        val cancellation = CancellationRoundController(ledger)
        cancellation.startPausedRound("round-1")

        cancellation.discardRound("round-1")

        assertNull(flowCancelledRoundNotice(ledger.load()))
        assertEquals(
            "discard must not resurrect the item as QUEUED",
            DeliveryState.CANCELLED_BY_USER_ROUND,
            ledger.load().items.single().deliveryState,
        )
        dir.deleteRecursively()
    }

    @Test
    fun only_the_latest_round_is_reported_when_two_rounds_were_never_resolved() {
        val dir = tempDir("latest-wins")
        val ledger = DiscoveryLedgerStore(dir)
        ledger.commitDiscoveryPage(listOf(candidate(1)), DiscoveryCursor(1L, 1L))
        ledger.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
        val cancellation = CancellationRoundController(ledger)
        cancellation.startPausedRound("round-1")
        // A second round starts only after the first is discarded (the
        // controller enforces "no cancellation round already active").
        cancellation.discardRound("round-1")
        ledger.commitDiscoveryPage(listOf(candidate(2)), DiscoveryCursor(1L, 2L))
        cancellation.startPausedRound("round-2")

        val notice = flowCancelledRoundNotice(ledger.load())
        assertEquals("round-2", notice?.roundId)
        assertEquals(1, notice?.count)
        dir.deleteRecursively()
    }
}
