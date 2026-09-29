// NET-29 (#467)：手机供数端点上不了线（provider_offline）时，App 开在前台就要一直接着试，不能试两次就停。
// 端点本身的自愈（没上线就换一个新端点）在 crates/transport/src/android_blobs.rs，由 media_import.rs 的
// NET-29 测试锁住；这里锁的是它依赖的那一半：provider_offline 是路径失败（不计次数、这张保持传输中），
// 之后每一拍前台心跳都叫醒循环再试一次，直到供数成功。
// 卡面现场（test.2）试两次就停，是因为 test.2 不含 #439 的心跳叫醒；main 已含，这里把它钉在 provider_offline 上。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NET29ProviderOfflineRetryTest {

    private val offline = "Android provider endpoint did not become online before serving " +
        "(endpoint=10cd961c21 homeRelay=[none] directAddrs=1; replaced by endpoint=5be0c0ffee generation=1)"

    // 连续三次 provider_offline（每次都带上 Rust 侧新加的诊断与「已换端点」说明），之后供数恢复：
    // 每次失败都不计次数、不改结局；每一拍心跳都再试同一张；第四次成功。
    // 反证：onDesktopReachable 不调 onTrigger → 第一次失败后再无尝试，requests 停在 1，红。
    @Test
    fun `repeated provider_offline keeps retrying the same photo on every foreground heartbeat until it serves`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        repeat(3) { rig.delivery.script += { classifyProviderFailure(IllegalStateException(offline)) } }

        rig.trigger()
        for (attempt in 1..3) {
            assertEquals("attempt $attempt", attempt, rig.delivery.requests.size)
            assertEquals(OrderState.TRANSFERRING, rig.state(1))
            assertEquals(WaitReason.DESKTOP_UNREACHABLE, rig.control.wait)
            assertEquals("a path failure is never counted", 0, rig.store.currentForMedia(1)!!.attempts)
            rig.engine.onDesktopReachable()
            rig.settle()
        }

        assertEquals(4, rig.delivery.requests.size)
        assertEquals(setOf(rig.delivery.requests[0].orderId), rig.delivery.requests.map { it.orderId }.toSet())
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertNull(rig.control.wait)
        rig.close()
    }

    // Rust 侧给错误加了诊断与「已换端点」说明之后，分类仍然是 provider_offline（路径失败），不会掉成单张失败开始计次数。
    // 反证：把 classifyProviderFailure 的 "did not become online" 分支改成要求整句相等 → ItemFailure，红。
    @Test
    fun `the diagnosed offline error is still classified as provider_offline`() {
        assertEquals(DeliveryOutcome.PathFailure("provider_offline"), classifyProviderFailure(IllegalStateException(offline)))
        assertEquals(
            DeliveryOutcome.PathFailure("provider_offline"),
            classifyProviderFailure(
                IllegalStateException(
                    "stream I/O: Android provider endpoint did not become online before ticket registration " +
                        "(endpoint=10cd961c21 homeRelay=[https://aps1-1.relay.n0.iroh.link./ connected=false " +
                        "lastError=connection refused] directAddrs=2; rebind failed: bind error)",
                ),
            ),
        )
    }
}
