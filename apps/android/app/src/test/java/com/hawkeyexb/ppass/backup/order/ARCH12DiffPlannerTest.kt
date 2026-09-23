// ARCH-12 (#416): 差集规划契约，对应 #413 正文与 Case Matrix O 组（order 与差集）。
//
// 全部走真实的 DiffPlanner + InMemoryOrderStore；MediaStore 用内存假源代替，
// 假源的快路径语义与 ContentResolverMediaSnapshotSource 相同（generation > G，按 generation、_id 升序）。
package com.hawkeyexb.ppass.backup.order

import com.hawkeyexb.ppass.backup.flow.sourceVersionOf
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ARCH12DiffPlannerTest {
    /** MediaStore 里的一张照片：快照字段 + 它的字节内容（假 hash 直接用内容串）。 */
    private data class Photo(val mediaId: Long, val modified: Long, val size: Long, val content: String, val generation: Long, val bucketId: Long = 7) {
        val snapshot get() = MediaSnapshot(mediaId, sourceVersionOf(modified, size), bucketId, generation)
    }

    private class FakeMediaSource(photos: List<Photo>) : MediaSnapshotSource {
        val photos = photos.toMutableList()
        override fun <R> readAll(block: (Sequence<MediaSnapshot>) -> R): R =
            block(photos.sortedBy { it.mediaId }.asSequence().map { it.snapshot })

        override fun <R> readChangedSince(volumeName: String, afterGeneration: Long, block: (Sequence<MediaSnapshot>) -> R): R =
            block(photos.filter { it.generation > afterGeneration }.sortedWith(compareBy({ it.generation }, { it.mediaId })).asSequence().map { it.snapshot })

        override fun volumeNames(): List<String> = listOf(LEGACY_VOLUME)

        override fun volumeVersions(): Map<String, String> = mapOf("external_primary" to "v1")

        override fun lookup(mediaId: Long): MediaDetails? = null
    }

    private val store = InMemoryOrderStore { 1L }
    private val hashed = mutableListOf<Long>()
    private var media = FakeMediaSource(emptyList())
    private val planner = DiffPlanner(
        hasher = { snap ->
            hashed += snap.mediaId
            "blake3:" + media.photos.single { it.mediaId == snap.mediaId }.content
        },
        ordersWithHash = store::ordersWithHash,
    )

    private fun slowPresent(): List<DiffAction> = media.readAll { s -> store.readCurrentOrders { o -> planner.planPresent(s, o).toList() } }
    private fun slowGone(): List<DiffAction.Gone> = media.readAll { s -> store.readCurrentOrders { o -> planner.planGone(s, o).toList() } }
    private fun fastPath(g: Long): List<DiffAction> = media.readChangedSince(LEGACY_VOLUME, g) { planner.planFastPath(it, store::currentForMedia).toList() }

    private fun confirmed(p: Photo, state: OrderState = OrderState.CONFIRMED): Order =
        store.insert(NewOrder(p.mediaId, p.snapshot.sourceVersion, p.bucketId, "blake3:" + p.content, state, pairingEpoch = "e1"))

    private inline fun <reified T : DiffAction> List<DiffAction>.only(): List<T> = filterIsInstance<T>()

    // #418：已确认的照片被挪进范围外的相册，慢路径只改 bucket_id（不算 hash、不改状态），英雄区的 m 才不会比 n 多。
    // 反证：去掉 DiffPlanner 范围外分支里的 MappingOnly → 这张得到 null，bucket_id 停在 7，红。
    @Test
    fun `a confirmed photo moved into an unselected album only has its album updated`() {
        val scoped = DiffPlanner(
            hasher = { snap -> hashed += snap.mediaId; "blake3:" + media.photos.single { it.mediaId == snap.mediaId }.content },
            ordersWithHash = store::ordersWithHash,
            inScope = { it == 7L },
        )
        val p = Photo(1, 100, 10, "a", generation = 5, bucketId = 7)
        val row = confirmed(p)
        val moved = p.copy(bucketId = 9)
        media = FakeMediaSource(listOf(moved))
        val actions = media.readAll { s -> store.readCurrentOrders { o -> scoped.planPresent(s, o).toList() } }
        assertEquals(listOf(DiffAction.MappingOnly(moved.snapshot, row)), actions)
        DiffApplier(store, { "e1" }) { 1L }.applyPresent(actions.single())
        assertEquals(9L, store.get(row.id)!!.bucketId)
        assertEquals(OrderState.CONFIRMED, store.get(row.id)!!.state)
        assertTrue("no hash is computed for an out-of-scope photo", hashed.isEmpty())
    }

    // O：新照片 → 待传。
    @Test
    fun `new photo is planned for upload`() {
        val old = Photo(1, 100, 10, "old", generation = 5)
        confirmed(old)
        media = FakeMediaSource(listOf(old, Photo(2, 200, 20, "fresh", generation = 6)))
        val actions = slowPresent()
        assertEquals(1, actions.size)
        val up = actions.single() as DiffAction.Upload
        assertEquals(2L, up.mediaId)
        assertEquals("blake3:fresh", up.contentHash)
        assertEquals(DiffAction.Reason.NEW, up.reason)
        assertEquals("unchanged photos are never hashed", listOf(2L), hashed)
        assertEquals(listOf(up), fastPath(g = 5).only<DiffAction.Upload>())
    }

    // O：快路径漏掉（generation ≤ G）的照片，慢路径补上。
    @Test
    fun `photo missed by the fast path is caught by the slow path`() {
        val known = Photo(1, 100, 10, "known", generation = 90)
        confirmed(known)
        // generation 50 < G=100：比如 G 被推得太前，或者 API<30 上 DATE_MODIFIED 是旧时间。
        val missed = Photo(2, 50, 20, "missed", generation = 50)
        media = FakeMediaSource(listOf(known, missed))
        assertEquals("fast path is only a hint and cannot see it", emptyList<DiffAction>(), fastPath(g = 100))
        val slow = slowPresent()
        assertEquals(listOf(2L), slow.only<DiffAction.Upload>().map { it.mediaId })
    }

    // O：MediaStore 重建后 _id 全变、hash 相同 → 不重传，只更新映射；两遍之后不产出 Gone。
    @Test
    fun `rebuilt media store with new ids but same content is not re-uploaded`() {
        val a = Photo(1, 100, 10, "A", generation = 1)
        val b = Photo(2, 200, 20, "B", generation = 2)
        val oa = confirmed(a)
        val ob = confirmed(b, OrderState.SKIPPED_BY_USER)
        media = FakeMediaSource(listOf(a.copy(mediaId = 101, generation = 1), b.copy(mediaId = 102, generation = 1)))

        val present = slowPresent()
        assertEquals("nothing is re-uploaded", emptyList<DiffAction.Upload>(), present.only<DiffAction.Upload>())
        val known = present.only<DiffAction.KnownContent>()
        assertEquals(listOf(101L to oa.id, 102L to ob.id), known.map { it.mediaId to it.existing.single().id })

        // 第一遍落库（这里用最小的「搬映射」），第二遍不再把旧 id 判成 Gone。
        known.forEach { store.updateMapping(it.existing.single().id, it.snapshot.mediaId, it.snapshot.sourceVersion, it.snapshot.bucketId) }
        assertEquals(emptyList<DiffAction.Gone>(), slowGone())
        assertEquals(OrderState.CONFIRMED, store.get(oa.id)!!.state)
        assertEquals(OrderState.SKIPPED_BY_USER, store.get(ob.id)!!.state)
        assertEquals("steady state after remap", emptyList<DiffAction>(), slowPresent())
    }

    // O：编辑后（版本与内容都变）→ 按新版本待传；只动了修改时间、内容没变 → 只更新版本。
    @Test
    fun `edited photo is uploaded as a new version, touched photo only updates version`() {
        val edited = Photo(1, 100, 10, "before", generation = 1)
        val touched = Photo(2, 200, 20, "same", generation = 2)
        val oe = confirmed(edited)
        val ot = confirmed(touched)
        media = FakeMediaSource(listOf(edited.copy(modified = 111, size = 11, content = "after", generation = 9), touched.copy(modified = 222, generation = 9)))

        val actions = slowPresent()
        val up = actions.only<DiffAction.Upload>().single()
        assertEquals(DiffAction.Reason.CHANGED, up.reason)
        assertEquals(oe, up.previous)
        assertEquals("blake3:after", up.contentHash)
        assertEquals(sourceVersionOf(111, 11), up.snapshot.sourceVersion)
        val mapping = actions.only<DiffAction.MappingOnly>().single()
        assertEquals(ot, mapping.order)
        assertEquals(sourceVersionOf(222, 20), mapping.snapshot.sourceVersion)
        assertEquals(2, actions.size)
        assertEquals(actions, fastPath(g = 5))
    }

    // O：源文件删除 → Gone；已是 SKIPPED_SOURCE_MISSING 的不再重复产出。
    @Test
    fun `deleted source is gone unless already marked missing`() {
        val kept = Photo(2, 200, 20, "kept", generation = 2)
        val deleted = confirmed(Photo(1, 100, 10, "deleted", generation = 1))
        confirmed(kept)
        val alreadyMissing = confirmed(Photo(3, 300, 30, "missing", generation = 3), OrderState.SKIPPED_SOURCE_MISSING)
        val skippedThenDeleted = confirmed(Photo(4, 400, 40, "skipped", generation = 4), OrderState.SKIPPED_BY_USER)
        media = FakeMediaSource(listOf(kept))

        assertEquals(emptyList<DiffAction>(), slowPresent())
        val gone = slowGone().map { it.order }
        assertEquals(listOf(deleted, skippedThenDeleted), gone)
        assertTrue(alreadyMissing !in gone)
    }

    // O：用户跳过的照片不会被补传——同版本、改版本、换 _id 三种都不产出待传。
    // #415 裁决 5：CANCELLED_BY_SCOPE 不是长期决定，同内容改了版本只更新映射（落库时重新准入，见 ARCH13OrderRulingsTest）。
    @Test
    fun `user-decided photos are never planned for upload`() {
        val skipped = Photo(1, 100, 10, "skipped", generation = 1)
        val cancelled = Photo(2, 200, 20, "cancelled", generation = 2)
        val sameVersion = Photo(3, 300, 30, "same", generation = 3)
        confirmed(skipped, OrderState.SKIPPED_BY_USER)
        confirmed(cancelled, OrderState.CANCELLED_BY_SCOPE)
        confirmed(sameVersion, OrderState.SKIPPED_BY_USER)
        media = FakeMediaSource(
            listOf(
                skipped.copy(modified = 101, content = "skipped-edited", generation = 10),
                cancelled.copy(modified = 201, generation = 10),
                sameVersion,
                // 同内容换了 _id（另存/重建）：hash 命中 SKIPPED_BY_USER 的 order。
                skipped.copy(mediaId = 50, generation = 11),
            ),
        )
        val actions = slowPresent()
        assertEquals(emptyList<DiffAction.Upload>(), actions.only<DiffAction.Upload>())
        assertEquals(listOf(1L), actions.only<DiffAction.Suppressed>().map { it.mediaId })
        assertEquals(listOf(2L), actions.only<DiffAction.MappingOnly>().map { it.mediaId })
        assertEquals(listOf(50L), actions.only<DiffAction.KnownContent>().map { it.mediaId })
        assertEquals("suppressed photos are not even hashed", listOf(2L, 50L), hashed)
        assertEquals(emptyList<DiffAction.Upload>(), fastPath(g = 0).only<DiffAction.Upload>())
    }

    // O：批量跳过之后，被跳过的照片不产出待传；中途失败的批次一张都不算跳过。
    @Test
    fun `batch skip is atomic end to end`() {
        val photos = (1L..3L).map { Photo(it, 100 * it, it, "c$it", generation = it) }
        media = FakeMediaSource(photos)
        val targets = photos.map { SkipTarget(it.mediaId, it.snapshot.sourceVersion, it.bucketId) }

        try {
            store.skipByUser(targets.take(2) + SkipTarget(0, "bad", 7) + targets.drop(2), pairingEpoch = "e1")
            fail("invalid target must abort the batch")
        } catch (expected: IllegalArgumentException) {
            // 预期
        }
        assertEquals("rolled back: all three still pending", listOf(1L, 2L, 3L), slowPresent().only<DiffAction.Upload>().map { it.mediaId })

        assertEquals(SkipResult(inserted = 3, updated = 0, untouched = 0), store.skipByUser(targets, pairingEpoch = "e1"))
        assertEquals(emptyList<DiffAction>(), slowPresent())
    }

    @Test
    fun `unordered input is rejected instead of silently mis-merged`() {
        val out = listOf(Photo(2, 1, 1, "b", 1).snapshot, Photo(1, 1, 1, "a", 1).snapshot)
        try {
            planner.planPresent(out.asSequence(), emptySequence()).toList()
            fail("descending snapshot must throw")
        } catch (expected: IllegalStateException) {
            assertTrue(expected.message!!.contains("strictly ascending"))
        }
    }

    // 超时兜底：两边都是无限流，实现一旦不再惰性（或一直产出不了动作）就会挂死而不是变红。
    @Test(timeout = 10_000)
    fun `planning is lazy - both sides are consumed one row at a time`() {
        var pulledSnapshots = 0L
        var pulledOrders = 0L
        val snapshots = generateSequence(1L) { it + 1 }.map { pulledSnapshots++; MediaSnapshot(it * 2, "v", 7, it) }
        val orders = generateSequence(1L) { it + 1 }.map {
            pulledOrders++
            Order(it, it * 2 + 1, "v", 7, "h", OrderState.CONFIRMED, 0, "e1", 0, 0)
        }
        val lazyPlanner = DiffPlanner(hasher = { "h${it.mediaId}" }, ordersWithHash = { emptyList() })
        val first = lazyPlanner.planPresent(snapshots, orders).take(3).toList()
        assertEquals(listOf(2L, 4L, 6L), first.map { it.mediaId })
        assertTrue("snapshots pulled: $pulledSnapshots", pulledSnapshots <= 4)
        assertTrue("orders pulled: $pulledOrders", pulledOrders <= 4)
    }

    @Test
    fun `unreadable photo is reported, not fatal`() {
        media = FakeMediaSource(listOf(Photo(1, 1, 1, "x", 1), Photo(2, 1, 1, "y", 1)))
        val failing = DiffPlanner(
            hasher = { if (it.mediaId == 1L) throw java.io.FileNotFoundException("gone") else "h" },
            ordersWithHash = { emptyList() },
        )
        val actions = media.readAll { s -> failing.planPresent(s, emptySequence()).toList() }
        assertTrue(actions[0] is DiffAction.Unhashable)
        assertTrue(actions[1] is DiffAction.Upload)
    }
}
