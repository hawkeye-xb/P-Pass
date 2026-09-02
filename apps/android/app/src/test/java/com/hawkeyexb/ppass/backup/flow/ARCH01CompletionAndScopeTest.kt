// ARCH-04: completion evidence and ScopeRevision contract.
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ARCH01CompletionAndScopeTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-arch01-completion-$case").toFile()

    private fun seededStore(dir: File): DiscoveryLedgerStore =
        DiscoveryLedgerStore(dir).also {
            it.commitDiscoveryPage(
                listOf(
                    DiscoveryCandidate("content://media/external/images/media/18", "generation-7", 42L),
                    DiscoveryCandidate("content://media/external/images/media/19", "generation-7", 42L),
                ),
                DiscoveryCursor(7L, 19L),
            )
        }

    private fun complete(store: DiscoveryLedgerStore, sequence: Long = 1L) {
        CompletionAndScope(store).acceptCompletionReceipt(
            CompletionReceipt(queueSequence = sequence, receiptId = "desktop-receipt-$sequence"),
        )
    }

    @Test
    fun e01_only_durable_completion_receipt_confirms_item_and_advances_cursor() {
        val dir = tempDir("e01")
        val store = seededStore(dir)

        CompletionAndScope(store).recordTransferStarted(queueSequence = 1L)
        assertEquals(DeliveryState.TRANSFERRING, store.load().items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals(UploadCursor(1L), store.load().uploadCursor)

        complete(store)
        val snapshot = store.load()
        assertEquals(DeliveryState.CONFIRMED, snapshot.items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals(UploadCursor(2L), snapshot.uploadCursor)
        dir.deleteRecursively()
    }

    @Test
    fun e02_valid_late_receipt_preserves_confirmed_fact_after_scope_reduction() {
        val dir = tempDir("e02")
        val store = seededStore(dir)
        complete(store)

        CompletionAndScope(store).reduceScopeTo(ScopeRevision(2L))
        CompletionAndScope(store).acceptCompletionReceipt(CompletionReceipt(1L, "late-duplicate-receipt"))

        val snapshot = store.load()
        assertEquals(ScopeRevision(2L), snapshot.scopeRevision)
        assertEquals(DeliveryState.CONFIRMED, snapshot.items.single { it.queueSequence == 1L }.deliveryState)
        dir.deleteRecursively()
    }

    @Test
    fun e03_scope_reduction_cancels_unreceipted_partial_and_rejects_late_finalization() {
        val dir = tempDir("e03")
        val store = seededStore(dir)
        CompletionAndScope(store).recordTransferStarted(queueSequence = 1L)

        CompletionAndScope(store).reduceScopeTo(ScopeRevision(2L))
        CompletionAndScope(store).acceptCompletionReceipt(CompletionReceipt(1L, "late-receipt"))

        val item = store.load().items.single { it.queueSequence == 1L }
        assertEquals(DeliveryState.CANCELLED_BY_SCOPE, item.deliveryState)
        assertEquals(null, store.load().fetchLease)
        dir.deleteRecursively()
    }

    @Test
    fun e04_cancel_current_round_does_not_overwrite_confirmed_fact() {
        val dir = tempDir("e04")
        val store = seededStore(dir)
        complete(store)

        CompletionAndScope(store).cancelCurrentRound()

        assertEquals(DeliveryState.CONFIRMED, store.load().items.single { it.queueSequence == 1L }.deliveryState)
        assertTrue(store.load().cancellationRound != null)
        dir.deleteRecursively()
    }

    @Test
    fun rebuild05_late_receipt_after_pause_and_user_cancel_still_confirms_the_same_content() {
        // REBUILD-05 对账缺口：Pause 清空 fetchLease 后，Desktop 已经异步完成的
        // 同一 lease/hash 回执必须仍能确认该项；否则 Desktop 侧留下一条手机
        // 永远看不到的历史 completed grant（对账缺口的真实根因）。
        val dir = tempDir("rebuild05-late-receipt")
        val store = seededStore(dir)
        val completion = CompletionAndScope(store)
        completion.recordTransferStarted(queueSequence = 1L)
        store.update { snapshot ->
            snapshot.copy(items = snapshot.items.map { item ->
                if (item.queueSequence == 1L) item.copy(contentHash = "a".repeat(64)) else item
            })
        }
        val issuedLease = store.load().fetchLease
        checkNotNull(issuedLease)

        // Pause: 严格消费者会清空 fetchLease、把该项打回 QUEUED（模拟 StrictConsumer.pauseByUser）。
        store.update { snapshot ->
            snapshot.copy(
                consumerGate = ConsumerGate.PAUSED_BY_USER,
                fetchLease = null,
                items = snapshot.items.map { item ->
                    if (item.queueSequence == 1L) item.copy(deliveryState = DeliveryState.QUEUED) else item
                },
            )
        }
        // 用户在暂停态发起本轮取消：该项转为 CANCELLED_BY_USER_ROUND。
        CancellationRoundController(store).startPausedRound("round-1")
        assertEquals(
            DeliveryState.CANCELLED_BY_USER_ROUND,
            store.load().items.single { it.queueSequence == 1L }.deliveryState,
        )

        // Desktop 端异步 fetch 早已用原 lease 完成，回执此刻才回流手机。
        completion.acceptCompletionReceipt(
            CompletionReceipt(
                queueSequence = 1L,
                receiptId = "desktop-late-1",
                leaseToken = issuedLease.leaseToken,
                contentHash = "a".repeat(64),
            ),
        )

        val item = store.load().items.single { it.queueSequence == 1L }
        assertEquals(
            "durable Desktop evidence must win even after a user-cancel raced it",
            DeliveryState.CONFIRMED,
            item.deliveryState,
        )
        assertEquals("desktop-late-1", item.completionReceiptId)
        dir.deleteRecursively()
    }

    @Test
    fun rebuild05_receipt_from_a_superseded_active_lease_is_still_rejected() {
        // 反证：如果当前仍持有一个不同的活跃 lease（同一队列位的新尝试），
        // 旧 lease 的回执必须继续被拒绝——REBUILD-05 的修复不能把「过期 lease
        // 也能确认」变成恒真式。
        val dir = tempDir("rebuild05-active-supersede")
        val store = seededStore(dir)
        val completion = CompletionAndScope(store)
        completion.recordTransferStarted(queueSequence = 1L)
        store.update { snapshot ->
            snapshot.copy(items = snapshot.items.map { item ->
                if (item.queueSequence == 1L) item.copy(contentHash = "a".repeat(64)) else item
            })
        }
        val staleLease = store.load().fetchLease
        checkNotNull(staleLease)

        // 一次新的尝试重新签发了 lease（仍是同一队列位，但 token 变了）。
        store.update { snapshot ->
            snapshot.copy(fetchLease = FetchLease(1L, "lease-1-retry"))
        }

        completion.acceptCompletionReceipt(
            CompletionReceipt(
                queueSequence = 1L,
                receiptId = "desktop-stale-1",
                leaseToken = staleLease.leaseToken,
                contentHash = "a".repeat(64),
            ),
        )

        val item = store.load().items.single { it.queueSequence == 1L }
        assertEquals(
            "a superseded lease attempt must not steal the current attempt's confirmation",
            DeliveryState.TRANSFERRING,
            item.deliveryState,
        )
        assertEquals(null, item.completionReceiptId)
        dir.deleteRecursively()
    }

    @Test
    fun scope_increase_records_a_separate_backfill_request_without_reusing_discovery_cursor() {
        val dir = tempDir("scope-increase")
        val store = seededStore(dir)

        CompletionAndScope(store).requestScopeBackfill(ScopeRevision(2L))

        val snapshot = store.load()
        assertEquals(ScopeRevision(2L), snapshot.scopeRevision)
        assertEquals(
            listOf(ScopeBackfillRequest(ScopeRevision(2L), boundary = DiscoveryCursor(7L, 19L))),
            snapshot.backfillRequests,
        )
        assertEquals(DiscoveryCursor(7L, 19L), snapshot.cursor)
        dir.deleteRecursively()
    }
}
