// #522（MOB-119）：配对被撤销后，照片 tab 的订阅每轮都先打 `subscribe: connected`，几毫秒后才
// `ended (IrohException: null)`——daemon 拒绝时第一帧就是 `{"ok":false,"error":{"code":"NOT_AUTHORIZED"}}`，
// 旧的读循环「读到第一帧就算连上」。这里钉住：
//  ① 读循环（readSubscriptionFrames，DaemonClient 用的就是它）：被拒不调 onConnected，抛 SubscribeRejectedException；
//     确认帧才调 onConnected。反证：把 onConnected 挪回分类之前 → 第一条用例红。
//  ② holder：撤销场景下首条日志就是「被拒 + 原因」，全程没有 connected。
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.proto.TimelinePage
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.SubscribeRejectedException
import com.hawkeyexb.ppass.transport.readSubscriptionFrames
import com.hawkeyexb.ppass.transport.subscribeRejectionOf
import java.io.File
import java.io.IOException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class C522SubscribeRejectedTest {

    // daemon router.rs：鉴权拒绝 = Resp::err(NOT_AUTHORIZED, msg_key)；允许 = Resp::ok({"subscribed":true}) 再推一次当前态。
    private val deny = Json.parseToJsonElement("""{"id":"r1","ok":false,"error":{"code":"NOT_AUTHORIZED","msg_key":"err.not_authorized"}}""")
    private val ack = Json.parseToJsonElement("""{"id":"r1","ok":true,"result":{"subscribed":true}}""")
    private val invalidated = Json.parseToJsonElement("""{"event":"timeline.invalidated","data":{}}""")

    /** 按顺序吐帧，吐完就像对端关流一样抛（生产里是 IrohException）。 */
    private fun frames(vararg f: JsonElement): suspend () -> JsonElement {
        val queue = ArrayDeque(f.toList())
        return { queue.removeFirstOrNull() ?: throw IOException("stream closed") }
    }

    @Test
    fun `a rejected subscription never reports connected and says it was rejected`() = runTest {
        var connected = 0
        try {
            readSubscriptionFrames(frames(deny), onConnected = { connected++ }, onFlowEvent = { _, _ -> }, onInvalidated = {})
        } catch (rejected: SubscribeRejectedException) {
            assertEquals("NOT_AUTHORIZED", rejected.code)
            assertEquals("err.not_authorized", rejected.msgKey)
            assertEquals("被拒不得算连上", 0, connected)
            return@runTest
        }
        fail("被拒必须抛 SubscribeRejectedException，而不是等下一帧读失败")
    }

    @Test
    fun `an acknowledged subscription reports connected once and then delivers events`() = runTest {
        var connected = 0
        var invalidations = 0
        try {
            readSubscriptionFrames(frames(ack, invalidated, invalidated), onConnected = { connected++ }, onFlowEvent = { _, _ -> }, onInvalidated = { invalidations++ })
        } catch (_: IOException) {
            // 流结束
        }
        assertEquals(1, connected)
        assertEquals(2, invalidations)
    }

    @Test
    fun `only an explicit ok false first frame is a rejection`() {
        assertNotNull(subscribeRejectionOf(deny))
        assertNull(subscribeRejectionOf(ack))
        assertNull(subscribeRejectionOf(invalidated))
        assertNull(subscribeRejectionOf(Json.parseToJsonElement("""{"ok":"false"}""")))
    }

    // ---------------------------------------------------------------- holder

    private val pairing = Pairing(daemonNodeId = "a".repeat(64), daemonAddrToken = "tok", storageDeviceName = "Test")

    /** 撤销后的桌面：走真实的读循环，第一帧就是拒绝。 */
    private class RevokedChannel(private val first: JsonElement) : TimelineChannel {
        var calls = 0
        override val loader: TimelineLoader? get() = null
        override suspend fun loadPage(cursor: String?): TimelinePage = throw IllegalStateException("timeline: err.not_authorized")
        override suspend fun subscribe(onConnected: suspend () -> Unit, onInvalidated: suspend () -> Unit) {
            calls++
            val queue = ArrayDeque(listOf(first))
            readSubscriptionFrames({ queue.removeFirstOrNull() ?: throw IOException("IrohException: null") }, onConnected, { _, _ -> }, onInvalidated)
        }
        override fun onRefreshed(hashes: Set<String>) {}
        override fun onAppended(hashes: Set<String>) {}
    }

    @Test
    fun `after a revoke the first subscribe log line says rejected and connected never appears`() = runTest {
        val logs = mutableListOf<String>()
        val ch = RevokedChannel(deny)
        val h = TimelineSubscriptionHolder(scope = backgroundScope, currentPairing = { pairing }, channelFor = { ch }, log = { logs += it })
        h.start()
        advanceTimeBy(61_000)
        runCurrent()
        assertTrue(ch.calls > 1)
        assertEquals("subscribe: rejected by the desktop (NOT_AUTHORIZED: err.not_authorized)", logs.first())
        assertFalse("撤销后不得出现 connected", logs.any { it == "subscribe: connected" })
        assertFalse(h.state.subscribeConnected)
        assertEquals(ch.calls, logs.count { it.startsWith("subscribe: rejected") })
        h.stop()
    }

    // ---------------------------------------------------------------- 接线门禁（源文本，只钉「接线还在」）

    @Test
    fun `the real client reads the stream through the classifying loop`() {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) dir = dir.parentFile ?: error("apps/android not found")
        val src = File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/transport/DaemonClient.kt").readText()
            .lines().filterNot { val t = it.trimStart(); t.startsWith("//") || t.startsWith("*") || t.startsWith("/*") }
            .joinToString("\n")
        val body = src.substringAfter("suspend fun subscribeTimeline(").substringBefore("suspend fun unpair(")
        assertTrue(body.contains("readSubscriptionFrames("))
        assertTrue(body.contains("onConnected = onConnected,"))
        assertFalse("读循环之外不得再自己调 onConnected", body.contains("onConnected()"))
    }
}
