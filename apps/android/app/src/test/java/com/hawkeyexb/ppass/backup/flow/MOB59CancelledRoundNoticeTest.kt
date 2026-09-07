package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MOB59CancelledRoundNoticeTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-mob59-notice-" + case).toFile()

    private fun candidate(id: Long) = DiscoveryCandidate(
        sourceRef = "content://media/external/images/media/" + id,
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

        assertEquals(2, flowCancelledRoundNotice(ledger.load())?.count)
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

    // MOB-59: the real bug this card fixes. Cancelling twice without ever
    // restoring must NOT drop the first round's items from the notice count
    // — the first cut keyed the notice off the *latest* round only, so the
    // earlier batch's photos silently became unreachable (real device,
    // 2026-09-07: "重复点击'取消当前轮'...已跳过 20 张...这里都没有办法处理了").
    @Test
    fun two_unresolved_cancelled_rounds_are_both_counted_in_the_notice() {
        val dir = tempDir("two-rounds")
        val ledger = DiscoveryLedgerStore(dir)
        ledger.commitDiscoveryPage(listOf(candidate(1)), DiscoveryCursor(1L, 1L))
        ledger.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
        val cancellation = CancellationRoundController(ledger)
        cancellation.startPausedRound("round-1")
        cancellation.finishRound()
        ledger.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
        ledger.commitDiscoveryPage(listOf(candidate(2)), DiscoveryCursor(1L, 2L))
        cancellation.startPausedRound("round-2")

        val notice = flowCancelledRoundNotice(ledger.load())

        assertEquals(
            "both round-1's and round-2's cancelled items must be counted, not just the latest",
            2,
            notice?.count,
        )
        dir.deleteRecursively()
    }
}
