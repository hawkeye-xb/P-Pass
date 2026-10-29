// #1119 被拒即清理：每一条信号路径（探测 / 投递 / 前台心跳）→ 记失效 → PairingRejectionCleanup → 断开清单。
// 用真的 store、真的 DaemonDesktopProbe / applyHeartbeatOutcome / FlowDeliveryPairingLoss.record、真的清单执行器；
// 唯一的替身是对端（FlowReceiptClient / Resp）与运行时记账（DisconnectRuntime）。
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.Screen
import com.hawkeyexb.ppass.backup.AutoBackupPrefs
import com.hawkeyexb.ppass.backup.DisconnectRuntime
import com.hawkeyexb.ppass.backup.applyDisconnectManifest
import com.hawkeyexb.ppass.backup.flow.DaemonDesktopProbe
import com.hawkeyexb.ppass.backup.flow.DesktopRejectedException
import com.hawkeyexb.ppass.backup.flow.FlowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.FlowPushedFailureException
import com.hawkeyexb.ppass.backup.flow.FlowReceiptClient
import com.hawkeyexb.ppass.backup.flow.PairingId
import com.hawkeyexb.ppass.backup.flow.ProbeResult
import com.hawkeyexb.ppass.proto.FlowFetchRequest
import com.hawkeyexb.ppass.proto.FlowStatusReply
import com.hawkeyexb.ppass.proto.FlowTupleRef
import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.proto.Resp
import com.hawkeyexb.ppass.proto.RespError
import com.hawkeyexb.ppass.screenAfterPairingCleared
import java.io.File
import java.io.IOException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PairingRejectionCleanupTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var filesDir: File
    private lateinit var cacheDir: File
    private val loss = FlowDeliveryPairingLoss()
    private val pairing = Pairing(daemonNodeId = "d".repeat(64), daemonAddrToken = "t", storageDeviceName = "Home", pairingId = "e1")

    private class Recording : DisconnectRuntime {
        var flowStopped = 0
        var previewsCleared = 0
        val cancelled = mutableListOf<String>()
        override fun stopFlowRuntime() { flowStopped++ }
        override fun cancelUniqueWork(name: String) { cancelled += name }
        override fun cancelMediaWatch() = Unit
        override fun clearPreviewCache() { previewsCleared++ }
    }

    private val runtime = Recording()
    private var unpairNotices = 0
    private lateinit var cleanup: PairingRejectionCleanup

    @Before
    fun setUp() {
        val data = tmp.newFolder("data")
        filesDir = File(data, "files").apply { mkdirs() }
        cacheDir = File(data, "cache").apply { mkdirs() }
        PairingStore(filesDir).save(pairing)
        AutoBackupPrefs(filesDir).apply { setRequested(true); setEnabled(true) }
        File(cacheDir, "video-0123456789abcdef.mp4").writeText("x")
        File(cacheDir, "video-0123456789abcdef.mp4.part").writeText("x")
        File(cacheDir, "share").mkdirs()
        File(cacheDir, "share/asset-1").writeText("x")
        // 与生产 clearLocalPairing 同一份清单；没有任何一步会发 device.unpair（这里没有 client 可发）。
        cleanup = PairingRejectionCleanup(
            currentPairing = { PairingStore(filesDir).load() },
            loss = loss,
            clear = { applyDisconnectManifest(filesDir, cacheDir, runtime) },
        )
    }

    private fun assertCleared(pid: String = "e1") {
        assertNull("配对记录必须删掉", PairingStore(filesDir).load())
        assertEquals("原图缓存必须清空", emptyList<String>(), cacheDir.list().orEmpty().toList())
        assertEquals("九条后台任务全部取消", 9, runtime.cancelled.toSet().size)
        assertEquals("运行时必须停", 1, runtime.flowStopped)
        assertEquals("缩略图缓存必须清", 1, runtime.previewsCleared)
        assertFalse("停生产者", AutoBackupPrefs(filesDir).enabled())
        assertEquals("界面据此回欢迎页", pid, cleanup.clearedPairingId.value)
    }

    private fun assertUntouched() {
        assertEquals(pairing, PairingStore(filesDir).load())
        assertEquals(listOf("share", "video-0123456789abcdef.mp4", "video-0123456789abcdef.mp4.part"), cacheDir.list().orEmpty().sorted())
        assertEquals(0, runtime.cancelled.size)
        assertEquals(0, runtime.flowStopped)
        assertNull(cleanup.clearedPairingId.value)
        assertTrue(AutoBackupPrefs(filesDir).enabled())
    }

    // ── 发现路径 ──────────────────────────────────────────────

    private fun client(hello: () -> Hello) = object : FlowReceiptClient {
        override suspend fun currentPairingId(): String? = error("unused")
        override suspend fun probeHello(trace: (com.hawkeyexb.ppass.transport.CallTrace) -> Unit): Hello = hello()
        override suspend fun offer(request: FlowFetchRequest) = FlowStatusReply(state = "active")
        override suspend fun status(tuple: FlowTupleRef) = FlowStatusReply(state = "active")
        override suspend fun suspendFetch(tuple: FlowTupleRef) = Unit
    }

    private suspend fun probe(hello: () -> Hello): ProbeResult =
        DaemonDesktopProbe(pairing = { PairingStore(filesDir).load() }, desktopFor = { client(hello) }, pairingLoss = loss).probe()

    private fun helloResp(pairingId: String?) = Resp(
        ok = true,
        result = ProtoJson.encodeToJsonElement(Hello.serializer(), Hello(pairingId = pairingId)),
    )

    private fun heartbeat(outcome: Result<Resp>) = applyHeartbeatOutcome(
        null, outcome,
        onPairingLost = { failure -> loss.record(PairingId("e1"), failure) },
        localPairingId = "e1",
    )

    // 反证（本组每条）：把 not_paired / 无 pairing_id / pairing_mismatch 从「配对失效」里拿掉、或收到后不调清理 → 红。
    @Test
    fun `not_paired on a business request clears everything once`() {
        loss.record(PairingId("e1"), DesktopRejectedException("not_paired", "flow.offer"))
        assertTrue(cleanup.onLossRecorded())
        assertCleared()
        // 幂等：再收到同一个拒绝（在途请求）、再触发一次清理——空操作，不重复取消 / 停运行时。
        loss.record(PairingId("e1"), DesktopRejectedException("not_paired", "flow.status"))
        assertFalse(cleanup.onLossRecorded())
        assertFalse(cleanup.onLossRecorded())
        assertCleared()
        assertEquals("清单只执行了一次", 9, runtime.cancelled.size)
    }

    @Test
    fun `a pushed flow_failed not_paired is the same fact`() {
        loss.record(PairingId("e1"), FlowPushedFailureException("not_paired"))
        assertTrue(cleanup.onLossRecorded())
        assertCleared()
    }

    @Test
    fun `hello ok without pairing_id (probe) clears`() = runTest {
        assertEquals(ProbeResult.PairingLost, probe { Hello(pairingId = null) })
        assertTrue(cleanup.onLossRecorded())
        assertCleared()
    }

    @Test
    fun `hello ok with a blank or different pairing_id (probe) clears`() = runTest {
        assertEquals(ProbeResult.PairingLost, probe { Hello(pairingId = "") })
        assertTrue(cleanup.onLossRecorded())
        assertCleared()
    }

    @Test
    fun `hello ok with a different pairing_id clears`() = runTest {
        assertEquals(ProbeResult.PairingLost, probe { Hello(pairingId = "e2") })
        assertTrue(cleanup.onLossRecorded())
        assertCleared()
    }

    @Test
    fun `hello ok without pairing_id (heartbeat) clears`() {
        heartbeat(Result.success(helloResp(null)))
        assertTrue(cleanup.onLossRecorded())
        assertCleared()
    }

    @Test
    fun `hello ok with a different pairing_id (heartbeat) clears`() {
        heartbeat(Result.success(helloResp("e2")))
        assertTrue(cleanup.onLossRecorded())
        assertCleared()
    }

    @Test
    fun `not_paired on hello (heartbeat) clears`() {
        heartbeat(Result.success(Resp(ok = false, error = RespError("X", "not_paired"))))
        assertTrue(cleanup.onLossRecorded())
        assertCleared()
    }

    @Test
    fun `pairing_mismatch on hello (heartbeat) clears`() {
        heartbeat(Result.success(Resp(ok = false, error = RespError("X", "pairing_mismatch"))))
        assertTrue(cleanup.onLossRecorded())
        assertCleared()
    }

    @Test
    fun `pairing_mismatch on a business request clears`() {
        loss.record(PairingId("e1"), DesktopRejectedException("pairing_mismatch", "flow.offer"))
        assertTrue(cleanup.onLossRecorded())
        assertCleared()
    }

    // ── 不触发 ────────────────────────────────────────────────
    // 反证：把 role_forbidden / 超时 / 连不上 / 版本不匹配 / 其它错误也归为未配对（或把「hello 带着本机 pairing_id」判成缺失）→ 红。

    @Test
    fun `a matching pairing_id is just reachable`() = runTest {
        assertTrue(probe { Hello(pairingId = "e1") } is ProbeResult.Reachable)
        var reachable = 0
        applyHeartbeatOutcome(null, Result.success(helloResp("e1")), onPairingLost = { error("must not fire") }, localPairingId = "e1") { reachable++ }
        assertEquals(1, reachable)
        assertFalse(cleanup.onLossRecorded())
        assertUntouched()
    }

    @Test
    fun `role_forbidden does not clear`() = runTest {
        loss.record(PairingId("e1"), DesktopRejectedException("role_forbidden", "flow.offer"))
        loss.record(PairingId("e1"), FlowPushedFailureException("role_forbidden"))
        heartbeat(Result.success(Resp(ok = false, error = RespError("X", "role_forbidden"))))
        assertEquals(ProbeResult.Unreachable, probe { throw DesktopRejectedException("role_forbidden", "hello") })
        assertFalse(cleanup.onLossRecorded())
        assertUntouched()
    }

    @Test
    fun `timeouts, unreachable, outdated and other errors do not clear`() = runTest {
        assertEquals(ProbeResult.Unreachable, probe { throw IOException("unreachable") })
        assertEquals(ProbeResult.Unreachable, probe { throw DaemonUnreachableException("no route") })
        assertEquals(ProbeResult.Unreachable, probe { throw TimeoutCancellationExceptionFactory.make() })
        assertTrue(probe { throw DesktopRejectedException("phone_outdated", "hello") } is ProbeResult.NeedsUpdate)
        assertTrue(probe { throw DesktopRejectedException("desktop_outdated", "hello") } is ProbeResult.NeedsUpdate)
        assertEquals(ProbeResult.Unreachable, probe { throw DesktopRejectedException("internal", "hello") })
        loss.record(PairingId("e1"), IOException("boom"))
        loss.record(PairingId("e1"), DesktopRejectedException("storage_full", "flow.offer"))
        heartbeat(Result.failure(IOException("unreachable")))
        heartbeat(Result.success(Resp(ok = false, error = RespError("VERSION_MISMATCH", "desktop_outdated"))))
        heartbeat(Result.success(Resp(ok = false, error = RespError("X", "internal"))))
        // 解不出来的 hello 不是「未配对」信号。
        heartbeat(Result.success(Resp(ok = true, result = kotlinx.serialization.json.JsonPrimitive("garbage"))))
        assertFalse(cleanup.onLossRecorded())
        assertUntouched()
    }

    @Test
    fun `a late rejection of an old pairing never clears a newer pairing`() {
        loss.record(PairingId("e1"), DesktopRejectedException("not_paired", "flow.offer"))
        PairingStore(filesDir).save(pairing.copy(pairingId = "e2"))
        assertFalse(cleanup.onLossRecorded())
        assertEquals("e2", PairingStore(filesDir).load()?.pairingId)
        assertEquals(0, runtime.cancelled.size)
    }

    @Test
    fun `no pairing means nothing to do`() {
        PairingStore(filesDir).clear()
        loss.record(PairingId("e1"), DesktopRejectedException("not_paired", "flow.offer"))
        assertFalse(cleanup.onLossRecorded())
        assertEquals(0, runtime.cancelled.size)
        assertNull(cleanup.clearedPairingId.value)
    }

    @Test
    fun `if the pairing record cannot be deleted the screen is not told it is disconnected`() {
        val stuck = PairingRejectionCleanup({ PairingStore(filesDir).load() }, loss) { /* 清理失败：什么也没删 */ }
        loss.record(PairingId("e1"), DesktopRejectedException("not_paired", "flow.offer"))
        assertFalse(stuck.onLossRecorded())
        assertNull(stuck.clearedPairingId.value)
    }

    // ── 界面回欢迎页 / 接线 ───────────────────────────────────

    @Test
    fun `screens on the cleared pairing go back to welcome, others stay`() {
        val home = Screen.Home(pairing)
        assertSame(Screen.Welcome, screenAfterPairingCleared(home, "e1"))
        assertSame(Screen.Welcome, screenAfterPairingCleared(Screen.Buckets(pairing, emptySet(), firstTime = false), "e1"))
        assertSame(Screen.Welcome, screenAfterPairingCleared(Screen.Started(pairing, 3), "e1"))
        assertSame(Screen.Welcome, screenAfterPairingCleared(Screen.PhotoIntro(pairing, firstTime = true), "e1"))
        // 清的不是这一条，或者用户正在建立新配对：不动。
        assertSame(home, screenAfterPairingCleared(home, "e0"))
        for (s in listOf(Screen.Scan, Screen.ManualPair, Screen.Welcome, Screen.Waiting("qr"))) {
            assertSame(s, screenAfterPairingCleared(s, "e1"))
        }
    }

    @Test
    fun `the application runs cleanup after the notice evaluation, and the activity listens for it`() {
        val app = File("src/main/java/com/hawkeyexb/ppass/PPassApplication.kt").readText()
        val collector = app.substringAfter("flowDeliveryPairingLoss.changes.collect {").substringBefore("}\n        }")
        assertTrue(collector.indexOf("evaluateDefinitiveEvents") in 0 until collector.indexOf("pairingRejectionCleanup.onLossRecorded()"))
        assertTrue("清理必须走与手动断开同一个入口", app.contains("clear = { clearLocalPairingLogged(this, it) }"))
        val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        assertTrue(main.contains("pairingRejectionCleanup.clearedPairingId.collect"))
        // 被动断开不发 device.unpair：清理入口里不许出现通知。
        val cleanupSrc = File("src/main/java/com/hawkeyexb/ppass/transport/PairingRejectionCleanup.kt").readText()
        assertFalse(cleanupSrc.contains("unpair("))
        assertFalse(cleanupSrc.contains("notifyUnpairOnce"))
    }
}

private object TimeoutCancellationExceptionFactory {
    /** 一个真的 [TimeoutCancellationException]（withTimeout 超时抛的那种）。 */
    fun make(): Throwable = try {
        kotlinx.coroutines.runBlocking { kotlinx.coroutines.withTimeout(1) { kotlinx.coroutines.delay(1_000) } }
        error("unreachable")
    } catch (e: TimeoutCancellationException) {
        e
    }
}
