// #902：本轮自报计数（flow.round.finished 的 payload）只数真正落了库的逐张事实。
//
// 逐张事实与结局同一次写入（store.transition(..., audit = …)）；这一行已被别处结掉时转换返回 false，
// 审计不落库——这一条就不能计进本轮自报计数，否则手机自报值与桌面按证据重算的数对不上。
// 反证：把计数挪回 audit() 构造时（不管落没落库都计）→ 本用例红（confirmed / failed 各多一条）。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

class C902RoundCountPersistedTest {

    @Test
    fun `an item fact that was not persisted is not counted in the round terminal fact`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        rig.photo(3, generation = 3)
        // 第 1、2 张传输途中被别处结掉（例如对账判定源已删）：之后的确认 / 失败转换都返回 false。
        rig.delivery.onStart = { r ->
            if (r.details.snapshot.mediaId != 3L) {
                rig.store.transition(r.orderId, setOf(OrderState.TRANSFERRING), OrderState.SKIPPED_SOURCE_MISSING)
            }
        }
        // 第 1 张桌面回「已确认」（默认），第 2 张单张失败（含立即重试那一次）。
        rig.delivery.script += { FakeDelivery.confirmed(it) }
        rig.delivery.script += { DeliveryOutcome.ItemFailure("boom") }
        rig.delivery.script += { DeliveryOutcome.ItemFailure("boom") }
        rig.trigger()

        assertEquals("测试前提：三张都送过", listOf(1L, 2L, 2L, 3L), rig.delivery.deliveredMediaIds)
        val audits = rig.store.pendingAudit(1_000)
        val persisted = audits.count { it.kind == AuditKinds.ITEM_CONFIRMED }
        assertEquals("测试前提：只有第 3 张的确认落了库", 1, persisted)
        assertEquals("测试前提：第 2 张的失败没落库", 0, audits.count { it.kind == AuditKinds.ITEM_ATTENTION })

        val finished = audits.single { it.kind == AuditKinds.ROUND_FINISHED }
        assertEquals("自报计数 == 已落库的逐张证据", mapOf("confirmed" to "1"), finished.payload)
        rig.close()
    }
}
