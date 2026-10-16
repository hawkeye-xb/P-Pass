// #900：drain 收尾期间到达的触发不能丢。
//
// 窗口：drain 的 while 退出后，收尾还要在 io 上重算一次待办（refreshPending → countTodo）。这段时间 cycleJob
// 仍是 active，写者上排着的触发走「coalesced into the running cycle」只把原因塞进 pending 就返回——收尾之后
// 要是不再看一眼 pending，这次触发就丢了，只能等下一次外部触发 / 5h 兜底。
//
// 测法：io 用独立调度器（与生产一样，切到 io 会让出写者），在收尾那次重算里新拍一张并触发。
// 反证：去掉 drain 收尾后的「再看一眼 pending」→ 第一条用例红（第二张没有传出）。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class C900DrainTailTriggerTest {

    /** 在收尾那次重算待办（这一轮已传过第一张、状态已回到空闲）里执行 [action]，只执行一次。返回是否执行过。 */
    private fun Rig.duringTailRecount(action: Rig.() -> Unit): () -> Boolean {
        var delivered = false
        var fired = false
        delivery.onStart = { if (it.details.snapshot.mediaId == 1L) delivered = true }
        media.onReadChanged = {
            if (delivered && !fired && engine.status.value.phase == LoopPhase.IDLE) {
                fired = true
                action()
            }
        }
        return { fired }
    }

    @Test
    fun `a trigger that lands while the cycle is finishing is still served`() = runTest {
        val rig = Rig(this, separateIo = true)
        rig.photo(1, generation = 1)
        val fired = rig.duringTailRecount {
            photo(2, generation = 2)
            engine.trigger(TriggerReason.MEDIA_CHANGE)
        }
        rig.trigger()

        assertTrue("测试前提：触发确实落在收尾那次重算里", fired())
        assertTrue(
            "测试前提：它被合并进了还没结束的这一次 drain（窗口真的打开了）",
            rig.logs.any { it.contains("coalesced into the running cycle") },
        )
        assertEquals("收尾期间新拍的那张不能丢：同一次 drain 里接着传", listOf(1L, 2L), rig.delivery.deliveredMediaIds)
        assertEquals(OrderState.CONFIRMED, rig.state(2))
        assertEquals("跑完没有剩下的待办", 0, rig.pending())
        rig.close()
    }

    @Test
    fun `a pause that lands while the cycle is finishing is not undone by the second look`() = runTest {
        val rig = Rig(this, separateIo = true)
        rig.photo(1, generation = 1)
        val fired = rig.duringTailRecount {
            photo(2, generation = 2)
            engine.trigger(TriggerReason.MEDIA_CHANGE)
            engine.pause()
        }
        rig.trigger()

        assertTrue("测试前提：触发与暂停确实落在收尾那次重算里", fired())
        assertEquals("暂停之后不再补跑：第二张不传", listOf(1L), rig.delivery.deliveredMediaIds)
        assertEquals("暂停后只申请过一次 FGS（没有为补跑再开一轮）", 1, rig.foreground.acquires)
        rig.close()
    }
}
