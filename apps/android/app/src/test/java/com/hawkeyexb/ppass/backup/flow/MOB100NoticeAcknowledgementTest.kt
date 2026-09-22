// MOB-100 RED（本卡的核心判据）：
//
// 「已跳过 N 张、不会再重传」这条横幅在真机上**绝对不可消除**——不是操作
// 麻烦，是根本没有操作。验收人清掉那 6 条测试残留用的是 adb → run-as →
// force-stop → 拉出 discovery-ledger.json → 手改 JSON → 写回 → 重启 App。
// 用户一步都走不了。
//
// 本文件锁住三条关键判断：
//   1. 确认 ≠ 删账本条目（条目是对账的依据，#139 MOB-87）；
//   2. 是**水位线**，不是布尔开关：确认 6 条 → 第二天又删 2 张 → 横幅以
//      **2** 回来，不是 8、不是不回来；
//   3. 关掉之后这批事实仍可查（MOB-59 的教训：提示消失了，那批再也找不到）。
//
// 以及 D3（`fun acknowledgeReuploadNotice() = Unit`）的同一套语义。
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB100NoticeAcknowledgementTest {

    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-mob100-$case").toFile()

    private fun candidate(id: Long) = DiscoveryCandidate(
        sourceRef = "content://media/external/images/media/$id",
        sourceVersion = "1789878898:1052429",
        bucketId = 42L,
    )

    private class SilentPort : DeliveryPort {
        override fun start(item: TransferItem, resumePartial: Boolean, lease: FetchLease) = Unit
        override fun stop(queueSequence: Long): PartialDisposition = PartialDisposition.RETAINED
    }

    /**
     * 造出 [count] 条「源已删除」的真实账本事实——全程走生产路径
     * （`StrictConsumer.wake` 租下队头 → `skipMissingSource`），
     * 判定语义（`SKIPPED_SOURCE_MISSING` / `UNRECOVERABLE`）一个字没动。
     */
    private fun skipSources(dir: File, ids: LongRange) {
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(
            ids.map { candidate(it) },
            DiscoveryCursor(lastGeneration = 7L, lastMediaId = ids.last),
        )
        val consumer = StrictConsumer(store, SilentPort())
        ids.forEach { _ ->
            consumer.wake(constraintsSatisfied = true)
            consumer.skipMissingSource()
        }
    }

    // ── 关键判据 A：水位线，不是布尔开关 ──────────────────────────────────
    @Test
    fun acknowledging_six_then_losing_two_more_brings_the_notice_back_with_two() {
        val dir = tempDir("watermark")
        skipSources(dir, 1L..6L)
        val store = DiscoveryLedgerStore(dir)
        assertEquals(
            "前提：6 条源已删除的事实都在账本里",
            6,
            flowMissingSourceNotice(store.load())?.count,
        )

        store.update { it.acknowledgeNotice(AcknowledgeableNotice.SOURCE_MISSING, 1_700_000_000_000L) }

        assertNull(
            "点过「知道了」之后横幅必须收起——这是本卡要修的「绝对不可消除」",
            flowMissingSourceNotice(store.load()),
        )

        // 第二天又删了 2 张照片。
        skipSources(dir, 7L..8L)

        assertEquals(
            "横幅必须以 2 回来：不是 8（把确认过的又数了一遍），" +
                "也不是 null（布尔开关一关就永久静音，新事实从此看不见）",
            2,
            flowMissingSourceNotice(DiscoveryLedgerStore(dir).load())?.count,
        )
        dir.deleteRecursively()
    }

    // 反证（编码方式）：水位线**不能**记成 `queueSequence`。那是**发现顺序**，
    // 不是**跳过顺序**——确认到 seq 6 之后，seq 3 那张的源明天才被删，
    // 新事实就永久沉在水位线底下。那正是 MOB-59 的「提示消失了，那批再也
    // 找不到」。逐条打标必须让这条低序号的新事实照样出现。
    @Test
    fun a_later_skip_with_a_lower_queue_sequence_is_not_swallowed() {
        val dir = tempDir("low-seq")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(
            (1L..6L).map { candidate(it) },
            DiscoveryCursor(lastGeneration = 7L, lastMediaId = 6L),
        )
        // 先让 seq 5、6 变成「源已删除」，其余仍在队列里。
        store.update { snapshot ->
            snapshot.copy(
                items = snapshot.items.map { item ->
                    if (item.queueSequence >= 5L) {
                        item.copy(
                            deliveryState = DeliveryState.SKIPPED_SOURCE_MISSING,
                            sourcePresence = SourcePresence.MISSING,
                            disposition = RecoveryDisposition.UNRECOVERABLE,
                        )
                    } else item
                },
            )
        }
        store.update { it.acknowledgeNotice(AcknowledgeableNotice.SOURCE_MISSING, 1_700_000_000_000L) }
        assertNull(flowMissingSourceNotice(store.load()))

        // 现在轮到 seq 3 那张——它的序号比刚确认的那两条都小。
        store.update { snapshot ->
            snapshot.copy(
                items = snapshot.items.map { item ->
                    if (item.queueSequence == 3L) {
                        item.copy(
                            deliveryState = DeliveryState.SKIPPED_SOURCE_MISSING,
                            sourcePresence = SourcePresence.MISSING,
                            disposition = RecoveryDisposition.UNRECOVERABLE,
                        )
                    } else item
                },
            )
        }

        assertEquals(
            "序号小于上次确认位置的新事实不得被吃掉——那是 MOB-59 的形状",
            1,
            flowMissingSourceNotice(store.load())?.count,
        )
        dir.deleteRecursively()
    }

    // ── 关键判据 B：确认 ≠ 删账本条目 ────────────────────────────────────
    @Test
    fun acknowledging_deletes_no_ledger_entry_and_changes_no_delivery_state() {
        val dir = tempDir("no-prune")
        skipSources(dir, 1L..3L)
        val store = DiscoveryLedgerStore(dir)
        val before = store.load().items

        store.update { it.acknowledgeNotice(AcknowledgeableNotice.SOURCE_MISSING, 1_700_000_000_000L) }

        val after = store.load().items
        assertEquals("条目一条不许删——删掉对账就失去依据（#139 MOB-87）", before.size, after.size)
        assertEquals(
            "deliveryState / sourcePresence / disposition 的判定语义不属本卡",
            before.map { Triple(it.deliveryState, it.sourcePresence, it.disposition) },
            after.map { Triple(it.deliveryState, it.sourcePresence, it.disposition) },
        )
        assertTrue(
            "唯一的变化是水位线字段",
            after.all { it.missingSourceAckedAt == 1_700_000_000_000L },
        )
        dir.deleteRecursively()
    }

    // ── 关键判据 C：关掉之后这批事实仍可查 ───────────────────────────────
    @Test
    fun acknowledged_facts_stay_countable_for_the_settings_card_row() {
        val dir = tempDir("archive")
        skipSources(dir, 1L..4L)
        val store = DiscoveryLedgerStore(dir)
        assertEquals(0, flowAcknowledgedMissingSourceCount(store.load()))

        store.update { it.acknowledgeNotice(AcknowledgeableNotice.SOURCE_MISSING, 1_700_000_000_000L) }

        assertEquals(
            "横幅收起 ≠ 事实蒸发：那 4 条得有去处（MOB-59 真机教训）",
            4,
            flowAcknowledgedMissingSourceCount(store.load()),
        )
        dir.deleteRecursively()
    }

    // 跨进程：水位线落在账本条目上，随账本一起原子落盘。
    @Test
    fun the_watermark_survives_a_fresh_ledger_store_reading_from_disk() {
        val dir = tempDir("persist")
        skipSources(dir, 1L..2L)
        DiscoveryLedgerStore(dir)
            .update { it.acknowledgeNotice(AcknowledgeableNotice.SOURCE_MISSING, 1_700_000_000_000L) }

        // 新实例 = 新进程：`cached` 为空，只能从 discovery-ledger.json 读。
        val reopened = DiscoveryLedgerStore(dir).load()

        assertNull("确认不能只活在内存里——重启 App 横幅不许回来", flowMissingSourceNotice(reopened))
        assertEquals(2, flowAcknowledgedMissingSourceCount(reopened))
        dir.deleteRecursively()
    }

    @Test
    fun acknowledging_an_empty_ledger_is_a_no_op_and_needs_a_real_timestamp() {
        assertNull(
            flowMissingSourceNotice(
                DiscoveryLedgerSnapshot().acknowledgeNotice(AcknowledgeableNotice.SOURCE_MISSING, 1L),
            ),
        )
        var threw = false
        try {
            DiscoveryLedgerSnapshot().acknowledgeNotice(AcknowledgeableNotice.SOURCE_MISSING, 0L)
        } catch (_: IllegalArgumentException) {
            threw = true
        }
        assertTrue("0 不是「已确认于某一刻」，它是「还没确认」——不许当成确认写进去", threw)
    }

    // ── D3：`fun acknowledgeReuploadNotice() = Unit` ─────────────────────
    @Test
    fun the_reupload_notice_acknowledgement_actually_lowers_the_count() {
        val dir = tempDir("reupload")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(
            listOf(candidate(1), candidate(2)),
            DiscoveryCursor(lastGeneration = 7L, lastMediaId = 2L),
        )
        store.update { snapshot ->
            snapshot.copy(
                items = snapshot.items.map {
                    it.copy(
                        deliveryState = DeliveryState.CONFIRMED,
                        disposition = RecoveryDisposition.NEEDS_DECISION,
                    )
                },
            )
        }
        assertEquals(2, flowReuploadNoticeCount(store.load()))

        store.update { it.acknowledgeNotice(AcknowledgeableNotice.REUPLOAD, 1_700_000_000_000L) }

        assertEquals(
            "「知道了」点完，下一 tick 从账本重算也不许把它原样端回来",
            0,
            flowReuploadNoticeCount(DiscoveryLedgerStore(dir).load()),
        )
        assertEquals("同样不许删条目", 2, store.load().items.size)
        dir.deleteRecursively()
    }

    @Test
    fun a_new_reupload_fact_after_an_acknowledgement_still_shows_up() {
        val dir = tempDir("reupload-new")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(
            listOf(candidate(1), candidate(2)),
            DiscoveryCursor(lastGeneration = 7L, lastMediaId = 2L),
        )
        store.update { snapshot ->
            snapshot.copy(
                items = snapshot.items.map { item ->
                    item.copy(
                        deliveryState = DeliveryState.CONFIRMED,
                        disposition = if (item.queueSequence == 1L) {
                            RecoveryDisposition.NEEDS_DECISION
                        } else {
                            RecoveryDisposition.NONE
                        },
                    )
                },
            )
        }
        store.update { it.acknowledgeNotice(AcknowledgeableNotice.REUPLOAD, 1_700_000_000_000L) }
        assertEquals(0, flowReuploadNoticeCount(store.load()))

        // 第二张照片这会儿在电脑上也不见了。
        store.update { snapshot ->
            snapshot.copy(
                items = snapshot.items.map { item ->
                    if (item.queueSequence == 2L) {
                        item.copy(disposition = RecoveryDisposition.NEEDS_DECISION)
                    } else item
                },
            )
        }

        assertEquals(1, flowReuploadNoticeCount(store.load()))
        dir.deleteRecursively()
    }

    // 两条水位线必须是**两个字段**。两个集合在任一瞬间互斥，但跨时间不互斥：
    // `ReconciliationCoordinator.requeueRecoverable` 把 NEEDS_DECISION 翻回
    // QUEUED，那一条之后可能走到 `StrictConsumer.skipMissingSource`。共用一个
    // 字段的话，这条用户从没见过的「源没了」事实一出生就带着别人的确认。
    @Test
    fun acknowledging_a_reupload_does_not_pre_acknowledge_a_later_missing_source() {
        val dir = tempDir("cross")
        val store = DiscoveryLedgerStore(dir)
        store.commitDiscoveryPage(
            listOf(candidate(1)),
            DiscoveryCursor(lastGeneration = 7L, lastMediaId = 1L),
        )
        store.update { snapshot ->
            snapshot.copy(
                items = snapshot.items.map {
                    it.copy(
                        deliveryState = DeliveryState.CONFIRMED,
                        disposition = RecoveryDisposition.NEEDS_DECISION,
                    )
                },
            )
        }
        store.update { it.acknowledgeNotice(AcknowledgeableNotice.REUPLOAD, 1_700_000_000_000L) }
        assertEquals(0, flowReuploadNoticeCount(store.load()))

        // 自动补传把它翻回队列（`requeueRecoverable` 的形状），随后这张的
        // 手机原图被删了 —— 走生产路径 `skipMissingSource`。
        store.update { snapshot ->
            snapshot.copy(
                items = snapshot.items.map {
                    it.copy(
                        deliveryState = DeliveryState.QUEUED,
                        disposition = RecoveryDisposition.NONE,
                        completionReceiptId = null,
                        attemptCount = 0,
                    )
                },
            )
        }
        val consumer = StrictConsumer(store, SilentPort())
        consumer.wake(constraintsSatisfied = true)
        consumer.skipMissingSource()

        assertNotNull(
            "这条「源没了」用户从没见过，不许带着上一条提示的确认出生",
            flowMissingSourceNotice(DiscoveryLedgerStore(dir).load()),
        )
        assertEquals(1, flowMissingSourceNotice(DiscoveryLedgerStore(dir).load())?.count)
        dir.deleteRecursively()
    }

    // MOB-98 的存量合并会把两条记录合成一条。水位线按「未确认的一方胜出」
    // 合并：丢一次确认 = 横幅多出现一次（可恢复）；凭空多一次确认 =
    // 用户没见过的事实被永久藏起来（不可恢复）。
    @Test
    fun collapsing_duplicates_keeps_the_unacknowledged_side() {
        val dir = tempDir("merge")
        val store = DiscoveryLedgerStore(dir)
        val legacy = { generation: Long ->
            DiscoveryCandidate(
                sourceRef = "content://media/external/images/media/60346",
                sourceVersion = "$generation:1789878898:1052429",
                bucketId = 42L,
            )
        }
        store.commitDiscoveryPage(
            listOf(legacy(61047L), legacy(61058L)),
            DiscoveryCursor(lastGeneration = 61058L, lastMediaId = 60346L),
        )
        assertEquals("前提：旧式身份下确实是两条", 2, store.load().items.size)
        store.update { snapshot ->
            snapshot.copy(
                items = snapshot.items.mapIndexed { index, item ->
                    item.copy(
                        deliveryState = DeliveryState.SKIPPED_SOURCE_MISSING,
                        sourcePresence = SourcePresence.MISSING,
                        disposition = RecoveryDisposition.UNRECOVERABLE,
                        // 一条确认过、一条没有。
                        missingSourceAckedAt = if (index == 0) 1_700_000_000_000L else 0L,
                    )
                },
            )
        }

        DiscoveryLedgerStore(dir).collapseGenerationDuplicates()

        val survivor = DiscoveryLedgerStore(dir).load().items.single()
        assertEquals(
            "未确认的一方胜出——宁可多问一次，也不许把用户没见过的事实藏起来",
            0L,
            survivor.missingSourceAckedAt,
        )
        dir.deleteRecursively()
    }
}
