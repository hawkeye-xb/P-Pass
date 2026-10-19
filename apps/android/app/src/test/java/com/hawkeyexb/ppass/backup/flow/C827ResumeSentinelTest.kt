// #827：备份在传的半路进程死了（崩溃 / 被系统杀），没人把它拉起来，要等下一次触发（最长 5h 周期）。
//
// 不变式（#409 / #652 补全）：队列有没传完的 ⇒ 系统里至少登记着一个会触发的唤醒——「正在传」不再是例外。
// 在传时的唤醒是续传哨兵：一轮开了（FGS 到手）就登记，收尾时（进程还活着）撤掉；进程死在半路时撤不掉，到点把进程拉起来。
// JVM 里模拟不了进程死亡本身，所以分两半验：死的那一刻系统里留下了什么（哨兵在、没被撤），和拉起来之后怎么续。
//
// 反证（本机逐条实测）：
//  - 去掉 runCycle 里的 armResumeSentinel(roundId) → 第 1、2、4、6 条红（半路没有哨兵 / 没计数 / 在跑时到点不再往后排）。
//  - 去掉 finally 里的 disarmResumeSentinel() → 第 2、5 条红（收尾不撤，每轮都会白拉一次）。
//  - 去掉 strikes 上限 → 第 5 条红（必崩的缺陷每 10 分钟重启一次、没有尽头）。
//  - 去掉 onTrigger 里哨兵的合并分支 → 第 4 条红（这一轮结束后白跑一轮）。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class C827ResumeSentinelTest {

    @Test
    fun `a round in flight leaves a registered sentinel behind if the process dies there`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.hold = true
        rig.trigger()

        // 此刻进程死掉：系统里留下的就是这些。
        assertEquals("这一轮真的开了（FGS 到手）", 1, rig.foreground.acquires)
        assertEquals("在传时登记了一个哨兵", listOf(RESUME_SENTINEL_DELAY_MS), rig.scheduler.resumeSentinels)
        assertEquals("还没撤（撤只发生在收尾）", 0, rig.scheduler.resumeSentinelCancels)
        assertEquals("「这一轮还没处理完一张」落盘了", 1, rig.control.strikes)
        rig.delivery.release()
        rig.settle()
        rig.close()
    }

    @Test
    fun `every way a round ends with the process alive cancels the sentinel`() = runTest {
        val ends: List<Pair<String, (Rig) -> Unit>> = listOf(
            "正常传完" to { r -> r.delivery.release() },
            "用户暂停" to { r -> r.engine.pause() },
            "断网" to { r -> r.engine.onNetworkLost() },
            "FGS 被系统收走" to { r -> r.engine.onForegroundLost() },
            "一轮跑到一半抛异常" to { r -> r.conditionsHook = { throw IllegalStateException("disk full") }; r.delivery.release() },
        )
        for ((why, end) in ends) {
            val rig = Rig(this)
            rig.photo(1, generation = 1)
            rig.photo(2, generation = 1)
            rig.delivery.hold = true
            rig.trigger()
            assertEquals("$why：开跑时登记了哨兵", 1, rig.scheduler.resumeSentinels.size)

            end(rig)
            rig.settle()
            assertEquals("$why：收尾撤掉了哨兵", 1, rig.scheduler.resumeSentinelCancels)
            assertEquals("$why：计数清零", 0, rig.control.strikes)
            rig.close()
        }
    }

    @Test
    fun `no sentinel when the round never starts`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.foreground.grant = false
        rig.trigger()
        assertEquals("FGS 被拒：没开轮，不登记哨兵（等待中自有探测梯）", emptyList<Long>(), rig.scheduler.resumeSentinels)
        assertEquals(0, rig.control.strikes)

        val idle = Rig(this)
        idle.trigger()
        assertEquals("没东西要传：不开轮，不登记", emptyList<Long>(), idle.scheduler.resumeSentinels)
        rig.close()
        idle.close()
    }

    @Test
    fun `a sentinel firing during a long round only pushes itself back`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.delivery.hold = true
        rig.trigger()

        rig.trigger(TriggerReason.RESUME_SENTINEL)
        assertEquals("到点而这一轮还在传：再往后排一次", 2, rig.scheduler.resumeSentinels.size)
        assertEquals("进程活着，不算一次「死在半路」", 1, rig.control.strikes)

        rig.delivery.release()
        rig.settle()
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertEquals("合并进这一轮，不在它结束后白跑一轮", 1, rig.foreground.acquires)
        rig.close()
    }

    @Test
    fun `the sentinel resumes a killed round without duplicates, and stops after repeated deaths`() = runTest {
        // 上一个进程死在第 1 张的半路：那张还挂着「传输中」，那一轮没闭合，计数 = 1。被哨兵拉起来的新进程：
        val rig = Rig(this, openRound = "round-killed")
        val p1 = rig.photo(1, generation = 1)
        rig.photo(2, generation = 1)
        rig.order(p1, OrderState.TRANSFERRING)
        rig.control.strikes = 1
        rig.trigger(TriggerReason.RESUME_SENTINEL)

        assertEquals("两张都传完", listOf(OrderState.CONFIRMED, OrderState.CONFIRMED), listOf(rig.state(1), rig.state(2)))
        assertEquals("每张只传一次（零重复）", listOf(1L, 2L), rig.delivery.deliveredMediaIds.sorted())
        assertTrue("死掉的那一轮补上了终态", rig.store.pendingAudit(100).any { it.kind == AuditKinds.ROUND_FINISHED && it.roundId == "round-killed" })
        assertEquals("这一轮正常收尾：撤掉哨兵、计数清零", 1, rig.scheduler.resumeSentinelCancels)
        assertEquals(0, rig.control.strikes)
        rig.close()

        // 必崩的缺陷：已连续 MAX 轮死在半路、一张都没处理完——不再登记，交给 5h 周期与事件。
        val doomed = Rig(this)
        doomed.photo(1, generation = 1)
        doomed.control.strikes = RESUME_SENTINEL_MAX_STRIKES
        doomed.delivery.hold = true
        doomed.trigger(TriggerReason.RESUME_SENTINEL)
        assertEquals("轮照样开（这次可能就好了）", 1, doomed.foreground.acquires)
        assertEquals("但不再登记哨兵", emptyList<Long>(), doomed.scheduler.resumeSentinels)

        // 这一次处理完了一张：计数清零，下一轮重新有哨兵。
        doomed.delivery.release()
        doomed.settle()
        assertEquals(OrderState.CONFIRMED, doomed.state(1))
        assertEquals(0, doomed.control.strikes)
        doomed.close()
    }

    @Test
    fun `strikes count consecutive rounds that died before finishing a photo`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 1)
        rig.control.strikes = RESUME_SENTINEL_MAX_STRIKES - 1
        rig.delivery.hold = true
        rig.trigger()
        assertEquals("还没到上限：登记，并把这一轮记上", 1, rig.scheduler.resumeSentinels.size)
        assertEquals(RESUME_SENTINEL_MAX_STRIKES, rig.control.strikes)

        // 第 1 张处理完了（进程没死在它身上）——清零，哪怕这一轮还没完。
        rig.delivery.release()
        rig.delivery.hold = true
        rig.settle()
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertEquals(0, rig.control.strikes)
        rig.delivery.release()
        rig.settle()
        rig.close()
    }
}
