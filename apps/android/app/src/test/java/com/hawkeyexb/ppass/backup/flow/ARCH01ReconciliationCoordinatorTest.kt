package com.hawkeyexb.ppass.backup.flow

import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ARCH01ReconciliationCoordinatorTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-arch01-coordinator-$case").toFile()

    @Test
    fun r01_remote_present_is_left_alone_and_remote_missing_with_live_source_is_requeued() {
        runBlocking {
            val dir = tempDir("r01")
            val store = seededStore(dir)
            val sourceProbes = mutableListOf<String>()
            val queried = mutableListOf<List<String>>()

            ReconciliationCoordinator(store).reconcilePage(
                remoteMissing = { hashes ->
                    queried += hashes
                    setOf("b".repeat(64))
                },
                sourcePresence = { sourceRef ->
                    sourceProbes += sourceRef
                    SourcePresence.PRESENT
                },
            )

            val items = store.load().items
            assertEquals(listOf(listOf("a".repeat(64), "b".repeat(64))), queried)
            // 只对桌面说"我没有"的那些问本地源——桌面还在的不必问。
            assertEquals(listOf("content://media/external/images/media/2"), sourceProbes)

            assertEquals(RemotePresence.PRESENT, items[0].remotePresence)
            assertEquals(RecoveryDisposition.NONE, items[0].disposition)
            assertEquals("桌面还在的不动它", DeliveryState.CONFIRMED, items[0].deliveryState)

            // MOB-87：桌面缺了、手机源还在 → **无提示退回队列补传**。
            // 旧契约（ARCH-07「零传输副作用」）把它停在 NEEDS_DECISION 等一个
            // 永远不会来的用户决定：那个计数是 `flowReuploadNoticeCount` 唯一的
            // 写入者，而它没有生产调用方，所以提示卡永远不出现、照片永远不回来。
            //
            // 产品规则（验收人定调）：手机上还有源 → 桌面上就必须有，
            // 桌面为什么没有不问。想让备份里没有它，去手机上删。
            assertEquals(DeliveryState.QUEUED, items[1].deliveryState)
            assertEquals("决定已经做了（自动补传），不再待决", RecoveryDisposition.NONE, items[1].disposition)
            assertEquals(RemotePresence.UNKNOWN, items[1].remotePresence)
            assertNull("旧回执作废——桌面上那份已经不在了", items[1].completionReceiptId)
            assertEquals("重传是全新尝试，不背上一轮的失败次数", 0, items[1].attemptCount)
            dir.deleteRecursively()
        }
    }

    @Test
    fun r02_remote_and_source_both_missing_is_unrecoverable_and_stays_out_of_the_queue() {
        runBlocking {
            val dir = tempDir("r02")
            val store = seededStore(dir)

            ReconciliationCoordinator(store).reconcilePage(
                remoteMissing = { setOf("b".repeat(64)) },
                sourcePresence = { SourcePresence.MISSING },
            )

            val item = store.load().items[1]
            assertEquals(RemotePresence.MISSING, item.remotePresence)
            assertEquals(SourcePresence.MISSING, item.sourcePresence)
            assertEquals(RecoveryDisposition.UNRECOVERABLE, item.disposition)
            // 两边都没了，补不回来——不进队列，也**不做任何用户提示**
            // （拦不住的场景，跟用户自己 copy 文件出去一样管不了；这条标记
            // 唯一的读者是我们，用来查"账本说谎"）。
            assertEquals(DeliveryState.CONFIRMED, item.deliveryState)
            assertEquals(0, item.attemptCount)
            assertEquals(
                "UNRECOVERABLE 不许进任何 UI 投影计数",
                0,
                flowReuploadNoticeCount(store.load()),
            )
            dir.deleteRecursively()
        }
    }

    /**
     * MOB-87 缺陷 #3：旧写法是 `sortedBy(queueSequence).take(500)`，没有游标，
     * 过滤里也不排除已核实过的项——跑一百轮都是同一批前 500 张。库里 1200 张，
     * 第 501 张往后的**一次都不会被核实**。
     */
    @Test
    fun r03_paging_covers_the_whole_ledger_across_rounds_and_then_starts_over() {
        runBlocking {
            val dir = tempDir("r03")
            val total = REMOTE_PRESENCE_PAGE_SIZE * 2 + 200
            val store = seededStore(dir, total)
            val coordinator = ReconciliationCoordinator(store)
            val asked = mutableListOf<List<String>>()
            val probe: suspend (List<String>) -> Set<String> = { hashes ->
                asked += hashes
                emptySet()
            }

            repeat(3) { coordinator.reconcilePage(probe, { SourcePresence.PRESENT }) }

            assertEquals(3, asked.size)
            assertEquals(
                "三轮必须覆盖全部 $total 项",
                (1..total).map { hashOf(it) }.toSet(),
                asked.flatten().toSet(),
            )
            assertTrue(store.load().items.all { it.remotePresence == RemotePresence.PRESENT })

            // ⚠️ 这一段是「过滤掉已 PRESENT 的项」那种写法过不了的红。
            // 那种写法首轮对完之后核对页永久为空、**再也不复查**——桌面在那
            // 之后删掉一张就永远发现不了，正好是本卡要解决的问题，只是推迟到
            // 了首轮之后。游标必须循环。
            //
            // 全部项此刻都已是 PRESENT，所以下一轮问出来的每一个 hash 都是
            // "已经核实过的"——非空本身就是断言。
            coordinator.reconcilePage(probe, { SourcePresence.PRESENT })
            assertEquals(4, asked.size)
            val alreadyVerified = store.load().items
                .filter { it.remotePresence == RemotePresence.PRESENT }
                .mapNotNull { it.contentHash }
                .toSet()
            assertEquals(REMOTE_PRESENCE_PAGE_SIZE, asked[3].size)
            assertTrue(
                "核实过的项必须被重新核实，否则桌面之后删掉的永远发现不了",
                asked[3].all { it in alreadyVerified },
            )
            // 环是连续的：第 3 轮尾部已绕回吃掉 1..300，第 4 轮接着 301 走。
            assertEquals("游标连续，不是每轮都从头重来", hashOf(301), asked[3].first())
            dir.deleteRecursively()
        }
    }

    /**
     * MOB-87 缺陷 #5：账本里有 CONFIRMED 项、却一条都排不进核对页——判据坏了，
     * 是故障。旧写法是裸 `return`，调用方拿到的"对完账了"和"一条都没对上"
     * 是同一个返回值。
     */
    @Test
    fun r04_confirmed_work_that_yields_no_page_is_a_durable_fact_not_a_silent_return() {
        runBlocking {
            val dir = tempDir("r04")
            val store = seededStore(dir)
            // 人为制造判据落空：项的归属章跟快照对不上（迁移漏了就是这个形状）。
            store.update { snapshot ->
                snapshot.copy(items = snapshot.items.map { it.copy(pairingEpoch = PairingEpoch("stale")) })
            }

            var askedDesktop = false
            ReconciliationCoordinator(store).reconcilePage(
                remoteMissing = { askedDesktop = true; emptySet() },
                sourcePresence = { SourcePresence.PRESENT },
            )

            assertFalse("排不出页就不该去打扰桌面", askedDesktop)
            val stalls = store.load().auditOutbox.filter { it.kind == AuditKinds.RECONCILIATION_STALLED }
            assertEquals(1, stalls.size)
            assertEquals("2", stalls.single().payload["confirmedTotal"])
            dir.deleteRecursively()
        }
    }

    @Test
    fun r05_an_empty_ledger_is_not_a_stall_and_writes_nothing() {
        runBlocking {
            val dir = tempDir("r05")
            val store = DiscoveryLedgerStore(dir)

            ReconciliationCoordinator(store).reconcilePage({ emptySet() }, { SourcePresence.PRESENT })

            assertTrue(
                "刚装好、还没传过东西——安静返回才是对的",
                store.load().auditOutbox.none { it.kind == AuditKinds.RECONCILIATION_STALLED },
            )
            dir.deleteRecursively()
        }
    }

    /**
     * MOB-87：桌面离线不是故障，是"这轮没条件干活"。游标不推进，下一轮重试
     * 同一页；**绝不**落 RECONCILIATION_STALLED——那条是留给真故障的，让离线
     * 把它刷成噪音就等于把信号毁掉。
     */
    @Test
    fun r06_unreachable_desktop_leaves_the_ledger_and_the_cursor_untouched() {
        runBlocking {
            val dir = tempDir("r06")
            val store = seededStore(dir)
            val before = store.load()

            ReconciliationCoordinator(store).reconcilePage(
                remoteMissing = { error("backup.presence rejected: peer unreachable") },
                sourcePresence = { SourcePresence.PRESENT },
            )

            val after = store.load()
            assertEquals(before.items, after.items)
            assertEquals(before.reconcileCursor, after.reconcileCursor)
            assertTrue(after.auditOutbox.none { it.kind == AuditKinds.RECONCILIATION_STALLED })
            dir.deleteRecursively()
        }
    }

    /**
     * 防止"只改了 Coordinator 就以为修完了"：写回那两处各有一份同样的 epoch
     * 判据（`RemoteReconciliation.kt:10,37`），落空时网络请求真发出去了、回调
     * 真跑了，只是 `ledger.update` 里一条都没命中——比 page 空更隐蔽。
     */
    @Test
    fun r07_both_write_back_sites_land_when_the_item_epoch_matches_the_snapshot() {
        val dir = tempDir("r07")
        val store = seededStore(dir)
        val reconciliation = RemoteReconciliation(store)

        reconciliation.recordRemotePresent("a".repeat(64))
        reconciliation.recordRemoteMissing("b".repeat(64), SourcePresence.MISSING)

        val items = store.load().items
        assertEquals(RemotePresence.PRESENT, items[0].remotePresence)
        assertEquals(RemotePresence.MISSING, items[1].remotePresence)
        assertEquals(RecoveryDisposition.UNRECOVERABLE, items[1].disposition)
        dir.deleteRecursively()
    }

    /** `commitDiscoveryPage` 自己的上限（`DiscoveryLedger` 私有），播种时按它切块。 */
    private val COMMIT_CHUNK = 500

    private fun hashOf(index: Int): String = index.toString().padStart(64, '0')

    private fun seededStore(dir: File, count: Int = 2): DiscoveryLedgerStore =
        DiscoveryLedgerStore(dir).also { store ->
            val hashes = if (count == 2) listOf("a".repeat(64), "b".repeat(64)) else (1..count).map(::hashOf)
            (1..count).chunked(COMMIT_CHUNK).forEach { chunk ->
                store.commitDiscoveryPage(
                    chunk.map { DiscoveryCandidate("content://media/external/images/media/$it", "g1", 42L) },
                    DiscoveryCursor(1L, chunk.last().toLong()),
                )
            }
            (1..count).forEach { seq ->
                CompletionAndScope(store).acceptCompletionReceipt(
                    CompletionReceipt(seq.toLong(), "r$seq", contentHash = hashes[seq - 1]),
                )
            }
        }
}
