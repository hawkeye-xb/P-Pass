// #413 契约 §5：传输端口的四条新规矩——取消发 flow.suspend（有界）、一轮一条推送订阅、offer 带 size_bytes、
// 错误码按契约分类；外加 hello 的 health 解析。真实的 NativeFlowDeliveryPort，桥 / 原生 / 桌面都是假的，虚拟时间。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.LEGACY_VOLUME
import com.hawkeyexb.ppass.backup.order.MediaDetails
import com.hawkeyexb.ppass.backup.order.MediaSnapshot
import com.hawkeyexb.ppass.proto.FlowCompletionReceipt
import com.hawkeyexb.ppass.proto.FlowFetchRequest
import com.hawkeyexb.ppass.proto.FlowStatusReply
import com.hawkeyexb.ppass.proto.FlowTupleRef
import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.ProtoJson
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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class C413DeliveryPortTest {
    private val hash = "cd".repeat(32)
    private val pairing = Pairing(daemonNodeId = "d", daemonAddrToken = "unused", storageDeviceName = "desk", pairingEpoch = "e1")

    private inner class Harness(val test: TestScope) {
        val nativeEvents = mutableListOf<String>()
        val native = object : NativeIrohBlobsProvider {
            override fun register(hash: String, source: Any): String = "ticket"
            override fun serve(hash: String): String = "ticket"
            override fun stopActiveFetch(queueSequence: Long) {
                nativeEvents += "stop:$queueSequence"
            }
            override fun releaseRetention(hash: String) {
                nativeEvents += "release"
            }
            override fun revoke(hash: String) {
                nativeEvents += "revoke"
            }
            override fun transferStatus(): String = """{"state":"in_progress","connected":true,"idle_for_ms":0,"bytes_sent":1,"byte_idle_for_ms":0}"""
        }
        var offerReply: (FlowFetchRequest) -> FlowStatusReply = { FlowStatusReply(state = "active") }
        var offerFailure: Throwable? = null
        val offers = mutableListOf<FlowFetchRequest>()
        val suspends = mutableListOf<FlowTupleRef>()
        var suspendImpl: suspend (FlowTupleRef) -> Unit = { suspends += it }
        var push: ((String, JsonObject) -> Unit)? = null
        var subscribeCalls = 0
        var connectDelayMs = 0L
        val desktop = object : FlowReceiptClient {
            override suspend fun currentPairingEpoch(): String = "e1"
            override suspend fun offer(request: FlowFetchRequest): FlowStatusReply {
                offers += request
                offerFailure?.let { throw it }
                return offerReply(request)
            }
            override suspend fun status(tuple: FlowTupleRef): FlowStatusReply = FlowStatusReply(state = "active")
            override suspend fun suspendFetch(tuple: FlowTupleRef) = suspendImpl(tuple)
        }
        val port = NativeFlowDeliveryPort(
            bridge = IrohBlobsProviderBridge(native) { "fd" },
            pairing = { pairing },
            desktopFor = { desktop },
            subscribe = { _, onConnected, onEvent ->
                subscribeCalls++
                push = onEvent
                kotlinx.coroutines.delay(connectDelayMs)
                onConnected()
                awaitCancellation()
            },
            cancelTuple = { _, _ -> },
            clock = { test.testScheduler.currentTime },
            sideEffects = CoroutineScope(test.coroutineContext + Job()),
            subscriptionRetryDelaysMs = longArrayOf(1_000),
        )

        fun request(orderId: Long) = DeliveryRequest(
            orderId,
            PairingEpoch("e1"),
            hash,
            MediaDetails(MediaSnapshot(9, "1:1", 7, 1, LEGACY_VOLUME), "content://media/external/file/9", "IMG_9.jpg", "image/jpeg", 4_321, 0),
        )

        fun receipt(orderId: Long) = FlowCompletionReceipt(orderId, "r$orderId", "e1", leaseTokenFor(orderId), hash)

        fun pushDelivered(orderId: Long) {
            push!!(
                "flow.delivered",
                buildJsonObject {
                    put("queue_sequence", JsonPrimitive(orderId))
                    put("pairing_epoch", JsonPrimitive("e1"))
                    put("lease_token", JsonPrimitive(leaseTokenFor(orderId)))
                    put("receipt", ProtoJson.encodeToJsonElement(FlowCompletionReceipt.serializer(), receipt(orderId)))
                },
            )
        }
    }

    // 暂停 / FGS 被收 / 断网 = 协程取消 → flow.suspend，绝不 flow.cancel。
    // 反证：取消分支不调 suspendFetch（或改回发 flow.cancel）→ suspends 为空，红。
    @Test
    fun `cancelling a delivery suspends the desktop fetch instead of cancelling it`() = runTest {
        val h = Harness(this)
        val job = async { h.port.deliver(h.request(1)) {} }
        advanceTimeBy(3_000)
        runCurrent()
        job.cancel()
        runCurrent()
        assertTrue(job.isCancelled)
        assertEquals(listOf(FlowTupleRef(1, "e1", leaseTokenFor(1))), h.suspends)
        assertTrue(h.nativeEvents.containsAll(listOf("stop:1", "revoke")))
    }

    // flow.suspend 有界：桌面不回（DaemonClient 的阻塞 FFI 可能卡 15 秒），暂停也要在约 3 秒内完成。
    // 反证：把 boundedControlCall 换成直接 await 调用 → 取消永远完成不了，job 不结束，红。
    @Test
    fun `a desktop that never answers flow suspend cannot hold the pause longer than the bound`() = runTest {
        val h = Harness(this)
        h.suspendImpl = { awaitCancellation() }
        val job = async { h.port.deliver(h.request(1)) {} }
        advanceTimeBy(3_000)
        runCurrent()
        job.cancel()
        runCurrent()
        assertTrue("still waiting for the bounded suspend", !job.isCompleted)
        advanceTimeBy(CONTROL_CALL_TIMEOUT_MS + 1)
        runCurrent()
        assertTrue(job.isCancelled)
    }

    // 一轮一条订阅：同一个 session 里传两张，只订阅一次；首张 offer 前等订阅就绪。
    // 反证：deliver 每张自己开订阅（原先的 waitForCompletion 里 launch keepSubscribed）→ subscribeCalls = 2，红。
    @Test
    fun `one push subscription serves a whole round and the first offer waits for it`() = runTest {
        val h = Harness(this)
        h.connectDelayMs = 1_500
        val outcomes = mutableListOf<DeliveryOutcome>()
        val round = async {
            h.port.session {
                outcomes += h.port.deliver(h.request(1)) {}
                outcomes += h.port.deliver(h.request(2)) {}
            }
        }
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals("first offer waits for the subscription", 0, h.offers.size)
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(1, h.offers.size)
        h.pushDelivered(1)
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals("second offer does not wait again", 2, h.offers.size)
        h.pushDelivered(1) // 上一张的迟到推送：按 tuple 过滤掉
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(1, outcomes.size)
        h.pushDelivered(2)
        advanceTimeBy(1_000)
        runCurrent()
        round.await()
        assertEquals(listOf(1L, 2L), outcomes.map { (it as DeliveryOutcome.Confirmed).receipt.queueSequence })
        assertEquals(1, h.subscribeCalls)
    }

    // 桌面按 size_bytes 预检剩余空间（契约 §5）。
    @Test
    fun `the offer carries the item size`() = runTest {
        val h = Harness(this)
        h.offerReply = { FlowStatusReply(state = "completed", receipt = h.receipt(it.queueSequence)) }
        assertTrue(h.port.deliver(h.request(1)) {} is DeliveryOutcome.Confirmed)
        assertEquals(4_321L, h.offers.single().sizeBytes)
        assertEquals(4_321L, ProtoJson.encodeToJsonElement(FlowFetchRequest.serializer(), h.offers.single()).let { (it as JsonObject)["size_bytes"].toString().toLong() })
    }

    // offer 被拒的 msgKey 按契约分类：放不下 → 对端失败（不计次数），不是单张失败。
    // 反证：DesktopRejectedException 一律 ItemFailure → 计次数，红。
    @Test
    fun `an offer refused for space is a peer failure`() = runTest {
        val h = Harness(this)
        h.offerFailure = DesktopRejectedException("storage_full", "flow.offer")
        assertEquals(DeliveryOutcome.PeerFailure(PeerFailureKind.STORAGE_FULL, "storage_full"), h.port.deliver(h.request(1)) {})
    }

    @Test
    fun `desktop codes map to the contract`() {
        assertEquals(DeliveryOutcome.PeerFailure(PeerFailureKind.STORAGE_FULL, "storage_full"), classifyPushedFailure("storage_full"))
        assertEquals(DeliveryOutcome.PeerFailure(PeerFailureKind.LIBRARY_UNAVAILABLE, "library_unavailable"), classifyPushedFailure("library_unavailable"))
        assertEquals(DeliveryOutcome.PeerFailure(PeerFailureKind.STORAGE_ERROR, "storage_failed"), classifyPushedFailure("storage_failed"))
        assertEquals(DeliveryOutcome.PathFailure("fetch_failed"), classifyPushedFailure("fetch_failed"))
        assertEquals(DeliveryOutcome.ItemFailure("pushed:materialize_ingest_failed"), classifyPushedFailure("materialize_ingest_failed"))
        assertEquals(DeliveryOutcome.PathFailure("fetch_failed"), classifyDeliveryFailure(DesktopRejectedException("fetch_failed", "flow.offer")))
        assertEquals(DeliveryOutcome.ItemFailure("rejected:err.other"), classifyDeliveryFailure(DesktopRejectedException("err.other", "flow.offer")))
        assertEquals(WaitReason.DESKTOP_STORAGE_FULL, waitReasonOf(PeerFailureKind.STORAGE_FULL))
        assertEquals(WaitReason.DESKTOP_LIBRARY_UNAVAILABLE, waitReasonOf(PeerFailureKind.LIBRARY_UNAVAILABLE))
        assertEquals(WaitReason.DESKTOP_STORAGE_ERROR, waitReasonOf(PeerFailureKind.STORAGE_ERROR))
    }

    // 供数失败：hash 对不上 / 源没了 → 源已删（不计失败）；provider 上线超时 → 路径失败；其余单张失败。
    @Test
    fun `provider failures are classified - a changed source is not a failure and an offline provider is a path failure`() {
        assertEquals(DeliveryOutcome.SourceMissing, classifyProviderFailure(SourceMissingException()))
        assertEquals(DeliveryOutcome.SourceMissing, classifyProviderFailure(SourceChangedException()))
        assertEquals(
            DeliveryOutcome.SourceMissing,
            classifyProviderFailure(IllegalStateException("Io(\"Android provider source does not match its declared content hash\")")),
        )
        assertEquals(DeliveryOutcome.PathFailure("provider_offline"), classifyProviderFailure(ProviderOfflineException()))
        assertEquals(
            DeliveryOutcome.PathFailure("provider_offline"),
            classifyProviderFailure(IllegalStateException("Android provider endpoint did not become online before ticket registration")),
        )
        assertEquals(DeliveryOutcome.ItemFailure("provider:IllegalStateException"), classifyProviderFailure(IllegalStateException("disk full")))
    }

    // 契约 §5 的 JSON 字段名；旧桌面没有 health → 视为健康。
    @Test
    fun `hello health is parsed with the contract field names and absent means healthy`() {
        val hello = ProtoJson.decodeFromString(
            Hello.serializer(),
            """{"proto_ver":1,"pairing_epoch":"e1","health":{"free_bytes":123,"library_writable":false,"index_ok":true}}""",
        )
        val health = desktopHealthOf(hello.health)!!
        assertEquals(DesktopHealth(123L, libraryWritable = false, indexOk = true), health)
        assertTrue(health.lowSpace)
        assertEquals(WaitReason.DESKTOP_LIBRARY_UNAVAILABLE, waitReasonOf(health))
        assertEquals(WaitReason.DESKTOP_STORAGE_ERROR, waitReasonOf(DesktopHealth(null, indexOk = false)))
        assertNull(waitReasonOf(DesktopHealth(1L)))
        val old = ProtoJson.decodeFromString(Hello.serializer(), """{"proto_ver":1,"pairing_epoch":"e1"}""")
        assertNull(desktopHealthOf(old.health))
        assertNull(waitReasonOf(desktopHealthOf(old.health)))
    }
}
