// UI-09 RED: aggregate status (K / M / last-success / all-safe) must derive from
// the durable Flow ledger, not the LEGACY ConfirmedStore.
//
// Reproduction of the 2026-09-06 verifier observation on v0.5.0-test.4: media
// actually transfers (ledger items reach CONFIRMED), yet the home screen never
// changes — K, M and last-success stay frozen because they still read a store
// the new core never writes. This test drives the *production* FlowRunner chain
// end to end on the JVM (RED-GREEN rule: tests go through production paths).
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UI09LedgerAggregateTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-ui09-$case").toFile()

    @Test
    fun full_transfer_of_20_items_takes_pending_K_from_20_to_zero_with_confirmed_M_and_last_success() {
        val dir = tempDir("k-to-zero")
        val ledger = DiscoveryLedgerStore(dir)
        val candidates = (18L..37L).map { candidate(it) }
        val delivery = RecordingDelivery()
        val runner = FlowRunner(ledger, RecordingDiscovery(DiscoveryPage(candidates, DiscoveryCursor(7L, 37L))), delivery)

        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)

        // Freshly discovered, nothing confirmed yet: the ledger view of the
        // triplet must already show K = 20 (the strict head is transferring,
        // 19 are queued).
        val discovered = ledger.load()
        assertEquals(20L, discovered.items.size.toLong())
        val before = flowAggregateOf(discovered)
        assertEquals(20L, before.pending)
        assertEquals(0L, before.confirmed)
        assertEquals(0L, before.lastSuccessAt)

        // Drain the whole queue through real completion receipts.
        repeat(20) { index ->
            val transferring = ledger.load().items.singleOrNull { it.deliveryState == DeliveryState.TRANSFERRING }
                ?: error("queue starved at index $index")
            runner.acceptCompletionReceipt(
                CompletionReceipt(
                    queueSequence = transferring.queueSequence,
                    receiptId = "desktop-${transferring.queueSequence}",
                ),
            )
        }

        val done = ledger.load()
        assertEquals(20L, done.items.count { it.deliveryState == DeliveryState.CONFIRMED }.toLong())
        val after = flowAggregateOf(done)
        assertEquals("every confirmed item clears the pending count", 0L, after.pending)
        assertEquals(20L, after.confirmed)
        assertTrue("confirmation must persist a completion time", after.lastSuccessAt > 0L)
        dir.deleteRecursively()
    }

    @Test
    fun all_safe_projection_requires_confirmed_items_and_an_empty_pending_ledger() {
        val dir = tempDir("all-safe")
        val ledger = DiscoveryLedgerStore(dir)
        val delivery = RecordingDelivery()
        val runner = FlowRunner(ledger, RecordingDiscovery(DiscoveryPage(listOf(candidate(18)), DiscoveryCursor(7L, 18L))), delivery)
        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)

        // Still in flight: not all-safe.
        val mid = ledger.load()
        assertTrue(flowUiStateOf(mid) is FlowUiState.Transferring)
        assertEquals(false, flowIsAllDone(mid, flowAggregateOf(mid)))

        val head = mid.items.single { it.deliveryState == DeliveryState.TRANSFERRING }
        runner.acceptCompletionReceipt(CompletionReceipt(queueSequence = head.queueSequence, receiptId = "desktop-1"))

        val cleared = ledger.load()
        assertEquals(true, flowIsAllDone(cleared, flowAggregateOf(cleared)))
        dir.deleteRecursively()
    }

    @Test
    fun failed_and_cancelled_items_keep_the_ledger_out_of_all_done() {
        val dir = tempDir("not-all-done")
        val ledger = DiscoveryLedgerStore(dir)
        val delivery = RecordingDelivery()
        val runner = FlowRunner(ledger, RecordingDiscovery(DiscoveryPage(listOf(candidate(18), candidate(19)), DiscoveryCursor(7L, 19L))), delivery)
        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)

        // Confirm only the strict head; the second item stays QUEUED -> not done.
        val head = ledger.load().items.single { it.deliveryState == DeliveryState.TRANSFERRING }
        runner.acceptCompletionReceipt(CompletionReceipt(queueSequence = head.queueSequence, receiptId = "desktop-1"))
        val partial = ledger.load()
        assertEquals(1L, flowAggregateOf(partial).confirmed)
        assertEquals(true, flowAggregateOf(partial).pending > 0L)
        assertEquals(false, flowIsAllDone(partial, flowAggregateOf(partial)))

        // Cancel the remaining round: CANCELLED_BY_USER_ROUND is terminal but
        // the round was not completed all-safe; after clearing the pause the
        // cancelled items stay out of the pending count.
        runner.pause()
        runner.cancelCurrentRound("round-1")
        val cancelled = ledger.load()
        assertEquals(0L, flowAggregateOf(cancelled).pending)
        assertEquals(false, flowIsAllDone(cancelled, flowAggregateOf(cancelled)))
        dir.deleteRecursively()
    }

    @Test
    fun missing_source_is_terminal_not_pending_and_does_not_block_all_safe_for_remaining_media() {
        fun item(id: Long, state: DeliveryState) = TransferItem(
            stableId = "content://media/external/images/media/$id\u0000generation-7",
            sourceRef = "content://media/external/images/media/$id",
            sourceVersion = "generation-7",
            bucketId = 42L,
            scopeRevision = ScopeRevision(),
            queueSequence = id,
            deliveryState = state,
        )
        val skipped = item(18, DeliveryState.SKIPPED_SOURCE_MISSING).copy(
            sourcePresence = SourcePresence.MISSING,
            disposition = RecoveryDisposition.UNRECOVERABLE,
        )
        val confirmed = item(19, DeliveryState.CONFIRMED).copy(
            completionReceiptId = "desktop-19",
            completedAt = 42L,
        )
        val snapshot = DiscoveryLedgerSnapshot(items = listOf(skipped, confirmed))

        assertEquals(0L, flowAggregateOf(snapshot).pending)
        assertEquals(1L, flowAggregateOf(snapshot).confirmed)
        assertEquals(1, flowMissingSourceNotice(snapshot)?.count)
        assertTrue(flowIsAllDone(snapshot, flowAggregateOf(snapshot)))
        assertTrue(backupUiStateOf(snapshot) is com.hawkeyexb.ppass.ui.BackupUiState.AllSafe)
    }

    @Test
    fun old_ledger_json_without_completedAt_loads_and_backfills_confirmed_items() {
        // Schema compatibility: a ledger written before UI-09 has no
        // completedAt field; kotlinx defaults must let it load without
        // crashing. MOB-53: a CONFIRMED item with no recorded completion
        // time is not "not yet completed" (it is terminal, no receipt will
        // ever replay for it again) — load() must backfill it to a positive
        // stamp, not leave it at the schema default 0 (that produced a
        // permanent "M confirmed" + "从未成功备份过" contradiction on a real
        // Samsung device, see MOB-53).
        val dir = tempDir("schema-compat")
        val storeDir = File(dir, "flow-state/node").apply { mkdirs() }
        val ledger = DiscoveryLedgerStore(storeDir)
        val delivery = RecordingDelivery()
        val runner = FlowRunner(ledger, RecordingDiscovery(DiscoveryPage(listOf(candidate(18)), DiscoveryCursor(7L, 18L))), delivery)
        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)
        val head = ledger.load().items.single()
        runner.acceptCompletionReceipt(CompletionReceipt(queueSequence = head.queueSequence, receiptId = "desktop-1"))
        val withTime = ledger.load().items.single { it.queueSequence == head.queueSequence }
        assertTrue(withTime.completedAt > 0L)

        // Strip completedAt from the persisted JSON (simulating a pre-UI-09
        // file) and reload: it must parse without crashing.
        val file = File(storeDir, "discovery-ledger.json")
        // completedAt is the declared-last field, so it appears either as
        // ,"completedAt":N (mid-object) or "completedAt":N} (object end).
        val stripped = file.readText()
            .replace(Regex("""\s*"completedAt":\s*\d+,"""), "")
            .replace(Regex(""","completedAt":\s*\d+"""), "")
        assertTrue("the test must actually strip the field", !stripped.contains("completedAt"))
        file.writeText(stripped)
        val reloaded = ledger.load()
        assertTrue(
            "MOB-53: a CONFIRMED item missing completedAt must be backfilled, not left at 0",
            reloaded.items.single { it.queueSequence == head.queueSequence }.completedAt > 0L,
        )
        dir.deleteRecursively()
    }

    // MOB-53 RED: a ledger written before UI-09 has CONFIRMED items whose
    // completedAt field is absent from the JSON (pre-migration schema). After
    // UI-09 added the field with a 0 default, these items load as
    // completedAt == 0 forever — no receipt replay will ever touch them again
    // (they are already terminal) — so the home screen shows real M/N counts
    // side by side with "从未成功备份过" (LastSuccess.Never), a permanent
    // self-contradiction observed on a real Samsung device 2026-09-07.
    @Test
    fun pre_ui09_confirmed_items_without_completedAt_are_backfilled_on_load() {
        val dir = tempDir("mob53-backfill")
        val storeDir = File(dir, "flow-state/node").apply { mkdirs() }
        val ledger = DiscoveryLedgerStore(storeDir)
        val delivery = RecordingDelivery()
        val runner = FlowRunner(
            ledger,
            RecordingDiscovery(DiscoveryPage(listOf(candidate(18), candidate(19)), DiscoveryCursor(7L, 19L))),
            delivery,
        )
        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)
        var head = ledger.load().items.single { it.deliveryState == DeliveryState.TRANSFERRING }
        runner.acceptCompletionReceipt(CompletionReceipt(queueSequence = head.queueSequence, receiptId = "desktop-1"))
        head = ledger.load().items.single { it.deliveryState == DeliveryState.TRANSFERRING }
        runner.acceptCompletionReceipt(CompletionReceipt(queueSequence = head.queueSequence, receiptId = "desktop-2"))
        val confirmed = ledger.load()
        assertEquals(2L, confirmed.items.count { it.deliveryState == DeliveryState.CONFIRMED }.toLong())

        // Simulate the pre-UI-09 on-disk shape: strip completedAt from both
        // CONFIRMED items (they were terminal before the field existed).
        val file = File(storeDir, "discovery-ledger.json")
        val stripped = file.readText()
            .replace(Regex(""""completedAt":\s*\d+,\s*"""), "")
            .replace(Regex(""",\s*"completedAt":\s*\d+"""), "")
        assertTrue("the test must actually strip the field", !stripped.contains("completedAt"))
        file.writeText(stripped)

        // RED (pre-fix): a naive load() reports completedAt == 0 for both,
        // so flowAggregateOf(...).lastSuccessAt == 0 and lastSuccessOf(0, now)
        // renders "从未成功备份过" — even though M == 2 confirmed items exist.
        val migrated = ledger.load()
        assertTrue(
            "every CONFIRMED item must have a positive completedAt after load-time backfill",
            migrated.items.filter { it.deliveryState == DeliveryState.CONFIRMED }.all { it.completedAt > 0L },
        )
        val aggregate = flowAggregateOf(migrated)
        assertTrue("lastSuccessAt must be positive once M > 0", aggregate.lastSuccessAt > 0L)

        // Idempotency: reloading again (backfill already persisted) must not
        // change the stamps a second time.
        val stamps = migrated.items.associate { it.stableId to it.completedAt }
        val reloaded = ledger.load()
        assertEquals(stamps, reloaded.items.associate { it.stableId to it.completedAt })
        dir.deleteRecursively()
    }

    private fun candidate(id: Long) = DiscoveryCandidate(
        sourceRef = "content://media/external/images/media/$id",
        sourceVersion = "generation-7",
        bucketId = 42L,
    )

    private class RecordingDelivery : DeliveryPort {
        val starts = mutableListOf<Long>()
        val stops = mutableListOf<Long>()
        override fun start(item: TransferItem, resumePartial: Boolean, lease: FetchLease) {
            starts += item.queueSequence
        }

        override fun stop(queueSequence: Long): PartialDisposition {
            stops += queueSequence
            return PartialDisposition.RETAINED
        }
    }

    private class RecordingDiscovery(private val page: DiscoveryPage) : FlowDiscoveryPort {
        override fun discover(cursor: DiscoveryCursor, scope: ScopeRevision): DiscoveryPage = page
    }
}
