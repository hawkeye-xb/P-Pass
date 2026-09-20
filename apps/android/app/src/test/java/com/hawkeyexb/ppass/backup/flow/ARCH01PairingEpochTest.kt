// ARCH-06: pairing epoch isolation contract.
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import com.hawkeyexb.ppass.transport.Pairing

class ARCH01PairingEpochTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-arch01-pairing-$case").toFile()

    private fun candidate(id: Int) = DiscoveryCandidate(
        sourceRef = "content://media/external/images/media/$id",
        sourceVersion = "generation-7",
        bucketId = 42L,
    )

    @Test
    fun p01_switching_desktop_preserves_scope_but_atomically_discards_old_epoch_runtime_state() {
        val dir = tempDir("p01")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(listOf(candidate(1)), DiscoveryCursor(7L, 1L))
        store.update { snapshot ->
            snapshot.copy(
                scopeRevision = ScopeRevision(4L),
                consumerGate = ConsumerGate.PAUSED_BY_USER,
                consumerStatus = ConsumerStatus.WAITING_FOR_CONSTRAINTS,
                cancellationRound = CancellationRound("old-round"),
                uploadCursor = UploadCursor(1L),
                fetchLease = FetchLease(1L, "old-lease"),
                backfillRequests = listOf(ScopeBackfillRequest(ScopeRevision(4L))),
                items = snapshot.items.map {
                    it.copy(deliveryState = DeliveryState.TRANSFERRING, partialRetained = true)
                },
            )
        }

        PairingEpochController(store).replaceDesktop(PairingEpoch("new-desktop-epoch"))

        val switched = store.load()
        assertEquals(PairingEpoch("new-desktop-epoch"), switched.pairingEpoch)
        assertEquals("P-01 keeps the selected-scope revision", ScopeRevision(4L), switched.scopeRevision)
        assertEquals(DiscoveryCursor.INITIAL, switched.cursor)
        assertEquals(UploadCursor.INITIAL, switched.uploadCursor)
        assertEquals(ConsumerGate.OPEN, switched.consumerGate)
        assertEquals(ConsumerStatus.IDLE, switched.consumerStatus)
        assertNull(switched.cancellationRound)
        assertNull(switched.fetchLease)
        assertTrue(switched.backfillRequests.isEmpty())
        // MOB-87: 账本项**保留**（旧写法是整份清空，于是每次重连都声明"我
        // 什么都没传过"，整库重新提供一遍；更要命的是没有 CONFIRMED 项就
        // 没有"桌面上还在吗"可问，对账无从谈起）。
        //
        // 但 P-01 真正保护的那条不变量原封不动：**partial ownership 不跨
        // epoch**——桌面侧的 staging 随旧凭证作废，带着它进新 epoch 会让
        // 手机去续一个根本不存在的半成品。TRANSFERRING 同理，退回队列重传。
        val migrated = switched.items.single()
        assertEquals("归属章改成新的", PairingEpoch("new-desktop-epoch"), migrated.pairingEpoch)
        assertFalse("partial ownership must not enter the new epoch", migrated.partialRetained)
        assertEquals(
            "in-flight transfer died with the old grant; requeue it",
            DeliveryState.QUEUED,
            migrated.deliveryState,
        )
        // 序号保留：新入账的项不能跟留下来的老项撞号。
        assertEquals(1L, migrated.queueSequence)
        assertEquals(2L, switched.nextQueueSequence)
        dir.deleteRecursively()
    }

    @Test
    fun mob87_migration_keeps_every_confirmed_content_fact_byte_for_byte() {
        val dir = tempDir("mob87-migrate")
        val store = DiscoveryLedgerStore(dir)
        PairingEpochController(store).replaceDesktop(PairingEpoch("epoch-a"))
        store.commitDiscoveryPage(listOf(candidate(1), candidate(2)), DiscoveryCursor(7L, 2L))
        CompletionAndScope(store).acceptCompletionReceipt(
            CompletionReceipt(1L, "receipt-1", PairingEpoch("epoch-a"), "a".repeat(64)),
        )
        val before = store.load().items.single { it.queueSequence == 1L }

        PairingEpochController(store).replaceDesktop(PairingEpoch("epoch-b"))

        val after = store.load().items.single { it.queueSequence == 1L }
        // 只有归属章变了。任何别的字段动一下，都是在篡改"这张传没传过"这个
        // 事实——而那正是账本存在的全部理由。
        assertEquals(before.copy(pairingEpoch = PairingEpoch("epoch-b")), after)
        assertEquals(DeliveryState.CONFIRMED, after.deliveryState)
        assertEquals("a".repeat(64), after.contentHash)
        assertEquals("receipt-1", after.completionReceiptId)
        assertTrue("completedAt 是 UI-09 的「上次成功」时钟，迁移不许动它", after.completedAt > 0L)
        assertEquals(before.completedAt, after.completedAt)
        dir.deleteRecursively()
    }

    @Test
    fun mob87_migrated_ledger_is_what_lets_reconciliation_have_a_page_at_all() {
        val dir = tempDir("mob87-page")
        val store = DiscoveryLedgerStore(dir)
        PairingEpochController(store).replaceDesktop(PairingEpoch("epoch-a"))
        store.commitDiscoveryPage(listOf(candidate(1)), DiscoveryCursor(7L, 1L))
        CompletionAndScope(store).acceptCompletionReceipt(
            CompletionReceipt(1L, "receipt-1", PairingEpoch("epoch-a"), "a".repeat(64)),
        )

        PairingEpochController(store).replaceDesktop(PairingEpoch("epoch-b"))

        // 这就是「静默失败」的红：不迁移的话，账本项还带着 epoch-a，
        // `ReconciliationCoordinator` 的 `item.pairingEpoch == snapshot.pairingEpoch`
        // 会把它们全滤掉 → page 恒空 → 裸 return，外面分不出"对完了"和
        // "一条都没对上"。
        val plan = ReconciliationCoordinator(store).planPage()
        assertEquals(1, plan.page.size)
        assertFalse("有页可对就不是 stalled", plan.stalled)
        dir.deleteRecursively()
    }

    @Test
    fun stale_runtime_epoch_is_replaced_before_an_old_head_can_be_delivered() {
        val dir = tempDir("stale-runtime")
        val store = DiscoveryLedgerStore(dir)
        PairingEpochController(store).replaceDesktop(PairingEpoch("old-epoch"))
        store.commitDiscoveryPage(listOf(candidate(4)), DiscoveryCursor(7L, 4L))
        CompletionAndScope(store).recordTransferStarted(1L)

        PairingEpochController(store).ensureCurrentEpoch(PairingEpoch("new-epoch"))

        val repaired = store.load()
        assertEquals(PairingEpoch("new-epoch"), repaired.pairingEpoch)
        // MOB-87: 项保留，但那个旧队头再也没法被投递——租约没了、
        // TRANSFERRING 退回 QUEUED、归属章换了。本测试要防的"旧队头被当成
        // 还在传的那一个继续交付"因此依然不可能发生。
        val head = repaired.items.single()
        assertEquals(PairingEpoch("new-epoch"), head.pairingEpoch)
        assertEquals(DeliveryState.QUEUED, head.deliveryState)
        assertFalse(head.partialRetained)
        assertNull(repaired.fetchLease)
        assertEquals(UploadCursor.INITIAL, repaired.uploadCursor)
        dir.deleteRecursively()
    }

    @Test
    fun delivery_epoch_guard_refuses_a_pairing_that_changes_while_the_old_delivery_is_running() {
        var pairing: Pairing? = pairing("epoch-a")
        val guard = FlowDeliveryEpochGuard { pairing }

        assertTrue(guard.isCurrent(PairingEpoch("epoch-a")))
        pairing = pairing("epoch-b")

        assertFalse(guard.isCurrent(PairingEpoch("epoch-a")))
    }

    @Test
    fun delivery_epoch_guard_adopts_only_a_nonempty_new_epoch_from_the_authenticated_desktop() {
        val guard = FlowDeliveryEpochGuard { pairing("epoch-a") }

        assertNull(guard.refreshedEpoch(null))
        assertNull(guard.refreshedEpoch(""))
        assertNull(guard.refreshedEpoch("epoch-a"))
        assertEquals(PairingEpoch("epoch-b"), guard.refreshedEpoch("epoch-b"))
    }

    @Test
    fun p02_late_receipt_from_old_desktop_cannot_confirm_the_new_epoch_item() {
        val dir = tempDir("p02")
        val store = DiscoveryLedgerStore(dir)
        PairingEpochController(store).replaceDesktop(PairingEpoch("new-desktop-epoch"))
        store.commitDiscoveryPage(listOf(candidate(2)), DiscoveryCursor(7L, 2L))
        CompletionAndScope(store).recordTransferStarted(1L)

        CompletionAndScope(store).acceptCompletionReceipt(
            CompletionReceipt(
                queueSequence = 1L,
                receiptId = "old-desktop-receipt",
                pairingEpoch = PairingEpoch("old-desktop-epoch"),
            ),
        )

        val item = store.load().items.single()
        assertEquals(DeliveryState.TRANSFERRING, item.deliveryState)
        assertNull(item.completionReceiptId)
        assertEquals(FetchLease(1L, "lease-1"), store.load().fetchLease)
        dir.deleteRecursively()
    }

    @Test
    fun p02_receipt_from_current_desktop_still_confirms_the_current_epoch_item() {
        val dir = tempDir("p02-current")
        val store = DiscoveryLedgerStore(dir)
        val epoch = PairingEpoch("current-desktop-epoch")
        PairingEpochController(store).replaceDesktop(epoch)
        store.commitDiscoveryPage(listOf(candidate(3)), DiscoveryCursor(7L, 3L))
        CompletionAndScope(store).recordTransferStarted(1L)

        CompletionAndScope(store).acceptCompletionReceipt(
            CompletionReceipt(queueSequence = 1L, receiptId = "current-desktop-receipt", pairingEpoch = epoch),
        )

        assertEquals(DeliveryState.CONFIRMED, store.load().items.single().deliveryState)
        assertEquals("current-desktop-receipt", store.load().items.single().completionReceiptId)
        dir.deleteRecursively()
    }

    private fun pairing(epoch: String) = Pairing(
        daemonNodeId = "desktop-$epoch",
        daemonAddrToken = "addr-$epoch",
        storageDeviceName = "Desktop",
        pairingEpoch = epoch,
    )
}
