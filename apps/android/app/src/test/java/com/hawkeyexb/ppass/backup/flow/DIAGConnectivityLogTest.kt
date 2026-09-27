// DIAG-A：跨 NAT 探测超时的诊断日志——路径分类（与 conninfo.rs 同口径）、探测逐阶段记录、循环检查阶段耗时。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.proto.FlowFetchRequest
import com.hawkeyexb.ppass.proto.FlowStatusReply
import com.hawkeyexb.ppass.proto.FlowTupleRef
import com.hawkeyexb.ppass.transport.CallTrace
import com.hawkeyexb.ppass.transport.DaemonUnreachableException
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PathFacts
import com.hawkeyexb.ppass.transport.PathKind
import com.hawkeyexb.ppass.transport.classifyPaths
import com.hawkeyexb.ppass.transport.isLanAddr
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DIAGConnectivityLogTest {
    // ── 路径分类：与 crates/transport/src/conninfo.rs 的 classify / is_lan_ip 同一张表 ──

    @Test
    fun `lan addresses match conninfo - private, loopback, link-local, ULA`() {
        for (a in listOf("192.168.43.1:5000", "10.0.0.2:1", "172.16.0.9:9", "172.31.255.1:9", "127.0.0.1:7", "169.254.3.4:1", "[fe80::1]:9", "[fd00::5]:9", "[::1]:9", "192.168.1.5")) {
            assertTrue(a, isLanAddr(a))
        }
        for (a in listOf("8.8.8.8:53", "172.32.0.1:9", "[2001:db8::1]:9", "https://aps1-1.relay.n0.iroh.link./", "", "not-an-ip")) {
            assertFalse(a, isLanAddr(a))
        }
    }

    @Test
    fun `selected path wins, relay is relay, no paths is none`() {
        val relay = PathFacts(selected = false, relay = true, remoteAddr = "https://r/", rttMs = 200)
        val lan = PathFacts(selected = true, relay = false, remoteAddr = "192.168.1.9:1234", rttMs = 3)
        val public = PathFacts(selected = false, relay = false, remoteAddr = "1.2.3.4:1234", rttMs = 40)
        assertEquals(PathKind.LAN, classifyPaths(listOf(relay, lan, public)).kind)
        assertEquals(PathKind.RELAY, classifyPaths(listOf(relay, public)).kind) // 没选中 → 第一条
        assertEquals(PathKind.DIRECT, classifyPaths(listOf(public.copy(selected = true), relay)).kind)
        assertEquals(PathKind.NONE, classifyPaths(emptyList()).kind)
        assertEquals(3L, classifyPaths(listOf(lan)).rttMs)
    }

    // ── 探测日志 ──

    private val pairing = Pairing(daemonNodeId = "d", daemonAddrToken = "unused", storageDeviceName = "desk", pairingEpoch = "e1")

    private fun client(probe: suspend ((CallTrace) -> Unit) -> String?) = object : FlowReceiptClient {
        override suspend fun currentPairingEpoch(): String? = error("probe must use the traced entry point")
        override suspend fun probeHello(trace: (CallTrace) -> Unit) = com.hawkeyexb.ppass.proto.Hello(pairingEpoch = probe(trace))
        override suspend fun offer(request: FlowFetchRequest) = FlowStatusReply(state = "active")
        override suspend fun status(tuple: FlowTupleRef) = FlowStatusReply(state = "active")
        override suspend fun suspendFetch(tuple: FlowTupleRef) = Unit
    }

    private fun trace(error: String?) = CallTrace(
        method = "hello", tokenRelay = "https://aps1-1.relay.n0.iroh.link./", tokenDirectAddrs = listOf("192.168.1.5:7000"),
        homeRelayAtStart = null, onlineAfterMs = null, connectMs = null, roundTripMs = null, totalMs = 15_000,
        path = null, pathCount = 0, errorClass = error, errorKind = null, errorMessage = "no response", peerKnownAddr = "relay=- direct=[]",
    )

    // 反证：probe() 的 catch 分支不打日志（改动前的样子）→ 找不到 `Flow probe result=unreachable`，红。
    @Test
    fun `an unreachable probe logs the traced phases and the error`() = runTest {
        val logs = mutableListOf<String>()
        val probe = DaemonDesktopProbe(
            pairing = { pairing },
            desktopFor = { client { t -> t(trace("DaemonUnreachableException")); throw DaemonUnreachableException("hello: no response") } },
            log = FlowLogger { logs += it },
        )
        assertEquals(ProbeResult.Unreachable, probe.probe())
        val line = logs.single()
        assertTrue(line, line.startsWith("Flow probe result=unreachable "))
        for (part in listOf("bindMs=", "online=no", "onlineAfterMs=never", "connectMs=-", "tokenDirect=[192.168.1.5:7000(lan)]", "error=DaemonUnreachableException")) {
            assertTrue("$part in $line", line.contains(part))
        }
    }

    @Test
    fun `a probe that outlives its own timeout is logged as probe_timeout`() = runTest {
        val logs = mutableListOf<String>()
        val probe = DaemonDesktopProbe(
            pairing = { pairing },
            desktopFor = { client { awaitCancellation() } },
            timeoutMs = 20_000,
            log = FlowLogger { logs += it },
        )
        assertEquals(ProbeResult.Unreachable, probe.probe())
        assertTrue(logs.single(), logs.single().startsWith("Flow probe result=unreachable:probe_timeout_20000ms"))
    }

    @Test
    fun `a reachable probe logs its path`() = runTest {
        val logs = mutableListOf<String>()
        val probe = DaemonDesktopProbe(
            pairing = { pairing },
            desktopFor = {
                client { t ->
                    t(trace(null).copy(homeRelayAtStart = "https://r/", onlineAfterMs = 0, connectMs = 900, roundTripMs = 1000, path = classifyPaths(listOf(PathFacts(true, true, "https://r/", 180))), pathCount = 1))
                    "e1"
                }
            },
            log = FlowLogger { logs += it },
        )
        assertEquals(ProbeResult.Reachable("e1"), probe.probe())
        val line = logs.single()
        for (part in listOf("result=reachable", "connectMs=900", "rpcMs=100", "online=yes", "path=relay", "rttMs=180")) {
            assertTrue("$part in $line", line.contains(part))
        }
    }

    // ── 循环检查阶段：本地慢路径 / 取件 / 探测 / 远端存在性各一条耗时 ──

    // 反证：去掉 runCycle 里的 `check … took` 日志 → 红。
    @Test
    fun `the check phase logs how long each step took`() = runTest {
        val rig = Rig(this)
        rig.photo(1, generation = 1)
        rig.trigger(TriggerReason.PERIODIC)
        for (step in listOf("check count took", "check probe took")) {
            assertTrue("$step in ${rig.logs}", rig.logs.any { it.contains(step) })
        }
        rig.close()
    }
}
