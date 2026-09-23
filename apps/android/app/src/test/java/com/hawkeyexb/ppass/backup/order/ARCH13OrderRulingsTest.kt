// ARCH-13 (#417) 第 1 步：#416 遗留点的裁决（#413 最后一条评论，裁决 1/2/3/5/7）的契约测试。
//
// 全部走真实的 DiffPlanner + DiffApplier + LocalReconciler + InMemoryOrderStore；MediaStore 用 FakeMedia。
// 每条都附反证：去掉对应的修复（写在测试上方），这条必须变红——反证输出见 #417 报告。
package com.hawkeyexb.ppass.backup.order

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ARCH13OrderRulingsTest {
    private val store = InMemoryOrderStore { 1L }
    private val media = FakeMedia()
    private val planner = DiffPlanner(
        hasher = { media.hash(it.mediaId) },
        ordersWithHash = store::ordersWithHash,
        inScope = media::inScope,
    )
    private val reconciler = LocalReconciler(store, media, planner, DiffApplier(store, { "e1" }, { 1L }))

    private fun row(p: FakePhoto, state: OrderState, hash: String? = p.hash): Order =
        store.insert(NewOrder(p.mediaId, p.snapshot.sourceVersion, p.bucketId, hash, state, "e1"))

    // 裁决 1：慢路径快照不按相册过滤。相册移出范围、照片还在 → CANCELLED_BY_SCOPE，不是 Gone。
    // 反证：MediaSnapshotSource.readAll 按范围过滤（FakeMedia.readAll 加 inScope 过滤）或
    // DiffPlanner.classify 删掉 OutOfScope 分支 → 这张被判 SKIPPED_SOURCE_MISSING / 保持 PAUSED，变红。
    @Test
    fun `ruling 1 - out-of-scope photo becomes CANCELLED_BY_SCOPE, never Gone, and is never hashed`() {
        val other = FakePhoto(1, 100, 10, "other-album", generation = 1, bucketId = 9)
        val stranger = FakePhoto(2, 200, 20, "never-selected", generation = 2, bucketId = 9)
        val paused = row(other, OrderState.PAUSED)
        media.put(other)
        media.put(stranger)

        val stats = reconciler.run()

        assertEquals(OrderState.CANCELLED_BY_SCOPE, store.get(paused.id)!!.state)
        assertFalse(store.get(paused.id)!!.sourceMissing)
        assertEquals(1, stats.cancelledByScope)
        assertEquals(0, stats.sourceMissingSkipped)
        assertNull("an out-of-scope photo without an order stays untouched", store.currentForMedia(2))
        assertEquals("out-of-scope photos are never hashed (D-06)", emptyList<Long>(), media.hashed)
    }

    // 裁决 2：Gone 不改写 CONFIRMED，只打 source_missing；原图重新出现清掉标记；打过标记的不再重复产出 Gone。
    // 反证：DiffApplier.applyGone 对 CONFIRMED 也 transition 成 SKIPPED_SOURCE_MISSING → 第一条断言红；
    // DiffPlanner.planGone 不排除 sourceMissing → 第二次慢路径 stats.sourceMissingFlagged 变 1，红。
    @Test
    fun `ruling 2 - a deleted original never rewrites CONFIRMED, only flags it, and the flag clears on return`() {
        val p = FakePhoto(1, 100, 10, "backed-up", generation = 1)
        val confirmed = row(p, OrderState.CONFIRMED)

        val first = reconciler.run()
        assertEquals(OrderState.CONFIRMED, store.get(confirmed.id)!!.state)
        assertTrue(store.get(confirmed.id)!!.sourceMissing)
        assertEquals(1, first.sourceMissingFlagged)
        assertEquals("the flag is audited", 1, store.audits().size)

        val second = reconciler.run()
        assertEquals("a flagged row is not Gone again", 0, second.sourceMissingFlagged)
        assertEquals(1, store.audits().size)

        media.put(p) // 从回收站恢复
        val third = reconciler.run()
        assertEquals(1, third.sourceReappeared)
        assertFalse(store.get(confirmed.id)!!.sourceMissing)
        assertEquals(OrderState.CONFIRMED, store.get(confirmed.id)!!.state)
    }

    // 裁决 3（前半）：hash 已存在 → 新增一行，不搬迁旧行；新行直接 CONFIRMED，不传。
    // 反证：DiffApplier 对 KnownContent 改成 updateMapping(旧行) → 旧行的 mediaId 被改写，第一条断言红。
    @Test
    fun `ruling 3 - known content gets its own new CONFIRMED row and the old row is not moved`() {
        val original = FakePhoto(1, 100, 10, "same-bytes", generation = 1)
        val wechatCopy = FakePhoto(2, 300, 10, "same-bytes", generation = 5)
        val old = row(original, OrderState.CONFIRMED)
        media.put(original)
        media.put(wechatCopy)

        val stats = reconciler.run()

        assertEquals(1L, store.get(old.id)!!.mediaId)
        val copy = store.currentForMedia(2)!!
        assertEquals(OrderState.CONFIRMED, copy.state)
        assertEquals(original.hash, copy.contentHash)
        assertEquals(1, stats.knownConfirmed)
        assertEquals("steady state: nothing more to do", ApplyStats(), reconciler.run())
    }

    // 裁决 3（后半）：旧行消失、但它的 hash 在另一条现存行上（MediaStore 重建）→ 删掉旧行，
    // 不标 source_missing、不算「已从手机删除」。
    // 反证：DiffApplier.applyGone 去掉 hashLivesElsewhere 分支 → 旧行留下并打标记，deletedMoved=0，红。
    @Test
    fun `ruling 3 - after a MediaStore rebuild the stale rows are deleted, not flagged`() {
        val a = FakePhoto(1, 100, 10, "A", generation = 1)
        val b = FakePhoto(2, 200, 20, "B", generation = 2)
        val oa = row(a, OrderState.CONFIRMED)
        val ob = row(b, OrderState.CONFIRMED)
        media.put(a.copy(mediaId = 101))
        media.put(b.copy(mediaId = 102))

        val stats = reconciler.run()

        assertNull(store.get(oa.id))
        assertNull(store.get(ob.id))
        assertEquals(2, stats.deletedMoved)
        assertEquals(0, stats.sourceMissingFlagged)
        assertEquals(listOf(OrderState.CONFIRMED, OrderState.CONFIRMED), store.allRows().map { it.state })
        assertEquals(listOf(101L, 102L), store.allRows().map { it.mediaId })
        assertTrue("no source-missing audit", store.audits().isEmpty())
    }

    // 裁决 3 的边界（执行方裁定）：hash 只挂在 FAILED 行上时「桌面已有」不成立，新行按待传处理。
    @Test
    fun `known content without any CONFIRMED row is queued, not confirmed`() {
        val failed = FakePhoto(1, 100, 10, "flaky", generation = 1)
        row(failed, OrderState.FAILED)
        media.put(failed)
        media.put(FakePhoto(2, 400, 10, "flaky", generation = 2))

        reconciler.run()

        assertEquals(OrderState.QUEUED, store.currentForMedia(2)!!.state)
    }

    // 裁决 5：SKIPPED_SOURCE_MISSING 不是永久状态——照片重新出现（同 _id、同版本）就恢复为可传。
    // 反证：DiffPlanner.classify 把「同版本」短路提到状态检查之前（#416 原写法）→ 返回 null，状态不变，红。
    @Test
    fun `ruling 5 - a SKIPPED_SOURCE_MISSING photo that reappears is transferable again`() {
        val p = FakePhoto(1, 100, 10, "restored", generation = 1)
        val missing = row(p, OrderState.SKIPPED_SOURCE_MISSING)
        media.put(p)

        val stats = reconciler.run()

        assertEquals(OrderState.QUEUED, store.get(missing.id)!!.state)
        assertEquals(1, stats.readmitted)
    }

    // #415 裁决 5：CANCELLED_BY_SCOPE 的照片所在相册重新纳入范围 → 重新变为可传。
    // 反证：同 ruling 5（classify 的同版本短路提到状态检查之前）→ 状态不变，红。
    @Test
    fun `a CANCELLED_BY_SCOPE photo whose album comes back is transferable again`() {
        val p = FakePhoto(1, 100, 10, "album-back", generation = 1)
        val cancelled = row(p, OrderState.CANCELLED_BY_SCOPE)
        media.put(p)

        reconciler.run()

        assertEquals(OrderState.QUEUED, store.get(cancelled.id)!!.state)
    }

    // 裁决 7：G 按卷分开存——推进一个卷的 G 不影响另一个卷。
    // （存储层的键；按卷查询、按卷推进由循环的快路径测试 D 组覆盖。）
    @Test
    fun `ruling 7 - fast path cursor G is kept per volume`() {
        store.advanceGeneration(GenerationAdvance("external_primary", 500))
        store.advanceGeneration(GenerationAdvance("1a2b-3c4d", 7))
        store.advanceGeneration(GenerationAdvance("external_primary", 400))

        assertEquals(500L, store.volumeState("external_primary")!!.fastPathGeneration)
        assertEquals(7L, store.volumeState("1a2b-3c4d")!!.fastPathGeneration)
        assertEquals(listOf("1a2b-3c4d", "external_primary"), store.volumeNames())
    }

    // 裁决 9：Unhashable 按单张失败处理，计入次数。
    @Test
    fun `unhashable photo is recorded as FAILED with one attempt`() {
        val p = FakePhoto(1, 100, 10, "unreadable", generation = 1)
        media.put(p)
        val broken = DiffPlanner(
            hasher = { throw SecurityException("no access") },
            ordersWithHash = store::ordersWithHash,
            inScope = media::inScope,
        )
        LocalReconciler(store, media, broken, DiffApplier(store, { "e1" }, { 1L })).run()
        val failed = store.currentForMedia(1)!!
        assertEquals(OrderState.FAILED, failed.state)
        assertEquals(1, failed.attempts)
    }
}
