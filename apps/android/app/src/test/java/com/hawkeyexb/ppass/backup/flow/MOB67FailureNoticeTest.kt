// MOB-67: "备份失败时通知我" must reach a system notification on a real
// terminal failure. Root cause found by archaeology: UX-02 (2026-08-05) had
// the full notification wiring inside BackupWorker (channel
// `ppass.backup.failed`, id 2027, gated on NotifyOnFailurePrefs.enabled());
// REBUILD-04 cutover (a325208) deleted 1124 lines of that file and the
// notifier died with them — the new Flow failure path never reconnected it.
// These cases lock the CONTRACT boundary: the terminal transition is the one
// and only trigger point, it is filtered by the user's preference, and its
// send is best-effort (never breaks the consumer). The actual
// NotificationManager call lives in FailureNotifier (Android layer, proven by
// real-device acceptance per the card).
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.FailureNotifier
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class MOB67FailureNoticeTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-mob67-$case").toFile()

    private class RecordingFailureNotifier : FailureNotifier {
        /** One entry per post call: total terminal items at that moment. */
        val posts = mutableListOf<Int>()
        var enabledResult: Boolean = true

        override fun enabled(): Boolean = enabledResult

        override fun postFailure(failedItems: Int) {
            posts += failedItems
        }
    }

    private fun candidate(id: Long) =
        DiscoveryCandidate("content://media/external/images/media/$id", "generation-7", 42L)

    private class FakeDiscovery(private val page: DiscoveryPage) : FlowDiscoveryPort {
        override fun discover(cursor: DiscoveryCursor, scope: ScopeRevision): DiscoveryPage = page
    }

    private class FakeDelivery : DeliveryPort {
        val starts = mutableListOf<Long>()
        override fun start(item: TransferItem, resumePartial: Boolean, lease: FetchLease) {
            starts += item.queueSequence
        }
        override fun stop(queueSequence: Long): PartialDisposition = PartialDisposition.RETAINED
    }

    // Card acceptance #1: enabled + a real terminal failure -> notification is
    // posted. Transient failures (attempts 1 and 2 of 3) must NOT post —
    // "failure" means the durable terminal fact, not every retry.
    @Test
    fun terminal_failure_posts_one_notification_transient_failures_post_none() {
        val dir = tempDir("terminal-post")
        val ledger = DiscoveryLedgerStore(dir)
        val notifier = RecordingFailureNotifier()
        val runner = FlowRunner(
            ledger,
            FakeDiscovery(DiscoveryPage(listOf(candidate(18)), DiscoveryCursor(7L, 18L))),
            FakeDelivery(),
            failureNotifier = notifier,
        )

        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)

        runner.recordPermanentFailure() // attempt 1 — re-queued, no notice
        runner.recordPermanentFailure() // attempt 2 — re-queued, no notice
        assertEquals("non-terminal retries must not notify", emptyList<Int>(), notifier.posts)

        runner.recordPermanentFailure() // attempt 3 — terminal FAILED_NEEDS_USER
        assertEquals(
            "the terminal transition posts exactly one failure notification",
            listOf(1),
            notifier.posts,
        )

        val failed = ledger.load().items.single { it.queueSequence == 1L }
        assertEquals(DeliveryState.FAILED_NEEDS_USER, failed.deliveryState)
        dir.deleteRecursively()
    }

    // Card acceptance #1 (second half) + #3 counterproof basis: the switch
    // off must suppress the post entirely — same ledger outcome, no notice.
    @Test
    fun disabled_preference_suppresses_the_notification_but_not_the_ledger_state() {
        val dir = tempDir("disabled")
        val ledger = DiscoveryLedgerStore(dir)
        val notifier = RecordingFailureNotifier().apply { enabledResult = false }
        val runner = FlowRunner(
            ledger,
            FakeDiscovery(DiscoveryPage(listOf(candidate(18)), DiscoveryCursor(7L, 18L))),
            FakeDelivery(),
            failureNotifier = notifier,
        )

        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)
        repeat(3) { runner.recordPermanentFailure() }

        assertEquals("a disabled switch must never post", emptyList<Int>(), notifier.posts)
        assertEquals(
            "the ledger transition is independent of the notification",
            DeliveryState.FAILED_NEEDS_USER,
            ledger.load().items.single { it.queueSequence == 1L }.deliveryState,
        )
        dir.deleteRecursively()
    }

    // MOB-54 must not regress: the wake-after-failure behavior stays intact
    // once the notifier is inserted into the same path.
    @Test
    fun failure_notifier_does_not_break_transient_auto_retry() {
        val dir = tempDir("mob54-regression")
        val delivery = FakeDelivery()
        val runner = FlowRunner(
            DiscoveryLedgerStore(dir),
            FakeDiscovery(DiscoveryPage(listOf(candidate(18)), DiscoveryCursor(7L, 18L))),
            delivery,
            failureNotifier = RecordingFailureNotifier(),
        )
        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)
        runner.recordPermanentFailure()
        assertEquals("MOB-54 auto-retry still fires", listOf(1L, 1L), delivery.starts)
        dir.deleteRecursively()
    }
}
