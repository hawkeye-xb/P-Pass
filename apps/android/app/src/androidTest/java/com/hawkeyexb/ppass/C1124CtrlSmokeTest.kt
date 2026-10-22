// #1124 真机冒烟：Android 控制面经共享 Rust 核心（uniffi CtrlClient），在真机上对着本机测试沙盒 daemon
// 走一遍：配对 → 请求 / 探测（call_traced 逐阶段记录）→ 订阅 → 取原图（asset.blob_ticket + fetch_blob）→
// 电脑删掉这台设备（410，订阅挂着）→ 关闭监听立刻收到 → 之后的请求被拒；从没申请过的新身份在握手时被 401 拒。
//
// 只由 tools/android-ctrl-smoke.sh 驱动（-e qr <配对串>；主机脚本预置照片、自动允许配对、在本测试打出
// `C1124 READY_FOR_REVOKE` 后经 IPC 删配对）。没给参数就跳过。用一次性随机身份，不碰 App 自己的身份与配对。
package com.hawkeyexb.ppass

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.hawkeyexb.ppass.backup.flow.FlowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.PairingId
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.proto.TimelinePage
import com.hawkeyexb.ppass.proto.TimelineQuery
import com.hawkeyexb.ppass.transport.CallTrace
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.PairOutcome
import com.hawkeyexb.ppass.transport.PeerAddrParts
import com.hawkeyexb.ppass.transport.PeerClosedException
import com.hawkeyexb.ppass.transport.pairWithQr
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import com.hawkeyexb.ppass.transport.recordDesktopClose
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class C1124CtrlSmokeTest {
    private fun say(line: String) {
        Log.i("C1124", line)
        println("C1124 $line")
    }

    @Test
    fun ctrlPlaneThroughTheSharedRustCore() {
        val qr = InstrumentationRegistry.getArguments().getString("qr")
        assumeTrue("no -e qr", !qr.isNullOrBlank())
        val cache = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val closes = CopyOnWriteArrayList<Pair<String, Long>>()
        runBlocking {
            val client = DaemonClient(bindLog = { say("bind: $it") })
            client.onPeerClosed = { node, code -> closes += node to code; say("peer closed by ${node.take(8)} code=$code") }
            client.bind(ByteArray(32).also { java.security.SecureRandom().nextBytes(it) })
            try {
                // 1. 配对（主机自动允许）。
                val outcome = pairWithQr(client, qr!!.trim(), deviceName = "C1124-smoke")
                assertTrue("pair: $outcome", outcome is PairOutcome.Joined)
                val pairing = (outcome as PairOutcome.Joined).pairing
                val desk: PeerAddrParts = parsePeerAddrToken(pairing.daemonAddrToken)
                say("paired desk=${pairing.daemonNodeId.take(8)} pairingId=${pairing.pairingId.take(8)}")

                // 2. 请求 + 探测。
                val hello = client.call(desk, Methods.HELLO, buildJsonObject {})
                assertTrue("hello: $hello", hello.ok)
                var trace: CallTrace? = null
                val traced = client.callTraced(desk, Methods.HELLO, buildJsonObject {}) { trace = it }
                assertTrue(traced.ok)
                val t = assertNotNullAndGet(trace)
                say("trace ${t.render()}")
                assertNotNull("connectMs", t.connectMs)
                assertNotNull("path", t.path)

                // 3. 取原图（主机已用 testclient 预置照片）。
                val page = client.call(
                    desk, Methods.TIMELINE_PAGE,
                    ProtoJson.encodeToJsonElement(TimelineQuery.serializer(), TimelineQuery(limit = 10)),
                )
                assertTrue("timeline: $page", page.ok)
                val items = ProtoJson.decodeFromJsonElement(TimelinePage.serializer(), page.result!!).items
                assertTrue("desktop has no photos to fetch", items.isNotEmpty())
                val asset = items.first()
                val dest = java.io.File(cache, "c1124-${asset.hash.take(16)}")
                dest.delete()
                var seen = 0L
                val got = client.downloadAsset(desk, asset.hash, dest, asset.bytes) { r, _ -> seen = r }
                assertEquals(asset.bytes, got)
                assertEquals(asset.bytes, dest.length())
                say("original ${asset.hash.take(16)} bytes=$got progress=$seen")
                dest.delete()

                // 4. 订阅挂着时电脑删掉这台设备 ⇒ 410 立刻到达关闭监听。
                val connected = CompletableDeferred<Unit>()
                val sub = async(Dispatchers.IO) {
                    runCatching {
                        client.subscribeTimeline(desk, onConnected = { connected.complete(Unit) }, onInvalidated = {})
                    }
                }
                withTimeout(15_000) { connected.await() }
                say("READY_FOR_REVOKE node=${client.nodeIdHex()}")
                val revokedAt = System.nanoTime()
                withTimeout(60_000) { while (closes.none { it.second == 410L }) delay(50) }
                val ms = (System.nanoTime() - revokedAt) / 1_000_000
                say("410 seen ${ms}ms after READY")
                assertEquals(pairing.daemonNodeId, closes.first { it.second == 410L }.first)
                val ended = withTimeout(15_000) { sub.await() }
                assertTrue("subscription must end: $ended", ended.isFailure)
                // 判定：记录的电脑 + 410 ⇒ 配对失效（应用接线用的同一个函数）。
                val loss = FlowDeliveryPairingLoss()
                assertTrue(recordDesktopClose(pairing.daemonNodeId, 410, pairing, loss))
                assertTrue(loss.isLost(PairingId(pairing.pairingId)))

                // 5a. 本机之后不再被认。#1122：提交过申请的设备在申请记录的保留期内仍过准入（好轮询自己的
                //     结果），hello 对谁都答——被拒的形状是「hello 不带本机的 pairing_id」（#1119 的同一判据），
                //     或已经是握手层的 401。两种都算。
                val after = runCatching { client.call(desk, Methods.HELLO, buildJsonObject {}) }
                val helloAfter = after.getOrNull()?.takeIf { it.ok }?.result
                    ?.let { ProtoJson.decodeFromJsonElement(com.hawkeyexb.ppass.proto.Hello.serializer(), it) }
                say("after revoke: pairingId=${helloAfter?.pairingId} error=${after.exceptionOrNull()}")
                assertTrue(
                    "after revoke the desktop must no longer recognise our pairing: $after",
                    (helloAfter != null && helloAfter.pairingId != pairing.pairingId) ||
                        (after.exceptionOrNull() as? PeerClosedException)?.code == 401L,
                )

                // 5b. 从没申请过的新身份（配对窗口已关）：握手后即被 401 拒——真机上的有类型关闭码 + 回调。
                val stranger = DaemonClient(bindLog = {})
                val strangerCloses = CopyOnWriteArrayList<Pair<String, Long>>()
                stranger.onPeerClosed = { node, code -> strangerCloses += node to code }
                stranger.bind(ByteArray(32).also { java.security.SecureRandom().nextBytes(it) })
                try {
                    val err = runCatching { stranger.call(desk, Methods.HELLO, buildJsonObject {}) }.exceptionOrNull()
                    say("stranger: $err")
                    assertTrue("expected PeerClosedException 401, got $err", err is PeerClosedException && err.code == 401L)
                    assertEquals(listOf(pairing.daemonNodeId to 401L), strangerCloses.toList())
                } finally {
                    stranger.close()
                }
                say("ALL GREEN")
            } finally {
                client.close()
            }
        }
    }

    private fun <T> assertNotNullAndGet(v: T?): T {
        assertNotNull(v)
        return v!!
    }
}
