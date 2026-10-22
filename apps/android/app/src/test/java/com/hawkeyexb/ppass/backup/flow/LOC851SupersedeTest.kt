// #851：拿到位置权限、桌面支持时，把当年抹过地点的已备份照片原地换成原图——不重传成第二张、不漏、可重放。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.LocationVerdict
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.proto.FLOW_SUPERSEDE_CAPABILITY
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LOC851SupersedeTest {
    private val capable = ProbeResult.Reachable(capabilities = setOf(FLOW_SUPERSEDE_CAPABILITY))
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
        rig.probeResult = ProbeResult.Reachable()
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

    /**
     * #1005：这一轮补不成、以后也补不成 → 落 [verdict]、退出待办；之后的触发（后台截图 / 换网这类）不再为它探测桌面。
     * 反证：processUpgrade 在这些情况下只 return Next、不记结论 → 这一行一直是待办，每次触发 probes 都 +1，红。
     */
    private fun Rig.upgradeEndsWith(verdict: LocationVerdict) {
        trigger(TriggerReason.MEDIA_CHANGE)
        val row = store.currentForMedia(1)!!
        assertEquals(verdict, row.locationVerdict)
        assertTrue("桌面手里仍是抹过的副本", row.locationRedacted)
        val probesAfter = probes
        repeat(3) { trigger(TriggerReason.MEDIA_CHANGE) }
        assertEquals("结论落下之后不再为它探测桌面", probesAfter, probes)
        assertEquals(emptyList<Triple<String, String, String>>(), supersedeCalls)
    }

    // 部分相册权限下照片看不见（或已删）：MediaStore 查不到。完整权限下对账会先打 source_missing，这里关掉它，只靠补地点自己落结论。
    @Test
    fun `a photo that can no longer be found ends the upgrade`() = runTest {
        val (rig, _) = backedUpRedacted()
        rig.fullMediaAccess = false
        rig.media.remove(1)
        rig.upgradeEndsWith(LocationVerdict.SOURCE_GONE)
        rig.close()
    }

    // MediaStore 还列着、打开时文件已不在。
    @Test
    fun `a photo whose file is gone at open ends the upgrade`() = runTest {
        val (rig, _) = backedUpRedacted()
        rig.importer.unreadable += 1L
        rig.upgradeEndsWith(LocationVerdict.SOURCE_GONE)
        rig.close()
    }

    // 照片被编辑成了新版本：这一行描述的字节已不存在（新版本照常另传）。
    @Test
    fun `an edited photo ends the upgrade of its old version`() = runTest {
        val (rig, _) = backedUpRedacted()
        val p = rig.media.photos.single { it.mediaId == 1L }
        rig.media.put(p.copy(modified = p.modified + 1))
        rig.upgradeEndsWith(LocationVerdict.VERSION_CHANGED)
        rig.close()
    }

    // 导入当场重试后仍抛：读不出来。
    @Test
    fun `a photo that cannot be read ends the upgrade`() = runTest {
        val (rig, _) = backedUpRedacted()
        repeat(2) { rig.importer.failures += java.io.IOException("unreadable") }
        rig.upgradeEndsWith(LocationVerdict.UNREADABLE)
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
