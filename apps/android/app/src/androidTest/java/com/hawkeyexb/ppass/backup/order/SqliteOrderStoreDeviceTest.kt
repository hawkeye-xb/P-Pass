// ARCH-12 (#416): SqliteOrderStore 与 ContentResolverMediaSnapshotSource 的设备测试。
//
// src/test 里的 OrderStoreContract 在 androidTest 编译单元里不可见（两套源集互不引用，
// 改 build.gradle 共享源码不在本卡范围），所以这里按同样的用例逐条对 SQLite 实现再跑一遍。
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
    private val store = SqliteOrderStore.open(context, name = null, clock = { now })

    @After
    fun close() = store.close()

    private fun newOrder(mediaId: Long, state: OrderState = OrderState.TRANSFERRING, hash: String? = "h$mediaId", version: String = "v1") =
        NewOrder(mediaId = mediaId, sourceVersion = version, bucketId = 7, contentHash = hash, state = state, pairingEpoch = 3)

    @Test
    fun insertAssignsIncreasingIdsAndStampsTime() {
        val a = store.insert(newOrder(10))
        now = 2_000L
        val b = store.insert(newOrder(5))
        assertTrue(b.id > a.id)
        assertEquals(1_000L, a.createdAtMs)
        assertEquals(2_000L, b.updatedAtMs)
        assertEquals(a, store.get(a.id))
        assertNull(store.get(b.id + 1000))
    }

    @Test
    fun currentOrderIsNewestRow() {
        store.insert(newOrder(10, OrderState.CONFIRMED, "old"))
        val edited = store.insert(newOrder(10, OrderState.TRANSFERRING, "new", version = "v2"))
        assertEquals(edited, store.currentForMedia(10))
        assertNull(store.currentForMedia(11))
    }

    @Test
    fun currentOrdersStreamAscendingAcrossPages() {
        for (m in 600L downTo 1L) store.insert(newOrder(m, OrderState.CONFIRMED, "a$m"))
        for (m in 1L..600L step 3) store.insert(newOrder(m, OrderState.TRANSFERRING, "b$m", version = "v2"))
        val seen = store.readCurrentOrders { it.toList() }
        assertEquals((1L..600L).toList(), seen.map { it.mediaId })
        seen.forEach { o ->
            val expected = if ((o.mediaId - 1) % 3 == 0L) "b${o.mediaId}" else "a${o.mediaId}"
            assertEquals("media ${o.mediaId}", expected, o.contentHash)
        }
    }

    @Test
    fun writingDuringStreamNeverRepeatsMediaId() {
        for (m in 1L..300L) store.insert(newOrder(m))
        val seen = store.readCurrentOrders { rows ->
            rows.map { o ->
                store.insert(newOrder(o.mediaId, hash = "edit${o.mediaId}", version = "v2"))
                o.mediaId
            }.toList()
        }
        assertEquals((1L..300L).toList(), seen)
    }

    @Test
    fun ordersWithHash() {
        val a = store.insert(newOrder(1, hash = "same"))
        val b = store.insert(newOrder(2, hash = "same"))
        store.insert(newOrder(3, hash = "other"))
        store.insert(newOrder(4, hash = null))
        assertEquals(listOf(a, b), store.ordersWithHash("same"))
        assertEquals(emptyList<Order>(), store.ordersWithHash("missing"))
    }

    @Test
    fun transitionIsCompareAndSet() {
        val o = store.insert(newOrder(1, OrderState.TRANSFERRING))
        assertFalse(store.transition(o.id, setOf(OrderState.PAUSED), OrderState.CONFIRMED))
        assertEquals(OrderState.TRANSFERRING, store.get(o.id)!!.state)
        now = 5_000L
        assertTrue(store.transition(o.id, setOf(OrderState.TRANSFERRING, OrderState.PAUSED), OrderState.FAILED, countAttempt = true))
        val failed = store.get(o.id)!!
        assertEquals(OrderState.FAILED, failed.state)
        assertEquals(1, failed.attempts)
        assertEquals(5_000L, failed.updatedAtMs)
        assertFalse(store.transition(o.id + 99, setOf(OrderState.FAILED), OrderState.CONFIRMED))
        assertFalse(store.transition(o.id, emptySet(), OrderState.CONFIRMED))
    }

    @Test
    fun updateMappingKeepsStateAndHash() {
        val o = store.insert(newOrder(1, OrderState.CONFIRMED, "h"))
        assertTrue(store.updateMapping(o.id, mediaId = 101, sourceVersion = "v9", bucketId = 8))
        val moved = store.get(o.id)!!
        assertEquals(listOf(101L, 8L), listOf(moved.mediaId, moved.bucketId))
        assertEquals("v9", moved.sourceVersion)
        assertEquals(OrderState.CONFIRMED, moved.state)
        assertEquals("h", moved.contentHash)
        assertNull(store.currentForMedia(1))
        assertFalse(store.updateMapping(o.id + 99, 1, "v", 1))
    }

    @Test
    fun skipByUserInsertsClosesAndLeaves() {
        val open = store.insert(newOrder(1, OrderState.PAUSED))
        val failed = store.insert(newOrder(2, OrderState.FAILED))
        val confirmed = store.insert(newOrder(3, OrderState.CONFIRMED))
        val result = store.skipByUser(
            listOf(SkipTarget(1, "v1", 7), SkipTarget(2, "v1", 7), SkipTarget(3, "v1", 7), SkipTarget(4, "v4", 9)),
            pairingEpoch = 5,
        )
        assertEquals(SkipResult(inserted = 1, updated = 2, untouched = 1), result)
        assertEquals(OrderState.SKIPPED_BY_USER, store.get(open.id)!!.state)
        assertEquals(OrderState.SKIPPED_BY_USER, store.get(failed.id)!!.state)
        assertEquals(OrderState.CONFIRMED, store.get(confirmed.id)!!.state)
        val inserted = store.currentForMedia(4)!!
        assertEquals(OrderState.SKIPPED_BY_USER, inserted.state)
        assertEquals(5L, inserted.pairingEpoch)
        assertNull(inserted.contentHash)
    }

    @Test
    fun skipByUserIsOneTransaction() {
        val open = store.insert(newOrder(1, OrderState.TRANSFERRING))
        val before = store.readCurrentOrders { it.toList() }
        try {
            store.skipByUser(
                listOf(SkipTarget(1, "v1", 7), SkipTarget(2, "v2", 7), SkipTarget(-1, "bad", 7), SkipTarget(3, "v3", 7)),
                pairingEpoch = 5,
            )
            fail("a non-positive media id must abort the batch")
        } catch (expected: IllegalArgumentException) {
            // 预期
        }
        assertEquals(before, store.readCurrentOrders { it.toList() })
        assertEquals(OrderState.TRANSFERRING, store.get(open.id)!!.state)
        assertNull(store.currentForMedia(2))
        assertTrue(store.insert(newOrder(9)).id > open.id)
    }

    @Test
    fun skipByUserOverSqliteBindLimitIsOneBatch() {
        // 5000 > API 26 SQLite 的 999 绑定变量上限：逐条预编译语句，不拼 IN (…)。
        val targets = (1L..5000L).map { SkipTarget(it, "v$it", 7) }
        assertEquals(SkipResult(inserted = 5000, updated = 0, untouched = 0), store.skipByUser(targets, pairingEpoch = 1))
        assertEquals(5000, store.readCurrentOrders { rows -> rows.count { it.state == OrderState.SKIPPED_BY_USER } })
    }

    @Test
    fun volumeStateRoundTrips() {
        assertNull(store.volumeState("external_primary"))
        store.saveVolumeState(VolumeState("external_primary", 120, "v-a"))
        store.saveVolumeState(VolumeState("0a1b-2c3d", 7, null))
        store.saveVolumeState(VolumeState("external_primary", 130, "v-b"))
        assertEquals(VolumeState("external_primary", 130, "v-b"), store.volumeState("external_primary"))
        assertEquals(VolumeState("0a1b-2c3d", 7, null), store.volumeState("0a1b-2c3d"))
        assertEquals(listOf("0a1b-2c3d", "external_primary"), store.volumeNames())
    }

    /** MediaStore 只读冒烟：排序、范围过滤、快路径过滤在真机 ContentResolver 上成立。 */
    @Test
    fun contentResolverSnapshotIsOrderedAndScoped() {
        // 先不限范围拿到本机所有 bucket，再挑一个做范围过滤（测试 App 未必有读媒体权限：
        // 没有权限时查询返回 0 行，本用例只验证不抛异常 + 空结果仍然成立）。
        val allBuckets = mutableSetOf<Long>()
        context.contentResolver.query(
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
            arrayOf(MediaStore.MediaColumns.BUCKET_ID),
            "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)",
            arrayOf(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(), MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString()),
            null,
        )?.use { c -> while (c.moveToNext()) allBuckets += c.getLong(0) }

        val all = ContentResolverMediaSnapshotSource(context, { allBuckets }).readAll { it.toList() }
        val ids = all.map { it.mediaId }
        assertEquals("strictly ascending _id", ids.sorted().distinct(), ids)
        assertTrue(all.all { it.bucketId in allBuckets })

        // 无论有没有读媒体权限，都让真实的 selection / sortOrder 在 MediaProvider 上执行一次：
        // 列名或语法写错会抛异常。bucket -1 不存在，所以结果必为空。
        val probe = ContentResolverMediaSnapshotSource(context, { setOf(-1L) })
        assertEquals(emptyList<MediaSnapshot>(), probe.readAll { it.toList() })
        assertEquals(emptyList<MediaSnapshot>(), probe.readChangedSince(0) { it.toList() })

        val none = ContentResolverMediaSnapshotSource(context, { null }).readAll { it.toList() }
        assertEquals(emptyList<MediaSnapshot>(), none)

        if (all.isNotEmpty()) {
            val one = all.first().bucketId
            val scoped = ContentResolverMediaSnapshotSource(context, { setOf(one) }).readAll { it.toList() }
            assertEquals(all.filter { it.bucketId == one }, scoped)

            val g = all.map { it.generation }.sorted()[all.size / 2]
            val fast = ContentResolverMediaSnapshotSource(context, { allBuckets }).readChangedSince(g) { it.toList() }
            assertTrue(fast.all { it.generation > g })
            assertEquals(fast.sortedWith(compareBy({ it.generation }, { it.mediaId })), fast)
            assertEquals(all.count { it.generation > g }, fast.size)
        }

        val versions = ContentResolverMediaSnapshotSource(context, { allBuckets }).volumeVersions()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) assertTrue("getVersion per volume: $versions", versions.isNotEmpty())
        android.util.Log.i("ARCH12", "snapshot rows=${all.size} buckets=${allBuckets.size} volumes=$versions")
    }
}
