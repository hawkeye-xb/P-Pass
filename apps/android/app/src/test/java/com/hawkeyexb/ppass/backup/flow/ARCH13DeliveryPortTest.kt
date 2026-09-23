// ARCH-13 (#417) E2：传输端口——#410 的参数（15 秒 / 3 分钟无新字节）与失败分类，在虚拟时间里跑真实的
// NativeFlowDeliveryPort 等待循环（桥、原生 provider、桌面控制面都是假的）。反证写在测试上方。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.LEGACY_VOLUME
import com.hawkeyexb.ppass.backup.order.MediaDetails
import com.hawkeyexb.ppass.backup.order.MediaSnapshot
import com.hawkeyexb.ppass.proto.FlowCompletionReceipt
import com.hawkeyexb.ppass.proto.FlowFetchRequest
import com.hawkeyexb.ppass.proto.FlowStatusReply
import com.hawkeyexb.ppass.proto.FlowTupleRef
import com.hawkeyexb.ppass.transport.Pairing
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ARCH13DeliveryPortTest {
    private val hash = "ab".repeat(32)
    private val orderId = 1_790_000_000_123L
    private val pairing = Pairing(daemonNodeId = "d", daemonAddrToken = "unused", storageDeviceName = "desk", pairingEpoch = "e1")

    private inner class Harness(val test: TestScope) {
        var status: () -> String = { """{"state":"in_progress","connected":false}""" }
        val nativeEvents = mutableListOf<String>()
        var onRegister: () -> Unit = {}
        val native = object : NativeIrohBlobsProvider {
            override fun register(hash: String, source: Any): String {
                onRegister()
                return "ticket"
            }
            override fun stopActiveFetch(queueSequence: Long) {
                nativeEvents += "stop:$queueSequence"
            }
            override fun releaseRetention(hash: String) {
                nativeEvents += "release"
            }
            override fun revoke(hash: String) {
                nativeEvents += "revoke"
            }
            override fun transferStatus(): String = status()
        }
        var offerReply = FlowStatusReply(state = "active")
        var statusReply: (Long) -> FlowStatusReply = { FlowStatusReply(state = "active") }
        val offers = mutableListOf<FlowFetchRequest>()
        val statusCallsAt = mutableListOf<Long>()
        val cancels = mutableListOf<FlowFetchRequest>()
        var push: ((String, JsonObject) -> Unit)? = null
        val progress = mutableListOf<Long>()
        val desktop = object : FlowReceiptClient {
            override suspend fun currentPairingEpoch(): String = "e1"
            override suspend fun offer(request: FlowFetchRequest): FlowStatusReply {
                offers += request
                return offerReply
            }
            override suspend fun status(tuple: FlowTupleRef): FlowStatusReply {
                statusCallsAt += test.testScheduler.currentTime
                return statusReply(test.testScheduler.currentTime)
            }
            override suspend fun cancel(request: FlowFetchRequest) {
                cancels += request
            }
        }
        val port = NativeFlowDeliveryPort(
            bridge = IrohBlobsProviderBridge(native) { "fd" },
            pairing = { pairing },
            desktopFor = { desktop },
            subscribe = { _, onEvent ->
                push = onEvent
                awaitCancellation()
            },
            cancelTuple = { _, _ -> },
            clock = { test.testScheduler.currentTime },
            sideEffects = CoroutineScope(test.coroutineContext + Job()),
        )
        val request = DeliveryRequest(
            orderId,
            PairingEpoch("e1"),
            hash,
            MediaDetails(MediaSnapshot(9, "1:1", 7, 1, LEGACY_VOLUME), "content://media/external/file/9", "IMG_9.jpg", "image/jpeg", 1_000_000, 0),
        )

        fun start() = test.async { port.deliver(request) { progress += it } }

        fun receipt() = FlowCompletionReceipt(
            queueSequence = orderId,
            receiptId = "r1",
            pairingEpoch = "e1",
            leaseToken = leaseTokenFor(orderId),
            contentHash = hash,
        )

        fun pushEvent(kind: String, extra: Map<String, kotlinx.serialization.json.JsonElement> = emptyMap()) {
            push!!(
                kind,
                buildJsonObject {
                    put("queue_sequence", JsonPrimitive(orderId))
                    put("pairing_epoch", JsonPrimitive("e1"))
                    put("lease_token", JsonPrimitive(leaseTokenFor(orderId)))
                    extra.forEach { (k, v) -> put(k, v) }
                },
            )
        }
    }

    // #417：queue_sequence 与 lease_token 用 order 行 id 填，线协议不改；NET-24：offer 回复已是终态就当场结账。
    @Test
    fun `the wire tuple is the order id and a terminal offer reply confirms without waiting`() = runTest {
        val h = Harness(this)
        h.offerReply = FlowStatusReply(state = "completed", receipt = h.receipt())
        val outcome = h.start().await()
        assertTrue(outcome is DeliveryOutcome.Confirmed)
        assertEquals(orderId, h.offers.single().queueSequence)
        assertEquals("lease-$orderId", h.offers.single().leaseToken)
        assertEquals(hash, h.offers.single().contentHash)
        assertEquals(listOf("release"), h.nativeEvents)
    }

    // C-10 / #410：连接还在、3 分钟没有新的文件字节 → 主动断开，判路径失败（不是单张失败）。
    // 反证：flowWaitStep 删掉 Stalled 分支 → 181 秒后仍未结束，红。
    @Test
    fun `C-10 connected but no new file bytes for three minutes is a path failure and disconnects`() = runTest {
        val h = Harness(this)
        val startedAt = testScheduler.currentTime
        h.status = {
            val idle = testScheduler.currentTime - startedAt
            """{"state":"in_progress","connected":true,"idle_for_ms":0,"bytes_sent":4096,"byte_idle_for_ms":$idle}"""
        }
        val job = h.start()
        advanceTimeBy(179_000)
        runCurrent()
        assertFalse("still waiting before three minutes", job.isCompleted)
        advanceTimeBy(2_000)
        runCurrent()
        assertTrue(job.isCompleted)
        assertEquals(DeliveryOutcome.PathFailure("byte_stall"), job.await())
        assertTrue("disconnected", h.nativeEvents.containsAll(listOf("stop:$orderId", "revoke")))
    }

    // #410：relay 限流时字节仍在走——只要 end_offset 在前进，就不会被误杀；进度会上报。
    @Test
    fun `bytes that keep moving are never mistaken for a stall`() = runTest {
        val h = Harness(this)
        h.status = {
            val t = testScheduler.currentTime
            """{"state":"in_progress","connected":true,"idle_for_ms":0,"bytes_sent":${t / 1000},"byte_idle_for_ms":${t % 1000}}"""
        }
        val job = h.start()
        advanceTimeBy(10 * 60 * 1000L)
        runCurrent()
        assertFalse(job.isCompleted)
        h.pushEvent("flow.delivered", mapOf("receipt" to com.hawkeyexb.ppass.proto.ProtoJson.encodeToJsonElement(FlowCompletionReceipt.serializer(), h.receipt())))
        advanceTimeBy(1_000)
        runCurrent()
        assertTrue(job.await() is DeliveryOutcome.Confirmed)
        assertTrue("progress reported", h.progress.size > 100 && h.progress == h.progress.sorted())
    }

    // C-11 / #410：15 秒没人来连 → 去问桌面；桌面回 active 就继续等，不判失败。
    // 反证：把 status「active」当失败（flowStatusPollOutcome 的 else → error）→ 结果变成失败，红。
    @Test
    fun `C-11 nobody connected for fifteen seconds asks the desktop and keeps waiting while it says active`() = runTest {
        val h = Harness(this)
        h.statusReply = { now -> if (now >= 60_000) FlowStatusReply(state = "completed", receipt = h.receipt()) else FlowStatusReply(state = "active") }
        val job = h.start()
        advanceTimeBy(14_000)
        runCurrent()
        assertEquals("no status call before 15s", 0, h.statusCallsAt.size)
        advanceTimeBy(3_000)
        runCurrent()
        assertTrue("asked the desktop after 15s", h.statusCallsAt.isNotEmpty())
        assertFalse(job.isCompleted)
        advanceTimeBy(60_000)
        runCurrent()
        assertTrue(job.await() is DeliveryOutcome.Confirmed)
    }

    // #410 / #415 裁决 3：桌面推来的 flow.failed 按 code 分类，code 终于被读。
    // 反证：classifyPushedFailure 一律返回 ItemFailure（原先「只有一种失败」）→ 前两条红。
    @Test
    fun `pushed failure codes are classified - storage is a peer failure, fetch is a path failure, unknown is an item failure`() = runTest {
        for ((code, expected) in listOf(
            "storage_failed" to DeliveryOutcome.PeerFailure("storage_failed"),
            "fetch_failed" to DeliveryOutcome.PathFailure("fetch_failed"),
            "something_new" to DeliveryOutcome.ItemFailure("pushed:something_new"),
        )) {
            val h = Harness(this)
            h.status = { """{"state":"in_progress","connected":true,"idle_for_ms":0,"bytes_sent":1,"byte_idle_for_ms":0}""" }
            val job = h.start()
            runCurrent()
            h.pushEvent("flow.failed", mapOf("code" to JsonPrimitive(code)))
            advanceTimeBy(1_000)
            runCurrent()
            assertEquals(code, expected, job.await())
        }
    }

    @Test
    fun `exceptions are classified - a reachable rejection is not a path failure`() {
        assertEquals(DeliveryOutcome.PairingLost, classifyDeliveryFailure(DesktopRejectedException("err.not_paired", "flow.offer")))
        assertEquals(DeliveryOutcome.ItemFailure("rejected:err.grant_mismatch"), classifyDeliveryFailure(DesktopRejectedException("err.grant_mismatch", "flow.offer")))
        assertEquals(DeliveryOutcome.PathFailure("network:IOException"), classifyDeliveryFailure(java.io.IOException("reset")))
        assertEquals(DeliveryOutcome.PeerFailure("storage_failed"), classifyDeliveryFailure(FlowPushedFailureException("storage_failed")))
    }

    // C-01（传输侧）：被取消（暂停 / 取消 / FGS 收走）→ 停掉原生传输、告诉桌面不等了、把取消抛出去。
    @Test
    fun `cancelling a waiting delivery stops the native fetch and tells the desktop`() = runTest {
        val h = Harness(this)
        val job = h.start()
        advanceTimeBy(5_000)
        runCurrent()
        job.cancel()
        runCurrent()
        assertTrue(job.isCancelled)
        assertTrue(h.nativeEvents.containsAll(listOf("stop:$orderId", "revoke")))
        assertEquals(1, h.cancels.size)
    }

    // 暂停发生在大文件 register（阻塞导入）期间 → register 返回后不再 offer。
    // 反证：删掉 register 之后的 ensureActive 检查 → offers = 1，红。
    @Test
    fun `a pause during a long register never reaches offer`() = runTest {
        val h = Harness(this)
        lateinit var job: kotlinx.coroutines.Deferred<DeliveryOutcome>
        h.onRegister = { job.cancel() }
        job = h.start()
        runCurrent()
        assertTrue(job.isCancelled)
        assertEquals(0, h.offers.size)
        assertTrue(h.nativeEvents.containsAll(listOf("stop:$orderId", "revoke")))
    }

    @Test
    fun `transfer status decodes byte progress and tolerates older native builds`() {
        assertEquals(
            TransferStatus.InProgress(connected = true, idleForMs = 5, bytesSent = 4096, byteIdleForMs = 180_000),
            parseTransferStatus("""{"state":"in_progress","connected":true,"idle_for_ms":5,"bytes_sent":4096,"byte_idle_for_ms":180000}"""),
        )
        assertEquals(
            TransferStatus.InProgress(connected = false, idleForMs = null),
            parseTransferStatus("""{"state":"in_progress","connected":false}"""),
        )
    }

    @Test
    fun `wait step thresholds - fifteen seconds to ask, three minutes of no bytes to give up`() {
        val quiet = TransferStatus.InProgress(connected = false, idleForMs = null)
        assertEquals(FlowWaitStep.KeepWaitingForPush, flowWaitStep(null, quiet, 15_000, 180_000, 14_999))
        assertEquals(FlowWaitStep.CheckStatusNow, flowWaitStep(null, quiet, 15_000, 180_000, 15_000))
        val connected = TransferStatus.InProgress(connected = true, idleForMs = 0, bytesSent = 1, byteIdleForMs = 179_999)
        assertEquals(FlowWaitStep.KeepWaitingForPush, flowWaitStep(null, connected, 15_000, 180_000, 999_999))
        assertEquals(FlowWaitStep.Stalled, flowWaitStep(null, connected.copy(byteIdleForMs = 180_000), 15_000, 180_000, 0))
        assertEquals(FlowWaitStep.Failed("storage_failed"), flowWaitStep(FlowPushOutcome.Failed("storage_failed"), connected, 15_000, 180_000, 0))
        assertEquals(15_000L, LOCAL_IDLE_STALL_THRESHOLD_MS)
        assertEquals(180_000L, BYTE_STALL_THRESHOLD_MS)
    }
}
