// MOB-98 RED: MediaStore 的 generation_modified 在内容一个字节没变时也会自增
// （把照片移进已选相册就会）。它曾被编进 stableId，于是同一张照片被当成新照片
// 重新入队；叠加严格队头消费，那条重复项卡住时后面所有新照片全部堵死。
//
// 2026-09-21 鸿蒙 4.2 真机实测的那一对：
//   content://…/60346  gen 61047:1789878898:1052429  → CONFIRMED
//   content://…/60346  gen 61058:1789878898:1052429  → TRANSFERRING (attempt=2)
//   contentHash 完全相同，date_modified 与 size 也完全相同。
//
// 本测试全程走生产路径：sourceVersionOf → DiscoveryCandidate.stableId →
// DiscoveryLedgerStore.commitDiscoveryPage / collapseGenerationDuplicates，
// 落盘往返都是真的文件 IO。
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB98GenerationNotIdentityTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-mob98-$case").toFile()

    private val sourceRef = "content://media/external/file/60346"
    private val modified = 1789878898L
    private val size = 1052429L

    /** 生产构造：身份只看内容有没有变。 */
    private fun candidate(dateModified: Long = modified, byteSize: Long = size) =
        DiscoveryCandidate(
            sourceRef = sourceRef,
            sourceVersion = sourceVersionOf(dateModified, byteSize),
            bucketId = 42L,
        )

    /** 修复前的构造，只在反证里用。 */
    private fun legacyCandidate(generation: Long) =
        DiscoveryCandidate(
            sourceRef = sourceRef,
            sourceVersion = "$generation:$modified:$size",
            bucketId = 42L,
        )

    private fun cursor(gen: Long) = DiscoveryCursor(gen, 60346L)

    // ── 验收 1：同文件、不同 generation → 账本只占一条 ────────────────────
    @Test
    fun two_discoveries_of_the_same_file_differing_only_in_generation_admit_one_item() {
        val dir = tempDir("dedupe")
        val ledger = DiscoveryLedgerStore(dir)

        // 第一次发现（真机上 generation 是 61047）
        ledger.commitDiscoveryPage(listOf(candidate()), cursor(61047L))
        // 照片被移进已选相册：generation 跳到 61058，内容没动
        ledger.commitDiscoveryPage(listOf(candidate()), cursor(61058L))

        val items = DiscoveryLedgerStore(dir).load().items
        assertEquals(
            "内容没变的同一张照片只许在账本里占一条，实际：" +
                items.joinToString { "${it.stableId}=${it.deliveryState}" },
            1,
            items.size,
        )
        dir.deleteRecursively()
    }

    // ── 验收 1 的反证：把 generation 放回身份里，上面那条必须失败 ─────────
    //
    // 这不是「换个写法再测一遍」：它证明去重确实是靠「generation 不在
    // stableId 里」成立的，而不是靠 commitDiscoveryPage 碰巧做了别的什么。
    @Test
    fun counter_proof_putting_generation_back_into_the_identity_readmits_the_same_photo() {
        val dir = tempDir("counter")
        val ledger = DiscoveryLedgerStore(dir)

        ledger.commitDiscoveryPage(listOf(legacyCandidate(61047L)), cursor(61047L))
        ledger.commitDiscoveryPage(listOf(legacyCandidate(61058L)), cursor(61058L))

        val items = DiscoveryLedgerStore(dir).load().items
        assertEquals(
            "反证锚点：generation 一旦进 stableId，同一张照片必然变成两条——" +
                "这正是 MOB-98 的原始故障。如果这里等于 1，说明上面那条用例已经" +
                "失去判别力，去重是别的东西顺手做掉的。",
            2,
            items.size,
        )
        assertNotEquals(items[0].stableId, items[1].stableId)
        dir.deleteRecursively()
    }

    // ── 验收 2：真实变更不许被去重吞掉 ────────────────────────────────────
    @Test
    fun a_changed_date_modified_or_size_is_still_a_new_version() {
        val dirA = tempDir("modified-changed")
        DiscoveryLedgerStore(dirA).also {
            it.commitDiscoveryPage(listOf(candidate()), cursor(1L))
            it.commitDiscoveryPage(listOf(candidate(dateModified = modified + 1)), cursor(2L))
        }
        assertEquals(
            "date_modified 变了就是真的改过——不能为了去重把真实变更吞掉",
            2,
            DiscoveryLedgerStore(dirA).load().items.size,
        )
        dirA.deleteRecursively()

        val dirB = tempDir("size-changed")
        DiscoveryLedgerStore(dirB).also {
            it.commitDiscoveryPage(listOf(candidate()), cursor(1L))
            it.commitDiscoveryPage(listOf(candidate(byteSize = size + 1)), cursor(2L))
        }
        assertEquals(
            "size 变了就是真的改过",
            2,
            DiscoveryLedgerStore(dirB).load().items.size,
        )
        dirB.deleteRecursively()
    }

    // ── 验收 3：存量账本收敛，不丢任何一条已 CONFIRMED 的事实 ─────────────
    @Test
    fun collapsing_a_legacy_ledger_keeps_the_confirmed_fact_and_its_completion_time() {
        val dir = tempDir("collapse")
        val ledger = DiscoveryLedgerStore(dir)

        // 复刻真机上那一对：旧式三段 sourceVersion，一条 CONFIRMED（带
        // completedAt / receipt / hash），一条 TRANSFERRING（attempt=2，
        // completedAt=0）。
        ledger.commitDiscoveryPage(
            listOf(legacyCandidate(61047L), legacyCandidate(61058L)),
            cursor(61058L),
        )
        val seeded = ledger.load().items
        assertEquals("前提：旧式身份下确实是两条", 2, seeded.size)
        val confirmed = seeded.first()
        val transferring = seeded.last()
        ledger.update { snapshot ->
            snapshot.copy(
                items = listOf(
                    confirmed.copy(
                        deliveryState = DeliveryState.CONFIRMED,
                        completedAt = 1789878900_000L,
                        completionReceiptId = "desktop-receipt-1",
                        contentHash = "da2d79b948fd8c0c3f32d385e13c3cdd99aa0eeeeb50b8735109e2fefd9d4250",
                    ),
                    transferring.copy(
                        deliveryState = DeliveryState.TRANSFERRING,
                        attemptCount = 2,
                    ),
                ),
            )
        }

        DiscoveryLedgerStore(dir).collapseGenerationDuplicates()

        val after = DiscoveryLedgerStore(dir).load().items
        assertEquals("收敛后只剩一条", 1, after.size)
        val survivor = after.single()
        assertEquals(
            "已确认成功是最强事实，不许被 TRANSFERRING 盖掉",
            DeliveryState.CONFIRMED,
            survivor.deliveryState,
        )
        assertEquals(
            "completedAt 丢了就是把刚修完的 MOB-53 重新引回来",
            1789878900_000L,
            survivor.completedAt,
        )
        assertEquals("desktop-receipt-1", survivor.completionReceiptId)
        assertTrue("contentHash 必须留住", survivor.contentHash != null)
        assertEquals("排队位置取先被收下的那个，不许被甩到队尾", minOf(confirmed.queueSequence, transferring.queueSequence), survivor.queueSequence)
        assertEquals("身份已改写成两段式", sourceVersionOf(modified, size), survivor.sourceVersion)

        // 幂等：再跑一遍不得有任何变化。
        DiscoveryLedgerStore(dir).collapseGenerationDuplicates()
        assertEquals(after, DiscoveryLedgerStore(dir).load().items)
        dir.deleteRecursively()
    }

    // ── 迁移是必须项，不是清理：不改写存量 stableId 会让全库重新入队 ──────
    @Test
    fun a_collapsed_ledger_does_not_readmit_the_same_photo_on_the_next_full_scan() {
        val dir = tempDir("rescan")
        val ledger = DiscoveryLedgerStore(dir)
        ledger.commitDiscoveryPage(listOf(legacyCandidate(61047L)), cursor(61047L))
        assertEquals(1, ledger.load().items.size)

        DiscoveryLedgerStore(dir).collapseGenerationDuplicates()

        // 迁移之后的全量重扫用的是新式身份。若存量行没被改写，这一页会被
        // 当成新照片重新收下——整个相册库都会这样，比原 bug 更糟。
        DiscoveryLedgerStore(dir).commitDiscoveryPage(listOf(candidate()), cursor(61058L))
        assertEquals(
            "存量行必须被改写成新式身份，否则下一次全量扫描会把整库重新入队",
            1,
            DiscoveryLedgerStore(dir).load().items.size,
        )
        dir.deleteRecursively()
    }
}
