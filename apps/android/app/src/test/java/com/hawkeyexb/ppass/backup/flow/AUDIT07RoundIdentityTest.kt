// AUDIT-07 (#499): 「一轮」在审计里的身份——round_id 从哪来、什么时候生成、挂到哪去。
//
// 契约（卡面）：一轮 = 一次持有 FGS 的传输段。FGS 到手（真的开始跑）时生成 round_id 并**先落库**；
// 这一轮发出的每条逐张事实都带上它；轮结束时补发 `flow.round.finished` 并清掉未闭合标记——
// 逐张证据因此能挂到同一次 operation 上，桌面活动页才有「已备份 N 张」这一行。
//
// 反证：audit() 不取 store.openRoundId()（退回写死 null）→ 逐张事实没有 round 可挂，本文件第一条
// 用例的每个断言都红；轮结束不补终态 → 终态断言红；关轮不清标记 → 「进程被杀」那条用例红。
package com.hawkeyexb.ppass.backup.flow

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AUDIT07RoundIdentityTest {

    private val itemKinds = setOf(AuditKinds.ITEM_CONFIRMED, AuditKinds.ITEM_SOURCE_MISSING, AuditKinds.ITEM_ATTENTION)

    @Test
    fun `every item fact and the round terminal fact carry the same persisted round id`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 1)
        rig.trigger()

        val audits = rig.store.pendingAudit(1_000)
        val items = audits.filter { it.kind in itemKinds }
        assertEquals("两张照片各一条逐张事实", 2, items.size)
        val roundId = items.first().roundId
        assertNotNull("逐张事实必须带上这一轮的 id（否则桌面的 audit_item_evidence.operation_id 是 NULL）", roundId)
        assertTrue("同一轮里的逐张事实是同一次 operation", items.all { it.roundId == roundId })

        val finished = audits.single { it.kind == AuditKinds.ROUND_FINISHED }
        assertEquals("终态挂在同一轮上（operation_id == round_id）", roundId, finished.roundId)
        assertEquals("终态的计数按桌面证据表的 outcome 名报", mapOf("confirmed" to "2"), finished.payload)
        assertEquals("终态必须是这一轮的最后一条：桌面按已落库证据重算，先有证据才有终态", finished.eventId, audits.last().eventId)
        assertNull("轮结束 = 未闭合标记清掉了", rig.store.openRoundId())
        rig.close()
    }

    @Test
    fun `a round that produced no item fact emits no terminal fact`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        // 路径失败：这一轮刚开跑就断网——那张照片还挂着「可续传」，本轮没有任何逐张事实。
        rig.delivery.script += { DeliveryOutcome.PathFailure("net_down") }
        rig.trigger()

        assertEquals("这一轮确实申请到 FGS、真的开跑了（不是压根没开轮）", 1, rig.foreground.acquires)
        assertTrue(
            "没有对象、没有证据就不发终态——不造「已备份 0 张」的空操作",
            rig.store.pendingAudit(100).none { it.kind == AuditKinds.ROUND_FINISHED },
        )
        assertNull("标记照样清掉，不留给下一轮", rig.store.openRoundId())
        rig.close()
    }

    @Test
    fun `a round left open by a killed process is closed at the next process start`() = runTest {
        // 上一次进程死在传输中途：未闭合标记还在库里（Rig 在引擎 start() 之前就摆好了它）。
        val rig = Rig(this, openRound = "round-killed")
        rig.settle()

        val finished = rig.store.pendingAudit(100).single { it.kind == AuditKinds.ROUND_FINISHED }
        assertEquals("替死去的那一轮补上终态", "round-killed", finished.roundId)
        assertTrue(
            "手机自报的计数随那个进程一起消失——终态不带计数，桌面按已落库的逐张证据自己重算",
            finished.payload.isEmpty(),
        )
        assertNull("补完终态就清标记", rig.store.openRoundId())
        rig.close()
    }

    @Test
    fun `a pause decision carries the round it interrupted`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.hold = true // 传输挂住 ⇒ 这一轮还开着
        rig.trigger()
        val roundId = rig.store.openRoundId()
        assertNotNull("传输中 = 有一轮开着", roundId)

        rig.engine.pause().also { rig.settle() }.await()

        val audits = rig.store.pendingAudit(100)
        val pause = audits.single { it.kind == AuditKinds.ROUND_CONTROLLED }
        assertEquals("「暂停」这条决策挂在它打断的那一轮上", roundId, pause.roundId)
        assertNull("被暂停打断、一张也没发出去的一轮不发终态", audits.singleOrNull { it.kind == AuditKinds.ROUND_FINISHED })
        rig.close()
    }
}
