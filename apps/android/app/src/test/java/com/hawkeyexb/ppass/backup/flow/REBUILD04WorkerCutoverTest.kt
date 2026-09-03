package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.BackupWorker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class REBUILD04WorkerCutoverTest {

    @Test
    fun ledger_projection_distinguishes_user_pause_constraint_wait_and_transfer() {
        val paused = flowUiStateOf(
            DiscoveryLedgerSnapshot(consumerGate = ConsumerGate.PAUSED_BY_USER),
        )
        val waiting = flowUiStateOf(
            DiscoveryLedgerSnapshot(consumerStatus = ConsumerStatus.WAITING_FOR_CONSTRAINTS),
        )
        val transferring = flowUiStateOf(
            DiscoveryLedgerSnapshot(
                uploadCursor = UploadCursor(1L),
                items = listOf(item(1L, DeliveryState.TRANSFERRING)),
            ),
        )

        assertEquals(FlowUiState.PausedByUser, paused)
        assertEquals(FlowUiState.WaitingForConstraints, waiting)
        assertEquals(FlowUiState.Transferring(queueSequence = 1L), transferring)
    }

    @Test
    fun terminal_delivery_failure_is_not_projected_as_idle() {
        val state = flowUiStateOf(
            DiscoveryLedgerSnapshot(items = listOf(item(1L, DeliveryState.FAILED_NEEDS_USER))),
        )

        assertFalse("a failed durable head must surface an actionable status", state is FlowUiState.Idle)
    }

    @Test
    fun continue_reopens_only_the_durable_head_and_cancel_returns_to_user_pause() {
        val dir = java.nio.file.Files.createTempDirectory("ppass-rebuild04-continue-cancel").toFile()
        val ledger = DiscoveryLedgerStore(dir)
        val delivery = RecordingDelivery()
        val runner = FlowRunner(
            ledger = ledger,
            discovery = RecordingDiscovery(
                DiscoveryPage(
                    candidates = listOf(candidate(18L), candidate(19L)),
                    nextCursor = DiscoveryCursor(7L, 19L),
                ),
            ),
            delivery = delivery,
        )

        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)
        runner.acceptCompletionReceipt(CompletionReceipt(queueSequence = 1L, receiptId = "desktop-1"))
        runner.pause()
        runner.continueFlow(constraintsSatisfied = true)

        assertEquals("receipt advances once and Continue resumes only the same durable head", listOf(1L, 2L, 2L), delivery.starts)
        assertEquals(DeliveryState.TRANSFERRING, ledger.load().items.single { it.queueSequence == 2L }.deliveryState)

        runner.cancelCurrentRound("round-1")
        val cancelled = ledger.load()
        assertEquals(FlowUiState.PausedByUser, flowUiStateOf(cancelled))
        assertEquals(null, cancelled.cancellationRound)
        assertEquals(DeliveryState.CONFIRMED, cancelled.items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals(DeliveryState.CANCELLED_BY_USER_ROUND, cancelled.items.single { it.queueSequence == 2L }.deliveryState)
        dir.deleteRecursively()
    }

    @Test
    fun worker_is_compiled_as_the_framework_flow_wake_adapter() {
        assertEquals(
            "androidx.work.CoroutineWorker",
            checkNotNull(BackupWorker::class.java.superclass).name,
        )
        assertEquals(1, BackupWorker::class.java.declaredMethods.count { it.name == "doWork" })
    }

    private fun item(sequence: Long, state: DeliveryState) = TransferItem(
        stableId = "item-$sequence",
        sourceRef = "content://media/$sequence",
        sourceVersion = "v1",
        bucketId = 42L,
        scopeRevision = ScopeRevision(),
        queueSequence = sequence,
        deliveryState = state,
    )

    private fun candidate(id: Long) = DiscoveryCandidate(
        sourceRef = "content://media/external/images/media/$id",
        sourceVersion = "generation-7",
        bucketId = 42L,
    )

    private class RecordingDiscovery(private val page: DiscoveryPage) : FlowDiscoveryPort {
        override fun discover(cursor: DiscoveryCursor, scope: ScopeRevision): DiscoveryPage = page
    }

    private class RecordingDelivery : DeliveryPort {
        val starts = mutableListOf<Long>()

        override fun start(item: TransferItem, resumePartial: Boolean, lease: FetchLease) {
            starts += item.queueSequence
        }

        override fun stop(queueSequence: Long): PartialDisposition = PartialDisposition.RETAINED
    }
}
