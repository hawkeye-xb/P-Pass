// #1124：Android 接 #1122 的关闭码。共享 Rust 核心对这个客户端上任何一条连接（请求、探测、订阅流、
// 取原图）被对端用应用关闭码关掉都回调 DaemonClient.onPeerClosed（Rust 侧测试见
// crates/transport/src/mobile_ffi.rs 的 every_path_reports_a_peer_close_to_the_listener /
// a_held_stream_closed_with_410_reports_at_once）。这里钉 Kotlin 一侧的判定与接线：
// 只有「关闭方 = 配对记录里的那台电脑」且码是 401 / 410 才记成配对失效（随后被拒即清理）；
// 其余一律当连不上，不动配对。
//
// #1126：上传 provider 的入站连接关闭监听与控制面共用同一个监听接口（peerCloseListener）与同一个判据
// （recordDesktopClose），下面「provider 关闭监听」几条钉住接线。
//
// 反证：去掉 desktopRejectionForClose 的关闭方核对 ⇒ 「别的 NodeId」一条变红；去掉码的核对 ⇒
// 「别的关闭码」一条变红；PPassApplication 不接 onPeerClosed ⇒ 接线一条变红。
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.backup.flow.DeliveryOutcome
import com.hawkeyexb.ppass.backup.flow.FlowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.PairingId
import com.hawkeyexb.ppass.backup.flow.classifyDeliveryFailure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class C1124DesktopCloseTest {
    private val desk = "ab".repeat(32)
    private val stranger = "cd".repeat(32)

    private fun pairing(daemon: String = desk) = Pairing(
        daemonNodeId = daemon,
        daemonAddrToken = "t",
        storageDeviceName = "Mac",
        pairingId = "pid-1",
    )

    @Test
    fun `the recorded desktop closing with 401 or 410 is pairing lost`() {
        for ((code, _) in DesktopCloseCodes.registry) {
            val rejected = desktopRejectionForClose(desk, code, desk, "hello")
            assertNotNull("$code", rejected)
            // 与应答 not_paired 同一条归类。
            assertEquals(DeliveryOutcome.PairingLost, classifyDeliveryFailure(rejected!!))
            val loss = FlowDeliveryPairingLoss()
            assertTrue(recordDesktopClose(desk, code, pairing(), loss))
            assertTrue("$code", loss.isLost(PairingId("pid-1")))
        }
        // NodeId 大小写不敏感（hex）。
        assertNotNull(desktopRejectionForClose(desk.uppercase(), 410, desk, "hello"))
    }

    @Test
    fun `another closer is not the desktop - treated as unreachable`() {
        val loss = FlowDeliveryPairingLoss()
        assertNull(desktopRejectionForClose(stranger, 401, desk, "hello"))
        assertFalse(recordDesktopClose(stranger, 410, pairing(), loss))
        assertFalse(loss.isLost(PairingId("pid-1")))
    }

    @Test
    fun `other close codes are not pairing lost`() {
        val loss = FlowDeliveryPairingLoss()
        for (code in listOf(0L, 1L, 400L, 402L, 403L, 409L, 411L, 500L)) {
            assertNull("$code", desktopRejectionForClose(desk, code, desk, "hello"))
            assertFalse("$code", recordDesktopClose(desk, code, pairing(), loss))
        }
        assertFalse(loss.isLost(PairingId("pid-1")))
    }

    @Test
    fun `without a recorded desktop nothing is cleaned`() {
        val loss = FlowDeliveryPairingLoss()
        assertFalse(recordDesktopClose(desk, 401, null, loss))
        assertNull(desktopRejectionForClose(desk, 401, null, "hello"))
        assertNull(desktopRejectionForClose(desk, 401, "  ", "hello"))
    }

    @Test
    fun `an untranslated peer close is a path failure, never pairing lost`() {
        assertEquals(
            DeliveryOutcome.PathFailure("network:PeerClosedException"),
            classifyDeliveryFailure(PeerClosedException(desk, 401)),
        )
    }

    /** 接线：进程级 DaemonClient 的关闭监听接到 recordDesktopClose 与配对失效入口（#1119 清理从那里接走）。 */
    @Test
    fun `the process client routes peer closes into the pairing-loss entry`() {
        val app = File("src/main/java/com/hawkeyexb/ppass/PPassApplication.kt").readText()
        assertTrue(app.contains("client.onPeerClosed = { nodeId, code -> onDesktopClosedConnection(nodeId, code) }"))
        assertTrue(app.contains("recordDesktopClose(nodeId, code, PairingStore(filesDir).load(), flowDeliveryPairingLoss)"))
        // FFI 回调到 Kotlin 的唯一口子在 DaemonClient：每次 bind 都挂上监听。
        val client = File("src/main/java/com/hawkeyexb/ppass/transport/DaemonClient.kt").readText()
        assertTrue(client.contains("it.setPeerCloseListener(closeListener)"))
    }

    // ---------------------------------------------------------------- #1126 provider 关闭监听

    /** 假 provider：登记监听后，由测试像 Rust 那样回调 (NodeId, code)。 */
    private class FakeProvider : com.hawkeyexb.ppass.backup.flow.NativeIrohBlobsProvider {
        var listener: com.hawkeyexb.ppass.ffi.PeerCloseListener? = null
        override fun serve(hash: String): String = error("unused")
        override fun stopActiveFetch(queueSequence: Long) = Unit
        override fun releaseRetention(hash: String) = Unit
        override fun revoke(hash: String) = Unit
        override fun transferStatus() = com.hawkeyexb.ppass.backup.flow.TransferStatus.NoLease
        override fun setPeerCloseListener(listener: com.hawkeyexb.ppass.ffi.PeerCloseListener?) {
            this.listener = listener
        }
    }

    /** 与 PPassApplication.providerCloseListener 同构：回调 → 同一个 recordDesktopClose 判据。 */
    private fun installed(loss: FlowDeliveryPairingLoss): FakeProvider {
        val provider = FakeProvider()
        provider.setPeerCloseListener(peerCloseListener { nodeId, code -> recordDesktopClose(nodeId, code, pairing(), loss) })
        return provider
    }

    @Test
    fun `the recorded desktop closing the provider connection with 410 invalidates the pairing`() {
        val loss = FlowDeliveryPairingLoss()
        installed(loss).listener!!.onPeerClosed(desk, 410UL)
        assertTrue(loss.isLost(PairingId("pid-1")))
    }

    @Test
    fun `another node closing with 410, or the recorded desktop with 0, leaves the pairing alone`() {
        val loss = FlowDeliveryPairingLoss()
        val listener = installed(loss).listener!!
        listener.onPeerClosed(stranger, 410UL)
        listener.onPeerClosed(desk, 0UL)
        assertFalse(loss.isLost(PairingId("pid-1")))
    }

    // 回调在 Rust 线程上：处理里抛出的异常不能穿回去。
    @Test
    fun `an exception in the handler never escapes the callback`() {
        peerCloseListener { _, _ -> error("boom") }.onPeerClosed(desk, 410UL)
    }

    @Test
    fun `the code is passed through as a long`() {
        var seen: Pair<String, Long>? = null
        peerCloseListener { nodeId, code -> seen = nodeId to code }.onPeerClosed(desk, 410UL)
        assertEquals(desk to 410L, seen)
    }

    /** 接线：provider 打开时登记的是应用级监听，它与 daemonClient 走同一个 onDesktopClosedConnection。 */
    @Test
    fun `the provider is opened with the application's close listener`() {
        val app = File("src/main/java/com/hawkeyexb/ppass/PPassApplication.kt").readText()
        assertTrue(app.contains("peerCloseListener { nodeId, code -> onDesktopClosedConnection(nodeId, code) }"))
        val runtime = File("src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidFlowRuntime.kt").readText()
        assertTrue(runtime.contains("(context.applicationContext as PPassApplication).providerCloseListener"))
        val provider = File("src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidNativeIrohBlobsProvider.kt").readText()
        assertTrue(provider.contains("provider.setPeerCloseListener(peerClose)"))
    }

    /** #1124：PeerAddrParts → token → PeerAddrParts 无损（共享 Rust 核心按 token 拨号）。 */
    @Test
    fun `peer token round trips`() {
        val parts = PeerAddrParts(desk, "https://relay.example/", listOf("192.168.1.2:41145", "[fe80::1]:41145"))
        assertEquals(parts, parsePeerAddrToken(parts.toToken()))
        val bare = PeerAddrParts(desk, null, emptyList())
        assertEquals(bare, parsePeerAddrToken(bare.toToken()))
    }
}
