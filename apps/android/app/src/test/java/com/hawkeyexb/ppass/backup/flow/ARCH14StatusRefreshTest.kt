// #418 回归：FGS 通知 / 首页英雄区的刷新闸门——值变了才刷新，字节进度每秒最多一次，换张 / 换阶段立即刷新。
// 反证写在每个测试上方。
package com.hawkeyexb.ppass.backup.flow

import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ARCH14StatusRefreshTest {
    // 文件名、总字节数故意相同：换张只能靠 orderId 认出来（两张同名同大小的照片是常见情况）。
    private fun running(orderId: Long, bytes: Long) =
        LoopStatus(LoopPhase.RUNNING, CurrentItem(orderId, "IMG.jpg", bytes, 1_000L))

    // ---------------------------------------------------------------- 纯判定

    // 字节数不变 → 不刷新；而且是在节流窗口**已经过去**之后再送同一个值——这时节流不会替它挡，只有「值变了」这条判断能挡。
    // 反证：删掉 StatusRefreshGate.offer 里的 `if (next == last) return Decision.Skip` → 同值被当成「只有字节变了」、
    // 窗口已过 → Now，红。
    @Test
    fun `unchanged bytes never refresh, even after the throttle window has passed`() {
        val gate = StatusRefreshGate()
        val s = running(1, 400)
        assertEquals(StatusRefreshGate.Decision.Now, gate.offer(s, nowMs = 0))
        gate.markPublished(s, nowMs = 0)

        assertEquals(StatusRefreshGate.Decision.Skip, gate.offer(s, nowMs = 5_000))
        assertEquals(StatusRefreshGate.Decision.Skip, gate.offer(s.copy(), nowMs = 60_000))
    }

    // 字节数变了 → 刷新，但每秒最多一次：窗口内给出剩余等待时间，窗口外立即。
    // 反证：offer 里去掉节流（字节变化一律 Now）→ 第 300ms 那次是 Now 不是 Later(700)，红。
    @Test
    fun `changed bytes refresh at most once per second`() {
        val gate = StatusRefreshGate()
        gate.markPublished(running(1, 100), nowMs = 0)

        assertEquals(StatusRefreshGate.Decision.Later(700), gate.offer(running(1, 200), nowMs = 300))
        assertEquals(StatusRefreshGate.Decision.Now, gate.offer(running(1, 200), nowMs = STATUS_REFRESH_MIN_INTERVAL_MS))
    }

    // 换张 / 换阶段 / 换等待原因 → 立即刷新，不受节流限制。
    // 反证：isBytesOnlyChange 不比 orderId（`ca.copy(bytesSent = 0, orderId = 0) == …`）→ 换张被当成字节变化，Later，红。
    @Test
    fun `switching item, phase or wait reason refreshes immediately`() {
        val gate = StatusRefreshGate()
        gate.markPublished(running(1, 900), nowMs = 0)

        assertEquals(StatusRefreshGate.Decision.Now, gate.offer(running(2, 0), nowMs = 10))
        assertEquals(StatusRefreshGate.Decision.Now, gate.offer(LoopStatus(LoopPhase.IDLE), nowMs = 10))
        assertEquals(
            StatusRefreshGate.Decision.Now,
            gate.offer(running(1, 900).copy(waitReason = WaitReason.WIFI), nowMs = 10),
        )
    }

    // ---------------------------------------------------------------- 真实引擎端到端

    // 一张照片传输期间进度回调很密（100ms 一次），通知只按「每秒最多一次 + 窗口末补发最新值」刷新；
    // 字节数停住之后再报同样的值不刷新；这一张结束、下一张开始时立即刷新，不等窗口。
    // 首页读的 engine.display 与通知收到的是同一串值。
    // 反证 1：删掉 offer 的 Skip 判断 → 3.2s 那次重复的 9 字节也发出去，bytes 序列多一个 9，红。
    // 反证 2：删掉节流（字节变化一律 Now）→ 3 / 6 / 9 各发一次，序列变成 [0,3,6,9,11]，红。
    @Test
    fun `engine refreshes the notification only when the value changed, throttled, and immediately on the next item`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.photo(2, generation = 2)
        val displayed = mutableListOf<LoopStatus>()
        rig.delivery.progress = { request, report ->
            if (request.details.snapshot.mediaId == 1L) {
                report(3); delay(100)
                report(6); delay(100)
                report(9)
                delay(3_000)
                report(9) // 字节没动：不刷新
                displayed += rig.engine.display.value
            }
        }
        rig.trigger()

        val firstId = rig.store.currentForMedia(1)!!.id
        val secondId = rig.store.currentForMedia(2)!!.id
        val size1 = rig.delivery.requests.first().details.sizeBytes
        val first = rig.foreground.updates.withIndex().filter { it.value.current?.orderId == firstId }
        assertEquals(listOf(0L, 9L, size1), first.map { it.value.current!!.bytesSent })

        val t = rig.foreground.updateTimes
        val start = t[first[0].index]
        assertEquals("trailing flush lands at the end of the 1s window", start + STATUS_REFRESH_MIN_INTERVAL_MS, t[first[1].index])
        // 最后一次字节进度与下一张的开始在同一时刻：换张不受节流。
        val nextStart = rig.foreground.updates.indexOfFirst { it.current?.orderId == secondId }
        assertTrue(nextStart > first.last().index)
        assertEquals(t[first.last().index], t[nextStart])

        // 首页同一个出口：窗口末补发之后看到的就是通知里的那个值。
        assertEquals(9L, displayed.single().current!!.bytesSent)
        rig.close()
    }
}
