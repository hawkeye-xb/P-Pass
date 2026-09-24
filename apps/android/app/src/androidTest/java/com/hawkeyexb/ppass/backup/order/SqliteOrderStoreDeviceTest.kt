// ARCH-12 (#416) → #413: SqliteOrderStore 与 ContentResolverMediaSnapshotSource 的设备测试。
//
// src/test 里的 OrderStoreContract 在 androidTest 编译单元里不可见（两套源集互不引用，
// 改 build.gradle 共享源码不在本卡范围），所以这里按同样的用例逐条对 SQLite 实现再跑一遍（用例正文与契约逐字一致）。
// 全部用内存库（name = null），不碰 App 自己的数据；MediaStore 只读。
package com.hawkeyexb.ppass.backup.order

import android.os.Build
import android.provider.MediaStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SqliteOrderStoreDeviceTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private var now = 1_000L
    private val clock: () -> Long = { now }
    private val opened = mutableListOf<SqliteOrderStore>()

    private fun fresh(): SqliteOrderStore = SqliteOrderStore.open(context, name = null, clock = clock).also { opened += it }

    @After
    fun close() = opened.forEach { it.close() }

    private fun newOrder(mediaId: Long, state: OrderState = OrderState.TRANSFERRING, hash: String? = "h$mediaId", version: String = "v1") =
        NewOrder(mediaId = mediaId, sourceVersion = version, bucketId = 7, contentHash = hash, state = state, pairingEpoch = "e3")

    @Test
    fun `insert assigns strictly increasing ids and the current row is the newest one per photo`() {
        val store = fresh()
        val a = store.insert(newOrder(10))
        now = 2_000L
        val b = store.insert(newOrder(10, OrderState.PENDING, version = "v2"))
        assertTrue(b.id > a.id)
        assertEquals(1_000L, a.createdAtMs)
        assertEquals(b, store.currentForMedia(10))
        assertEquals(listOf(b.id), store.currentInStates(setOf(OrderState.PENDING, OrderState.TRANSFERRING)).map { it.id })
        assertEquals(emptyList<Order>(), store.currentInStates(setOf(OrderState.PENDING), afterId = b.id))
    }

    @Test
    fun `transition is compare-and-set and writes attempts, hash, G, S and audit in the same step`() {
        val store = fresh()
        store.saveVolumeState(VolumeState("external", 0L, 0L, "v"))
        val o = store.insert(newOrder(1, hash = null))
        assertFalse(store.transition(o.id, setOf(OrderState.PENDING), OrderState.CONFIRMED, advance = GenerationAdvance("external", 9)))
        assertEquals(0L, store.volumeState("external")!!.generation)
        val audit = AuditRecord("ev1", "k", null, 1L)
        assertTrue(
            store.transition(
                o.id, setOf(OrderState.TRANSFERRING), OrderState.FAILED,
                countAttempt = true, contentHash = "abc", advance = GenerationAdvance("external", 9, 3), scanTo = 42, audit = audit,
            ),
        )
        val row = store.get(o.id)!!
        assertEquals(OrderState.FAILED, row.state)
        assertEquals(1, row.attempts)
        assertEquals("abc", row.contentHash)
        assertEquals(VolumeState("external", 9L, 3L, "v"), store.volumeState("external"))
        assertEquals(42L, store.scanState().cursor)
        assertEquals(listOf(audit), store.pendingAudit(10))
    }

    @Test
    fun `G advances lexicographically by generation then media id and never goes back`() {
        val store = fresh()
        store.advanceGeneration(GenerationAdvance("v", 5, 10))
        store.advanceGeneration(GenerationAdvance("v", 5, 3))
        assertEquals(10L, store.volumeState("v")!!.generationMediaId)
        store.advanceGeneration(GenerationAdvance("v", 4, 99))
        assertEquals(5L, store.volumeState("v")!!.generation)
        store.advanceGeneration(GenerationAdvance("v", 6, 1))
        assertEquals(6L to 1L, store.volumeState("v")!!.let { it.generation to it.generationMediaId })
    }

    @Test
    fun `the scan cursor lifecycle - dirty from zero, only moves forward, finish clears it`() {
        val store = fresh()
        assertEquals(ScanState(false, 0L), store.scanState())
        store.markScanDirty()
        store.advanceScan(5)
        store.advanceScan(3)
        assertEquals(ScanState(true, 5L), store.scanState())
        store.markScanDirty()
        assertEquals(ScanState(true, 0L), store.scanState())
        store.finishScan()
        assertEquals(ScanState(false, 0L), store.scanState())
    }

    @Test
    fun `cancel remaining writes the skip list and skips open orders but leaves photos settled since the dialog`() {
        val store = fresh()
        val open = store.insert(newOrder(1))
        store.insert(newOrder(2, OrderState.CONFIRMED))
        store.insert(newOrder(4, OrderState.CONFIRMED, version = "old"))
        val result = store.cancelRemaining(
            listOf(SkipTarget(1, "v1", 7), SkipTarget(2, "v1", 7), SkipTarget(3, "v1", 8), SkipTarget(4, "v1", 7)),
        )
        assertEquals(SkipResult(written = 3, ordersSkipped = 1, untouched = 1), result)
        assertEquals(OrderState.SKIPPED_BY_USER, store.get(open.id)!!.state)
        assertTrue(store.isSkipped(1) && store.isSkipped(3) && store.isSkipped(4))
        assertFalse(store.isSkipped(2))
        assertEquals(listOf(1L, 3L, 4L), store.readSkipList { it.toList() })
        assertEquals(1L, store.countSkipped(setOf(8L)))
        assertEquals("「已跳过」报名单", 3L, store.countCurrentByState(null)[OrderState.SKIPPED_BY_USER])
    }

    @Test
    fun `cancel remaining is one transaction`() {
        val store = fresh()
        val open = store.insert(newOrder(1))
        try {
            store.cancelRemaining(listOf(SkipTarget(1, "v1", 7), SkipTarget(-1, "v1", 7)))
            fail("a bad target must abort the batch")
        } catch (_: IllegalArgumentException) {
        }
        assertEquals(OrderState.TRANSFERRING, store.get(open.id)!!.state)
        assertFalse(store.isSkipped(1))
    }

    @Test
    fun `restore empties the skip list and marks the scan dirty`() {
        val store = fresh()
        store.cancelRemaining(listOf(SkipTarget(1, "v1", 7), SkipTarget(2, "v1", 7)))
        assertEquals(2, store.restoreSkipped())
        assertEquals(0L, store.countSkipped())
        assertEquals(ScanState(true, 0L), store.scanState())
        assertNull(store.countCurrentByState(null)[OrderState.SKIPPED_BY_USER])
    }

    @Test
    fun `retry failed turns current failed rows back to pending and keeps their attempts`() {
        val store = fresh()
        val o = store.insert(newOrder(1))
        store.transition(o.id, setOf(OrderState.TRANSFERRING), OrderState.FAILED, countAttempt = true)
        assertEquals(1, store.retryFailed())
        assertEquals(OrderState.PENDING, store.get(o.id)!!.state)
        assertEquals(1, store.get(o.id)!!.attempts)
    }

    @Test
    fun `changing desktops clears facts and cursors but keeps the skip list and lifts the id floor`() {
        val store = fresh()
        assertFalse(store.claimOwner("desk-a", idFloor = 100))
        val o = store.insert(newOrder(1))
        assertTrue(o.id > 100)
        store.cancelRemaining(listOf(SkipTarget(2, "v1", 7)))
        store.saveVolumeState(VolumeState("v", 3, 3, "x"))
        assertFalse(store.claimOwner("desk-a", idFloor = 5_000))
        assertTrue(store.claimOwner("desk-b", idFloor = 5_000))
        assertNull(store.get(o.id))
        assertNull(store.volumeState("v"))
        assertTrue(store.scanState().dirty)
        assertTrue(store.isSkipped(2))
        assertTrue(store.insert(newOrder(3)).id > 5_000)
    }

    @Test
    fun `ui counts read current rows and confirmed-present`() {
        val store = fresh()
        store.insert(newOrder(1, OrderState.CONFIRMED))
        val gone = store.insert(newOrder(2, OrderState.CONFIRMED))
        store.setSourceMissing(gone.id, true)
        store.insert(newOrder(3, OrderState.FAILED))
        assertEquals(2L, store.countCurrentByState(setOf(7L))[OrderState.CONFIRMED])
        assertEquals(1L, store.countConfirmedPresent(setOf(7L)))
        assertEquals(0L, store.countConfirmedPresent(emptySet()))
        assertEquals(listOf(1L, 2L, 3L), store.readCurrentOrders { rows -> rows.map { it.mediaId }.toList() })
        assertEquals(2, store.confirmedWithHashAfter(0L, 10).size)
    }

    /** MediaStore 只读冒烟：排序、范围过滤、发现游标过滤在真机 ContentResolver 上成立。 */
    @Test
    fun contentResolverSnapshotIsOrderedAndScoped() {
        // 测试 App 未必有读媒体权限：没有权限时查询返回 0 行，本用例只验证不抛异常 + 空结果仍然成立。
        val allBuckets = mutableSetOf<Long>()
        context.contentResolver.query(
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
            arrayOf(MediaStore.MediaColumns.BUCKET_ID),
            "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)",
            arrayOf(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(), MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString()),
            null,
        )?.use { c -> while (c.moveToNext()) allBuckets += c.getLong(0) }

        val source = ContentResolverMediaSnapshotSource(context, { allBuckets })
        val all = source.readInScope(0L) { it.toList() }
        val ids = all.map { it.mediaId }
        assertEquals("strictly ascending _id", ids.sorted().distinct(), ids)
        assertTrue(all.all { it.bucketId in allBuckets })

        // 列名或语法写错会抛异常：让真实的 selection / sortOrder 在 MediaProvider 上执行一次。bucket -1 不存在。
        val probe = ContentResolverMediaSnapshotSource(context, { setOf(-1L) })
        assertEquals(emptyList<MediaSnapshot>(), probe.readInScope(0L) { it.toList() })
        val volumes = probe.volumeNames()
        assertTrue("at least one volume: $volumes", volumes.isNotEmpty())
        volumes.forEach { v -> assertEquals(emptyList<MediaSnapshot>(), probe.readChangedSince(v, 0, 0) { it.toList() }) }
        volumes.forEach { v -> assertTrue(probe.maxGeneration(v) >= 0) }
        assertEquals(emptyList<MediaSnapshot>(), ContentResolverMediaSnapshotSource(context, { null }).readChangedSince(volumes.first(), 0, 0) { it.toList() })

        if (all.isNotEmpty()) {
            val first = all.first()
            val details = source.lookup(first.mediaId)
            assertEquals(first.mediaId, details?.snapshot?.mediaId)
            val sorted = all.sortedWith(compareBy({ it.generation }, { it.mediaId }))
            val mid = sorted[sorted.size / 2]
            val after = volumes.flatMap { v -> source.readChangedSince(v, mid.generation, mid.mediaId) { it.toList() } }
            assertTrue(after.all { it.generation > mid.generation || (it.generation == mid.generation && it.mediaId > mid.mediaId) })
            assertEquals(all.filter { it.mediaId > first.mediaId }, source.readInScope(first.mediaId) { it.toList() })
        }

        val versions = source.volumeVersions()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) assertTrue("getVersion per volume: $versions", versions.isNotEmpty())
        android.util.Log.i("ARCH12", "snapshot rows=${all.size} buckets=${allBuckets.size} volumes=$versions")
    }
}
