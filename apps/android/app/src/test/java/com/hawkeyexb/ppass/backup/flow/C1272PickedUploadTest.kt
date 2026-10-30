// #1272 挑几张传：手选订单走同一条传输循环，但与自动备份在结构上隔离——手选优先、不进 order 表、不被对账碰、
// 按哈希去重记「已有」、没传成的如实标出。真实 FlowEngine + 内存手选表。每条附反证。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.backup.picked.NewPicked
import com.hawkeyexb.ppass.backup.picked.PickedItem
import com.hawkeyexb.ppass.backup.picked.PickedState
import com.hawkeyexb.ppass.proto.FLOW_SOURCE_AUTO
import com.hawkeyexb.ppass.proto.FLOW_SOURCE_PICKED
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class C1272PickedUploadTest {
    private fun pick(uri: String) = NewPicked(uri, "$uri.jpg", "image/jpeg", 10L, 1_700_000_000_000L)

    // 手选的照片传到桌面，请求带 source=picked、queue_sequence 在手选段（不撞自动备份的 order id）。
    // 反证：processPicked 不传 source → 请求 source 恒为 auto，红。
    @Test
    fun `a picked photo is delivered with source picked and its own sequence range`() = runTest {
        val rig = Rig(this)
        rig.picked.addBatch(listOf(pick("content://picker/1")))
        rig.trigger(TriggerReason.PICKED_ADDED)

        val req = rig.delivery.requests.single()
        assertEquals(FLOW_SOURCE_PICKED, req.source)
        assertTrue(req.orderId >= PickedItem.SEQUENCE_BASE)
        assertEquals(PickedState.DELIVERED, rig.picked.latestBatch()?.let { rig.picked.nextOpen()?.state ?: PickedState.DELIVERED })
        assertEquals(1, rig.picked.latestBatch()!!.delivered)
        assertEquals(listOf("content://picker/1"), rig.pickedSettled)
        rig.close()
    }

    // 手选永远不写进备份范围 / order 表。反证：processPicked 里 store.insert(...) → currentInStates 非空，红。
    @Test
    fun `picked photos never touch the order store`() = runTest {
        val rig = Rig(this)
        rig.picked.addBatch(listOf(pick("content://picker/1"), pick("content://picker/2")))
        rig.trigger(TriggerReason.PICKED_ADDED)

        assertEquals(2, rig.picked.latestBatch()!!.delivered)
        assertTrue(rig.store.currentInStates(OrderState.entries.toSet()).isEmpty())
        rig.close()
    }

    // 手选优先：自动备份有待办时，下一张取的是手选。反证：pickNext 去掉最前面的手选取件 → 自动备份的先传，红。
    @Test
    fun `picked photos go before automatic backup`() = runTest {
        val rig = Rig(this)
        rig.order(rig.photo(1, generation = 1), OrderState.PENDING)
        rig.picked.addBatch(listOf(pick("content://picker/1")))
        rig.trigger(TriggerReason.PICKED_ADDED)

        assertEquals(2, rig.delivery.requests.size)
        assertEquals(FLOW_SOURCE_PICKED, rig.delivery.requests[0].source)
        assertEquals(FLOW_SOURCE_AUTO, rig.delivery.requests[1].source)
        rig.close()
    }

    // 电脑上已有同内容：桌面没收字节就完成 → 记「已有」。反证：不看 bytesSent → 记成 DELIVERED，红。
    @Test
    fun `content the desktop already has is recorded as already there`() = runTest {
        val rig = Rig(this)
        rig.delivery.alreadyOnDesktop += "hash:content://picker/1"
        rig.picked.addBatch(listOf(pick("content://picker/1"), pick("content://picker/2")))
        rig.trigger(TriggerReason.PICKED_ADDED)

        val s = rig.picked.latestBatch()!!
        assertEquals(1, s.delivered)
        assertEquals(1, s.alreadyThere)
        rig.close()
    }

    // 原图读不到：标「没传成」，不拖住后面的，也不记进 order。反证：SourceMissing 当成 Exit → 后面那张没传，红。
    @Test
    fun `an unreadable picked photo is reported as failed and the rest still go`() = runTest {
        val rig = Rig(this)
        rig.importer.pickedUnreadable += "content://picker/1"
        rig.picked.addBatch(listOf(pick("content://picker/1"), pick("content://picker/2")))
        rig.trigger(TriggerReason.PICKED_ADDED)

        val s = rig.picked.latestBatch()!!
        assertEquals(1, s.failed)
        assertEquals(1, s.delivered)
        assertEquals(0, s.open)
        rig.close()
    }

    // 自动备份没开也能传（用户在场）；没配对不传。反证：PICKED_ADDED 不带 userPresent → DISABLED 挡住，红。
    @Test
    fun `picked upload works with automatic backup off`() = runTest {
        val rig = Rig(this)
        rig.conditions = Conditions(autoBackupEnabled = false)
        rig.picked.addBatch(listOf(pick("content://picker/1")))
        rig.trigger(TriggerReason.PICKED_ADDED)

        assertEquals(1, rig.picked.latestBatch()!!.delivered)
        rig.close()
    }

    // 路径失败（桌面不可达）：留在传输中，退出循环，不记失败，下次续传。
    @Test
    fun `an unreachable desktop leaves the picked photo resumable`() = runTest {
        val rig = Rig(this)
        rig.delivery.script += { DeliveryOutcome.PathFailure("unreachable") }
        rig.picked.addBatch(listOf(pick("content://picker/1")))
        rig.trigger(TriggerReason.PICKED_ADDED)

        val s = rig.picked.latestBatch()!!
        assertEquals(1, s.open)
        assertEquals(0, s.failed)
        assertNull(rig.pickedSettled.firstOrNull())
        rig.close()
    }
}
