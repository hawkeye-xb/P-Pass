package com.hawkeyexb.ppass.backup.flow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * MOB-88：前提已经不成立的事实被拒绝时，必须留下痕迹。
 *
 * 为什么这组用例值得单独存在：回执、永久失败、哈希回填都来自原生传输
 * 线程，到达时世界可能已经变了（桌面端换了配对代号、这一条被另一个租约
 * 取代、条目已经终态、租约已被收走）。改造前这些情况一律静默
 * `return`——系统不出声。#107 的真机验收因此根本问不出结果：撤掉锁的
 * 对照组和修复版的日志一模一样。能被发现的 bug 才能被修。
 */
class MOB88RejectionAuditTest {
    @get:Rule
    val folder = TemporaryFolder()

    private fun store() = DiscoveryLedgerStore(JsonFileFlowLedgerRepository(folder.newFolder()))

    private fun item(
        queueSequence: Long,
        epoch: PairingEpoch,
        state: DeliveryState = DeliveryState.TRANSFERRING,
        contentHash: String? = null,
    ) = TransferItem(
        stableId = "stable-$queueSequence",
        sourceRef = "content://media/external/file/$queueSequence",
        sourceVersion = "1:1:1",
        bucketId = 7L,
        fileName = "photo-$queueSequence.jpg",
        mediaType = "image/jpeg",
        scopeRevision = ScopeRevision(1L),
        pairingEpoch = epoch,
        queueSequence = queueSequence,
        deliveryState = state,
        contentHash = contentHash,
    )

    private fun rejections(ledger: DiscoveryLedgerStore) =
        ledger.load().auditOutbox.filter { it.kind == AuditKinds.ACTION_REJECTED }

    private fun assertRejectedOnce(
        ledger: DiscoveryLedgerStore,
        action: String,
        reason: String,
    ) {
        val hits = rejections(ledger)
        assertEquals("应当恰好留下一条拒绝记录，实际：${hits.map { it.payload }}", 1, hits.size)
        assertEquals(action, hits.single().payload["action"])
        assertEquals(reason, hits.single().payload["reason"])
    }

    // ① 回执到达，但桌面端已经换了配对代号 —— 旧账全部作废
    @Test
    fun a_receipt_from_a_replaced_pairing_epoch_is_rejected_with_a_trace() {
        val ledger = store()
        val epoch = PairingEpoch("epoch-current")
        ledger.update { it.copy(pairingEpoch = epoch, items = listOf(item(1L, epoch))) }

        CompletionAndScope(ledger).acceptCompletionReceipt(
            CompletionReceipt(queueSequence = 1L, receiptId = "r1", pairingEpoch = PairingEpoch("epoch-stale")),
        )

        assertEquals(
            "陈旧代号的回执不得改动条目状态",
            DeliveryState.TRANSFERRING,
            ledger.load().items.single().deliveryState,
        )
        assertRejectedOnce(ledger, action = "receipt", reason = "pairing_epoch_changed")
    }

    // ② 回执到达，但这一条已经被另一次投递（新租约）接手
    @Test
    fun a_receipt_superseded_by_an_active_lease_is_rejected_with_a_trace() {
        val ledger = store()
        val epoch = PairingEpoch("epoch-current")
        ledger.update {
            it.copy(
                pairingEpoch = epoch,
                fetchLease = FetchLease(queueSequence = 1L, leaseToken = "lease-新"),
                items = listOf(item(1L, epoch)),
            )
        }

        CompletionAndScope(ledger).acceptCompletionReceipt(
            CompletionReceipt(queueSequence = 1L, receiptId = "r1", pairingEpoch = epoch, leaseToken = "lease-旧"),
        )

        assertEquals(DeliveryState.TRANSFERRING, ledger.load().items.single().deliveryState)
        assertRejectedOnce(ledger, action = "receipt", reason = "superseded_by_active_lease")
    }

    // ③ 回执到达，但账本已经被重置过，这个条目不在了
    @Test
    fun a_receipt_for_an_item_no_longer_in_the_ledger_is_rejected_with_a_trace() {
        val ledger = store()
        val epoch = PairingEpoch("epoch-current")
        ledger.update { it.copy(pairingEpoch = epoch, items = emptyList()) }

        CompletionAndScope(ledger).acceptCompletionReceipt(
            CompletionReceipt(queueSequence = 42L, receiptId = "r42", pairingEpoch = epoch),
        )

        assertRejectedOnce(ledger, action = "receipt", reason = "item_no_longer_in_ledger")
    }

    // ④ 回执到达，但这一条在它到达之前已经进了终态（源文件消失）
    @Test
    fun a_receipt_for_an_already_terminal_item_is_rejected_with_a_trace() {
        val ledger = store()
        val epoch = PairingEpoch("epoch-current")
        ledger.update {
            it.copy(
                pairingEpoch = epoch,
                items = listOf(item(1L, epoch, state = DeliveryState.SKIPPED_SOURCE_MISSING)),
            )
        }

        CompletionAndScope(ledger).acceptCompletionReceipt(
            CompletionReceipt(queueSequence = 1L, receiptId = "r1", pairingEpoch = epoch),
        )

        assertEquals(
            DeliveryState.SKIPPED_SOURCE_MISSING,
            ledger.load().items.single().deliveryState,
        )
        assertRejectedOnce(ledger, action = "receipt", reason = "item_already_terminal")
    }

    // ⑤ 永久失败回调到达，但租约已经被收走（暂停/取消先落地了）
    @Test
    fun a_permanent_failure_without_an_active_lease_is_rejected_with_a_trace() {
        val ledger = store()
        val epoch = PairingEpoch("epoch-current")
        ledger.update { it.copy(pairingEpoch = epoch, fetchLease = null, items = listOf(item(1L, epoch))) }
        val consumer = StrictConsumer(
            ledger,
            object : DeliveryPort {
                override fun start(item: TransferItem, resumePartial: Boolean, lease: FetchLease) = Unit
                override fun stop(queueSequence: Long) = PartialDisposition.DISCARDED
            },
        )

        val becameTerminal = consumer.recordPermanentFailure()

        assertTrue("没有活跃租约时不该判定为终态失败", !becameTerminal)
        assertRejectedOnce(ledger, action = "permanent_failure", reason = "no_active_lease")
    }

    // ⑥ 哈希算完回来，租约已经不是自己的了 —— 不许把整条副本写回去
    @Test
    fun a_content_hash_for_a_lease_that_moved_on_is_rejected_with_a_trace() {
        val epoch = PairingEpoch("epoch-current")
        val hashed = item(1L, epoch, contentHash = "blake3-算好的")
        val snapshot = DiscoveryLedgerSnapshot(
            pairingEpoch = epoch,
            // 用户在哈希期间点了暂停：租约被收走，条目退回 QUEUED
            fetchLease = null,
            items = listOf(item(1L, epoch, state = DeliveryState.QUEUED)),
        )

        val next = snapshot.withContentHash(hashed)

        assertEquals(
            "租约已不在，绝不能把 TRANSFERRING 的旧副本写回去覆盖 QUEUED",
            DeliveryState.QUEUED,
            next.items.single().deliveryState,
        )
        val rejected = next.auditOutbox.single { it.kind == AuditKinds.ACTION_REJECTED }
        assertEquals("content_hash", rejected.payload["action"])
        assertEquals("no_longer_the_leased_head", rejected.payload["reason"])
        assertEquals("1", rejected.payload["queueSequence"])
    }

    // 反面：前提成立时不许留拒绝痕迹，否则这组断言就成了橡皮章
    @Test
    fun a_valid_content_hash_writes_through_without_a_rejection() {
        val epoch = PairingEpoch("epoch-current")
        val hashed = item(1L, epoch, contentHash = "blake3-算好的")
        val snapshot = DiscoveryLedgerSnapshot(
            pairingEpoch = epoch,
            fetchLease = FetchLease(queueSequence = 1L, leaseToken = "lease-1"),
            items = listOf(item(1L, epoch)),
        )

        val next = snapshot.withContentHash(hashed)

        assertEquals("blake3-算好的", next.items.single().contentHash)
        assertTrue(
            "前提成立的写入不该产生拒绝记录",
            next.auditOutbox.none { it.kind == AuditKinds.ACTION_REJECTED },
        )
    }
}
