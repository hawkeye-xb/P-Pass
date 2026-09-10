// AUDIT-01: durable ledger <-> audit outbox contract.
//
// Decisions this locks in (cards/AUDIT-01-flow-audit-v2-durable-outbox.md):
//  - A user action / durable fact and its outbox event commit in the SAME
//    atomic snapshot write; the event id persists and survives restart.
//  - Every ordinary window with a persistent roundId writes exactly one
//    `flow.round.finished` summary on the round's terminal transition —
//    not one row per item.
//  - Pause/continue/cancel/retry/restore write `flow.round.controlled`.
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AUDIT01LedgerOutboxTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-audit01-$case").toFile()

    private fun candidate(id: Long) = DiscoveryCandidate(
        sourceRef = "content://media/external/images/media/$id",
        sourceVersion = "generation-7",
        bucketId = 42L,
    )

    private class RecordingDelivery : DeliveryPort {
        val starts = mutableListOf<Long>()
        override fun start(item: TransferItem, resumePartial: Boolean, lease: FetchLease) {
            starts += item.queueSequence
        }
        override fun stop(queueSequence: Long): PartialDisposition = PartialDisposition.RETAINED
    }

    private class RecordingDiscovery(private val page: DiscoveryPage) : FlowDiscoveryPort {
        override fun discover(cursor: DiscoveryCursor, scope: ScopeRevision): DiscoveryPage = page
    }

    // RED #1: a user action (pause) must write its outbox event in the same
    // snapshot as the durable state change, and the event id must survive a
    // fresh load() from disk (simulated restart).
    @Test
    fun user_action_and_its_outbox_event_commit_in_one_atomic_snapshot_and_survive_restart() {
        val dir = tempDir("atomic-pause")
        val ledger = DiscoveryLedgerStore(dir)
        val runner = FlowRunner(ledger, RecordingDiscovery(DiscoveryPage(listOf(candidate(1)), DiscoveryCursor(7L, 1L))), RecordingDelivery())

        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)
        runner.pause()

        val before = ledger.load()
        val event = before.auditOutbox.singleOrNull { it.kind == AuditKinds.ROUND_CONTROLLED }
        assertNotNull("pause must durably enqueue a flow.round.controlled event", event)

        // Simulate restart: a fresh store instance over the same directory
        // must see the identical event id — it is not regenerated.
        val restarted = DiscoveryLedgerStore(dir).load()
        assertEquals(
            "the outbox event id must persist across restart",
            event!!.eventId,
            restarted.auditOutbox.single { it.kind == AuditKinds.ROUND_CONTROLLED }.eventId,
        )
        dir.deleteRecursively()
    }

    // RED #2: dequeueing an acknowledged event and replaying the same
    // acknowledge call must not duplicate or resurrect it (local dispatcher
    // idempotency mirrors the Desktop-side unique event id contract).
    @Test
    fun acknowledging_an_outbox_event_twice_is_idempotent() {
        val dir = tempDir("ack-idempotent")
        val ledger = DiscoveryLedgerStore(dir)
        val runner = FlowRunner(ledger, RecordingDiscovery(DiscoveryPage(listOf(candidate(1)), DiscoveryCursor(7L, 1L))), RecordingDelivery())
        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)
        runner.pause()

        val eventId = ledger.load().auditOutbox.single().eventId
        ledger.acknowledgeAuditEvents(setOf(eventId))
        ledger.acknowledgeAuditEvents(setOf(eventId))

        assertTrue("an acknowledged event must not linger in the outbox", ledger.load().auditOutbox.isEmpty())
        dir.deleteRecursively()
    }

    // RED #3: three normal items in the same persistent roundId produce
    // exactly one flow.round.finished summary, never one row per item.
    @Test
    fun three_confirmed_items_in_one_round_produce_exactly_one_round_finished_summary() {
        val dir = tempDir("round-summary")
        val ledger = DiscoveryLedgerStore(dir)
        val candidates = listOf(candidate(1), candidate(2), candidate(3))
        val runner = FlowRunner(ledger, RecordingDiscovery(DiscoveryPage(candidates, DiscoveryCursor(7L, 3L))), RecordingDelivery())

        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)
        val roundId = ledger.load().currentRoundId
        assertNotNull("admitting a fresh window must assign a persistent roundId", roundId)
        assertTrue(ledger.load().items.all { it.roundId == roundId })

        repeat(3) {
            val head = ledger.load().items.single { it.deliveryState == DeliveryState.TRANSFERRING }
            runner.acceptCompletionReceipt(CompletionReceipt(queueSequence = head.queueSequence, receiptId = "desktop-${head.queueSequence}"))
        }

        val finished = ledger.load()
        val summaries = finished.auditOutbox.filter { it.kind == AuditKinds.ROUND_FINISHED && it.roundId == roundId }
        assertEquals("exactly one aggregate summary per round, never one per item", 1, summaries.size)
        assertEquals("3", summaries.single().payload["confirmed"])
        assertEquals(null, finished.currentRoundId)

        val itemLevelAudit = finished.auditOutbox.filter { it.roundId == roundId && it.kind != AuditKinds.ROUND_FINISHED }
        assertTrue("ordinary per-item confirmations must never reach the audit outbox", itemLevelAudit.isEmpty())
        dir.deleteRecursively()
    }

    // RED: scope reduction (cancelling out-of-scope items) must write
    // flow.scope.changed exactly once, referencing the new scope revision.
    @Test
    fun scope_reduction_writes_a_scope_changed_event() {
        val dir = tempDir("scope-changed")
        val ledger = DiscoveryLedgerStore(dir)
        ledger.commitDiscoveryPage(listOf(candidate(1)), DiscoveryCursor(7L, 1L))

        CompletionAndScope(ledger).reduceScopeTo(ScopeRevision(2L))

        val event = ledger.load().auditOutbox.single { it.kind == AuditKinds.SCOPE_CHANGED }
        assertEquals("2", event.payload["scopeRevision"])
        dir.deleteRecursively()
    }

    // RED: a pairing-epoch replacement (new Desktop) invalidates the old
    // epoch's items and must write flow.epoch.invalidated referencing the
    // epoch being retired.
    @Test
    fun pairing_epoch_replacement_writes_an_epoch_invalidated_event() {
        val dir = tempDir("epoch-invalidated")
        val ledger = DiscoveryLedgerStore(dir)
        PairingEpochController(ledger).replaceDesktop(PairingEpoch("epoch-a"))

        PairingEpochController(ledger).replaceDesktop(PairingEpoch("epoch-b"))

        val event = ledger.load().auditOutbox.single { it.kind == AuditKinds.EPOCH_INVALIDATED }
        assertEquals("epoch-a", event.payload["previousEpoch"])
        dir.deleteRecursively()
    }

    // RED: a terminally-failed head (retry budget exhausted) must write
    // flow.item.attention — this is the "needs user decision" case, not a
    // silent retry.
    @Test
    fun exhausted_retry_budget_writes_an_item_attention_event() {
        val dir = tempDir("item-attention")
        val ledger = DiscoveryLedgerStore(dir)
        val runner = FlowRunner(ledger, RecordingDiscovery(DiscoveryPage(listOf(candidate(1)), DiscoveryCursor(7L, 1L))), RecordingDelivery())
        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)

        repeat(3) { runner.recordPermanentFailure() }

        val event = ledger.load().auditOutbox.single { it.kind == AuditKinds.ITEM_ATTENTION }
        assertEquals("delivery_failed", event.payload["reason"])
        dir.deleteRecursively()
    }
}
