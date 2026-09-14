// NET-12: pure decision test for whether the Android layer should start or
// stop the transfer foreground service. Deliberately JVM-only (see
// [foregroundActionFor] doc) — no Android framework needed to prove the
// ledger-derived decision itself is correct.
package com.hawkeyexb.ppass.backup.flow

import org.junit.Assert.assertEquals
import org.junit.Test

class ForegroundServiceDecisionTest {

    private fun queuedItem(queueSequence: Long) = TransferItem(
        stableId = "stable-$queueSequence",
        sourceRef = "content://media/$queueSequence",
        sourceVersion = "v1",
        bucketId = 1L,
        scopeRevision = ScopeRevision(),
        queueSequence = queueSequence,
        deliveryState = DeliveryState.QUEUED,
    )

    @Test
    fun round_active_with_a_lease_requires_the_foreground_service_running() {
        val snapshot = DiscoveryLedgerSnapshot(
            consumerGate = ConsumerGate.OPEN,
            fetchLease = FetchLease(queueSequence = 1L, leaseToken = "lease-1"),
            items = listOf(queuedItem(1L).copy(deliveryState = DeliveryState.TRANSFERRING)),
        )
        assertEquals(ForegroundAction.START, foregroundActionFor(snapshot))
    }

    @Test
    fun round_active_with_queued_work_and_no_lease_yet_still_requires_the_service() {
        // The between-files gap MOB-51 already had to handle: lease is
        // momentarily null but there is still deliverable work durably
        // queued. The foreground service must not flicker off here.
        val snapshot = DiscoveryLedgerSnapshot(
            consumerGate = ConsumerGate.OPEN,
            fetchLease = null,
            items = listOf(queuedItem(1L)),
        )
        assertEquals(ForegroundAction.START, foregroundActionFor(snapshot))
    }

    @Test
    fun idle_ledger_with_nothing_queued_does_not_require_the_service() {
        val snapshot = DiscoveryLedgerSnapshot(
            consumerGate = ConsumerGate.OPEN,
            fetchLease = null,
            items = listOf(queuedItem(1L).copy(deliveryState = DeliveryState.CONFIRMED)),
        )
        assertEquals(ForegroundAction.STOP, foregroundActionFor(snapshot))
    }

    @Test
    fun paused_by_user_does_not_require_the_service_even_with_queued_work() {
        // A user pause is a deliberate stop, not "the system might reclaim
        // us" — flowRoundActive already encodes gate == OPEN as part of
        // "active"; a paused gate must resolve to STOP.
        val snapshot = DiscoveryLedgerSnapshot(
            consumerGate = ConsumerGate.PAUSED_BY_USER,
            fetchLease = null,
            items = listOf(queuedItem(1L)),
        )
        assertEquals(ForegroundAction.STOP, foregroundActionFor(snapshot))
    }

    /** 反证 anchor: if [foregroundActionFor] stopped delegating to
     *  [flowRoundActive] and instead always returned STOP, every one of the
     *  three "should be running" cases above would go red. This test only
     *  documents the anchor; the real 反证 is done by hand during review
     *  (temporarily hardcode STOP, confirm the suite goes red, then revert —
     *  see card NET-12 implementation log). */
    @Test
    fun foreground_action_is_not_a_constant() {
        val active = foregroundActionFor(
            DiscoveryLedgerSnapshot(
                consumerGate = ConsumerGate.OPEN,
                fetchLease = FetchLease(queueSequence = 1L, leaseToken = "lease-1"),
                items = listOf(queuedItem(1L).copy(deliveryState = DeliveryState.TRANSFERRING)),
            ),
        )
        val idle = foregroundActionFor(DiscoveryLedgerSnapshot())
        assertEquals(ForegroundAction.START, active)
        assertEquals(ForegroundAction.STOP, idle)
    }
}
