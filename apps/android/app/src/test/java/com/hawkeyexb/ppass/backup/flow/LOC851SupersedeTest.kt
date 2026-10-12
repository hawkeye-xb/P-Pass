// #851：拿到位置权限、桌面支持时，把当年抹过地点的已备份照片原地换成原图——不重传成第二张、不漏、可重放。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.proto.FLOW_SUPERSEDE_CAPABILITY
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LOC851SupersedeTest {
    private val capable = ProbeResult.Reachable("e1", capabilities = setOf(FLOW_SUPERSEDE_CAPABILITY))
    private val original = "blake3:original-with-gps"

    /** 一张照片按 #843 之前的样子备份完（地点被抹），然后用户给了位置权限。 */
    private fun TestScope.backedUpRedacted(): Pair<Rig, String> {
        val rig = Rig(this)
        val p = rig.photo(1, generation = 1)
        rig.importer.locationRedacted = true
        rig.store.markScanDirty()
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals(OrderState.CONFIRMED, rig.state(1))
        assertTrue(rig.store.currentForMedia(1)!!.locationRedacted)
        rig.importer.locationRedacted = false
        rig.importer.hashOverride[p.mediaId] = original
        rig.locationReadable = true
        rig.probeResult = capable
        return rig to p.hash
    }

    // 主路径：桌面原地替换 → 当前行换成原图的 hash；从头到尾没有一次普通传输（原图不会成为第二张）。
    // 反证：把补地点做成普通传输（建传输中的行再交付）→ delivery.requests 多一条，红。
    @Test
    fun `a redacted backup is superseded in place once permission and desktop allow it`() = runTest {
        val (rig, old) = backedUpRedacted()
        val delivered = rig.delivery.requests.size

        rig.trigger(TriggerReason.APP_FOREGROUND)

        assertEquals(listOf(Triple(old, original, "ticket-1")), rig.supersedeCalls)
        val current = rig.store.currentForMedia(1)!!
        assertEquals(OrderState.CONFIRMED, current.state)
        assertEquals(original, current.contentHash)
        assertFalse(current.locationRedacted)
        assertEquals(delivered, rig.delivery.requests.size)
        assertTrue(original in rig.importer.released)
        assertEquals(0, rig.pending())

        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals("换完就不再是待办", 1, rig.supersedeCalls.size)
        rig.close()
    }

    // 进程在补地点途中被杀：这一刻库里没有任何传输中的行，所以重启后不会被当成普通传输把原图交付一遍。
    @Test
    fun `no transferring row exists while a supersede is in flight`() = runTest {
        val (rig, _) = backedUpRedacted()
        var transferringDuringCall = -1
        rig.supersedeReply = { _, _ ->
            transferringDuringCall = rig.store.currentInStates(setOf(OrderState.TRANSFERRING, OrderState.PENDING)).size
            SupersedeOutcome.Replaced
        }
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals(0, transferringDuringCall)
        rig.close()
    }

    // 旧桌面（没宣告 flow.supersede.v1）：不重读、不调用，也不为它申请前台服务。
    @Test
    fun `an older desktop is never asked and costs no foreground service`() = runTest {
        val (rig, _) = backedUpRedacted()
        rig.probeResult = ProbeResult.Reachable("e1")
        val imports = rig.importer.imported.size
        val acquires = rig.foreground.acquires

        rig.trigger(TriggerReason.APP_FOREGROUND)

        assertEquals(emptyList<Triple<String, String, String>>(), rig.supersedeCalls)
        assertEquals(imports, rig.importer.imported.size)
        assertEquals(acquires, rig.foreground.acquires)
        assertTrue(rig.store.currentForMedia(1)!!.locationRedacted)
        rig.close()
    }

    @Test
    fun `without the location grant nothing is re-read`() = runTest {
        val (rig, _) = backedUpRedacted()
        rig.locationReadable = false
        val imports = rig.importer.imported.size
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals(emptyList<Triple<String, String, String>>(), rig.supersedeCalls)
        assertEquals(imports, rig.importer.imported.size)
        rig.close()
    }

    // 照片本来就没有地点：重读的字节与传过的一样 → 只记结论，不打扰桌面；之后不再重读。
    @Test
    fun `a photo without location only clears the flag`() = runTest {
        val (rig, _) = backedUpRedacted()
        rig.importer.hashOverride.clear()
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals(emptyList<Triple<String, String, String>>(), rig.supersedeCalls)
        assertFalse(rig.store.currentForMedia(1)!!.locationRedacted)
        val imports = rig.importer.imported.size
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals(imports, rig.importer.imported.size)
        rig.close()
    }

    // 桌面拒绝（例如不只是抹地点）：记结论，不再反复尝试；桌面上那份不动，手机也不改账。
    @Test
    fun `a refusal is final and the old row stays current`() = runTest {
        val (rig, old) = backedUpRedacted()
        rig.supersedeReply = { _, _ -> SupersedeOutcome.Refused("not_a_redaction") }
        rig.trigger(TriggerReason.APP_FOREGROUND)
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals(1, rig.supersedeCalls.size)
        assertEquals(old, rig.store.currentForMedia(1)!!.contentHash)
        rig.close()
    }

    // 暂时的失败（桌面不可达 / 拉块失败）：留着，下一轮再试；桌面对重放回成功。
    @Test
    fun `transient failures are retried on a later round`() = runTest {
        val (rig, _) = backedUpRedacted()
        var calls = 0
        rig.supersedeReply = { _, _ ->
            calls++
            when (calls) {
                1 -> throw java.io.IOException("desktop went away")
                2 -> SupersedeOutcome.Refused("fetch_failed")
                else -> SupersedeOutcome.Replaced
            }
        }
        repeat(3) { rig.trigger(TriggerReason.APP_FOREGROUND) }
        assertEquals(3, rig.supersedeCalls.size)
        assertEquals(original, rig.store.currentForMedia(1)!!.contentHash)
        rig.close()
    }

    // 补地点排在最后：有新照片要传时先传完，再补地点。
    @Test
    fun `new photos are delivered before any supersede`() = runTest {
        val (rig, _) = backedUpRedacted()
        val events = mutableListOf<String>()
        rig.delivery.onStart = { events += "deliver ${it.orderId}" }
        rig.supersedeReply = { _, _ -> events += "supersede"; SupersedeOutcome.Replaced }
        rig.photo(2, generation = 2)
        rig.store.markScanDirty()
        rig.trigger(TriggerReason.APP_FOREGROUND)
        assertEquals("supersede", events.last())
        assertTrue(events.first().startsWith("deliver"))
        rig.close()
    }
}
