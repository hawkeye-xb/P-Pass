// MOB-51 RED: the hero Pause affordance must stay reachable for the whole
// round, not only in the instant one file is mid-TRANSFER.
//
// Reproduction of the 2026-09-06 real-device observation on v0.5.0-test.5:
// progress numbers animate (UI-09 landed), but the Pause button never appears.
// Root cause proven here: between two files the durable ledger is "head
// CONFIRMED + next QUEUED, fetchLease == null, gate OPEN" — a gap the 500ms
// UI poll lands in — and the per-file Transferring projection is Idle there,
// so the hero button hides. The fix adds a sticky round-active fact derived
// only from durable ledger state (no invented scheduling truth).
//
// backupUiStateOf is the single snapshot -> home-screen state mapping shared
// by the production holder and these tests (production-chain rule).
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.ui.BackupUiState
import com.hawkeyexb.ppass.ui.HeroAction
import com.hawkeyexb.ppass.ui.heroActionOf
import com.hawkeyexb.ppass.ui.statusLineOf
import com.hawkeyexb.ppass.ui.StatusLine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB51HeroStickyTest {
    private fun item(seq: Long, state: DeliveryState) = TransferItem(
        stableId = "id-$seq", sourceRef = "content://media/external/images/media/$seq",
        sourceVersion = "1", bucketId = 1L, scopeRevision = ScopeRevision(),
        queueSequence = seq, deliveryState = state,
    )

    // The between-files gap: nothing mid-transfer, but the round owns
    // unfinished work and the user has not paused.
    private fun gapSnapshot(): DiscoveryLedgerSnapshot =
        DiscoveryLedgerSnapshot(
            items = listOf(item(1, DeliveryState.CONFIRMED), item(2, DeliveryState.QUEUED)),
            uploadCursor = UploadCursor(2L),
            consumerGate = ConsumerGate.OPEN,
            fetchLease = null,
        )

    @Test
    fun the_per_file_projection_is_idle_in_the_gap_but_the_round_is_still_active() {
        val gap = gapSnapshot()
        // Exactly the false-negative the poll hits today.
        assertTrue(flowUiStateOf(gap) is FlowUiState.Idle)
        // The new durable fact must say the round is running.
        assertTrue("a round with unfinished QUEUED work and an open gate is active", flowRoundActive(gap))
    }

    @Test
    fun a_running_round_keeps_the_Pause_affordance_visible_in_the_gap() {
        val state = backupUiStateOf(gapSnapshot())
        assertEquals(HeroAction.Pause, heroActionOf(state, pairingLost = false))
        // The status line stays honest: real work, or at minimum the debt.
        val line = statusLineOf(state, pendingK = 1L)
        assertTrue(line is StatusLine.Working || line is StatusLine.Pending)
    }

    @Test
    fun a_finished_drained_ledger_is_not_active_and_shows_no_button() {
        val done = DiscoveryLedgerSnapshot(
            items = listOf(item(1, DeliveryState.CONFIRMED)),
            uploadCursor = UploadCursor.INITIAL,
            consumerGate = ConsumerGate.OPEN,
            fetchLease = null,
        )
        assertFalse("a drained round is not active", flowRoundActive(done))
        val state = backupUiStateOf(done)
        assertTrue(state is BackupUiState.AllSafe)
        assertEquals(null, heroActionOf(state, pairingLost = false))
    }

    @Test
    fun a_user_paused_round_is_not_active_but_still_offers_Resume() {
        val paused = gapSnapshot().copy(consumerGate = ConsumerGate.PAUSED_BY_USER)
        assertFalse("a user pause ends the running round", flowRoundActive(paused))
        val state = backupUiStateOf(paused)
        assertEquals(HeroAction.Resume, heroActionOf(state, pairingLost = false))
    }

    @Test
    fun a_terminal_failed_head_with_no_queued_backing_is_stalled_not_running() {
        val stalled = DiscoveryLedgerSnapshot(
            items = listOf(item(1, DeliveryState.FAILED_NEEDS_USER)),
            uploadCursor = UploadCursor.INITIAL,
            consumerGate = ConsumerGate.OPEN,
            fetchLease = null,
        )
        assertFalse("an exhausted head awaiting retry is not an active round", flowRoundActive(stalled))
        assertTrue(backupUiStateOf(stalled) is BackupUiState.Trouble)
    }

    @Test
    fun mid_file_transfer_remains_active_and_shows_the_file_progress() {
        val transferring = gapSnapshot().copy(
            fetchLease = FetchLease(2L, "lease-2"),
            items = listOf(item(1, DeliveryState.CONFIRMED), item(2, DeliveryState.TRANSFERRING)),
        )
        assertTrue(flowRoundActive(transferring))
        val state = backupUiStateOf(transferring)
        assertTrue("the file-name progress view is preserved", state is BackupUiState.Sending)
        assertEquals(HeroAction.Pause, heroActionOf(state, pairingLost = false))
    }
}
