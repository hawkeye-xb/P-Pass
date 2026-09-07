package com.hawkeyexb.ppass.backup.flow

import org.junit.Assert.assertEquals
import org.junit.Test

class MOB59RoundProgressTest {
    @Test
    fun first_observation_starts_the_baseline_at_zero_done() {
        val progress = advanceRoundProgress(previousPending = null, previousDone = 0L, currentPending = 5L)
        assertEquals(0L, progress.done)
        assertEquals(5L, progress.total)
    }

    @Test
    fun a_completed_item_advances_done_and_keeps_total_stable() {
        val progress = advanceRoundProgress(previousPending = 5L, previousDone = 0L, currentPending = 4L)
        assertEquals(1L, progress.done)
        assertEquals(5L, progress.total)
    }

    @Test
    fun adding_more_albums_mid_round_grows_total_without_losing_done_credit() {
        val progress = advanceRoundProgress(previousPending = 4L, previousDone = 1L, currentPending = 35L)
        assertEquals(
            "adding pending work must not reset the credit already earned",
            1L,
            progress.done,
        )
        assertEquals(36L, progress.total)
    }

    @Test
    fun a_fully_drained_round_resets_the_baseline_for_the_next_round() {
        val drained = advanceRoundProgress(previousPending = 1L, previousDone = 4L, currentPending = 0L)
        assertEquals(5L, drained.done)
        assertEquals(5L, drained.total)

        val nextRoundStart = advanceRoundProgress(previousPending = drained.total - drained.done, previousDone = drained.done, currentPending = 10L)
        assertEquals(
            "pending is 0 before this call means the round finished; the next round must start fresh at 0",
            0L,
            advanceRoundProgress(previousPending = 0L, previousDone = drained.done, currentPending = 10L).done,
        )
    }
}
