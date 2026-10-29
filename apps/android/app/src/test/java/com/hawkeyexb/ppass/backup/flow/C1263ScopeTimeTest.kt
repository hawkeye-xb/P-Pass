package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1263：范围 = 相册 + 开始时间。时间条件只是 inScope 里多一个 `DATE_ADDED >= since`，
 * 扩大 / 缩小沿用 #413 裁定 8：已传完的不删；在途被移出的不续传、丢半截；没传的从待办消失，扩回来自动回来。
 */
class C1263ScopeTimeTest {
    private val today = 1_000L

    // 「从今天起」：以前的照片不传，今天之后新增的照片会传。
    // 反证：readChangedSince / inScope 不看 since → #1 也被传，红。
    @Test
    fun `since today skips earlier photos and sends today's`() = runTest {
        val rig = Rig(this)
        rig.media.since = today
        rig.photo(1, generation = 1, dateAdded = today - 1)
        rig.photo(2, generation = 2, dateAdded = today)
        rig.trigger()
        assertEquals(listOf(2L), rig.delivery.deliveredMediaIds)
        assertEquals(0, rig.pending())
        rig.photo(3, generation = 3, dateAdded = today + 60)
        rig.trigger()
        assertEquals(listOf(2L, 3L), rig.delivery.deliveredMediaIds)
        rig.close()
    }

    // 改成「全部」= 范围扩大：走补扫（SCOPE_ADDED），以前的照片补传上来。
    // 顺序按现有引擎走（10-29 定稿，不改引擎）：#413 取件优先级里对账扫描先于新照片（case matrix D-01），
    // 先补以前的照片 #1 #2，补扫期间新拍的 #3 排在后面。
    // 反证：SCOPE_ADDED 不置脏 / readInScope 仍按 since 过滤 → #1 #2 取不到，红。
    @Test
    fun `widening to all backfills earlier photos after new ones`() = runTest {
        // 生产的起点：onboarding 第一轮 G 从当前最大 generation 起步，已有的照片只能由对账扫描取到。
        val rig = Rig(this, cursors = false)
        rig.media.since = today
        rig.photo(1, generation = 1, dateAdded = today - 86_400)
        rig.photo(2, generation = 2, dateAdded = today - 3_600)
        rig.trigger()
        assertEquals(emptyList<Long>(), rig.delivery.deliveredMediaIds)

        rig.media.since = null
        rig.photo(3, generation = 3, dateAdded = today + 10) // 补扫开始前刚拍的
        rig.trigger(TriggerReason.SCOPE_ADDED)
        assertEquals(listOf(1L, 2L, 3L), rig.delivery.deliveredMediaIds)
        assertEquals(0, rig.pending())
        rig.close()
    }

    // 改回「从今天起」= 范围缩小：没传的不再传（从待办消失），在途的丢半截，已传完的不删；扩回来自动回来。
    // 反证：hasWork / 取件按相册不按时间 → 老照片 #1 照传，红；processExisting 不看时间 → #2 被续传，红。
    @Test
    fun `narrowing back to since today drops pending, discards in-flight, keeps confirmed`() = runTest {
        val rig = Rig(this)
        val old1 = rig.photo(1, generation = 1, dateAdded = today - 100)
        val old2 = rig.photo(2, generation = 2, dateAdded = today - 50)
        val old3 = rig.photo(3, generation = 3, dateAdded = today - 10)
        rig.order(old1, OrderState.PENDING)
        val inFlight = rig.order(old2, OrderState.TRANSFERRING)
        rig.order(old3, OrderState.CONFIRMED)
        rig.store.advanceGeneration(com.hawkeyexb.ppass.backup.order.GenerationAdvance(com.hawkeyexb.ppass.backup.order.LEGACY_VOLUME, 3))

        rig.media.since = today
        rig.trigger()
        assertEquals(emptyList<Long>(), rig.delivery.deliveredMediaIds)
        assertEquals(listOf(inFlight.id), rig.delivery.discarded)
        assertEquals(OrderState.PENDING, rig.state(2))
        assertEquals(OrderState.CONFIRMED, rig.state(3))
        assertEquals(0, rig.pending())
        // 范围外的待传输不让每次触发空转 FGS。
        val acquires = rig.foreground.acquires
        rig.trigger(TriggerReason.MEDIA_CHANGE)
        assertEquals(acquires, rig.foreground.acquires)
        // 账目按范围数：范围外的已确认不进「已备份」。
        assertEquals(0L, rig.store.countConfirmedPresent(setOf(7L), today))
        assertEquals(1L, rig.store.countConfirmedPresent(setOf(7L), null))

        rig.media.since = null
        rig.trigger(TriggerReason.SCOPE_ADDED)
        assertTrue(rig.delivery.deliveredMediaIds.containsAll(listOf(1L, 2L)))
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertEquals(OrderState.CONFIRMED, rig.state(2))
        assertEquals(0, rig.pending())
        rig.close()
    }
}
