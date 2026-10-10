// #548：logcat 唯一出口 PLog 写出前统一脱敏——调用点怎么拼（地址、自建 relay、全长 hash、
// 原生异常文本、异常 cause 链）都不影响写出去的是什么。
//
// 反证：把 PLog.render 里的 Redact.redact 撤掉（直接返回 raw），本文件全红。
package com.hawkeyexb.ppass.log

import com.hawkeyexb.ppass.transport.CallTrace
import com.hawkeyexb.ppass.transport.KnownAddr
import com.hawkeyexb.ppass.transport.PathFacts
import com.hawkeyexb.ppass.transport.classifyPaths
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class PLogExitTest {

    private data class Line(val priority: Int, val tag: String, val message: String)

    private val lines = mutableListOf<Line>()

    @Before
    fun capture() {
        PLog.sink = PLog.Sink { p, t, m -> lines += Line(p, t, m) }
    }

    @After
    fun restore() = PLog.resetSink()

    private val hash = "4333cf7417fd9b3b533089e86eae4c739712fc08662a44efadb762be4ead6998"
    private val raw = listOf(
        "203.0.113.7", "198.51.100.20", "2001:db8:85a3::8a2e:370:7334", "2001:db8::1",
        "relay.family-example.org", hash,
    )

    private fun assertClean(text: String) {
        for (r in raw) assertFalse("`$r` leaked: $text", text.contains(r))
    }

    @Test
    fun `message text is redacted before it reaches logcat`() {
        PLog.i(
            "PPassFlow",
            "connect remote=203.0.113.7:4433 via https://relay.family-example.org./ " +
                "v6=[2001:db8:85a3::8a2e:370:7334]:4433 release $hash lan=192.168.1.5:7000",
        )
        val line = lines.single()
        assertEquals(PLog.INFO, line.priority)
        assertEquals("PPassFlow", line.tag)
        assertClean(line.message)
        assertTrue(line.message, line.message.contains("remote=<ipv4:public>:4433"))
        assertTrue(line.message, line.message.contains("https://<host>/"))
        assertTrue(line.message, line.message.contains("[<ipv6:public>]:4433"))
        assertTrue(line.message, line.message.contains("release 4333cf74…<masked>"))
        assertTrue("私网地址排障要看，原样保留", line.message.contains("lan=192.168.1.5:7000"))
    }

    @Test
    fun `throwable message and cause chain are redacted too`() {
        val cause = IllegalStateException("dial wss://relay.family-example.org/relay from 198.51.100.20:54560")
        PLog.w("PPassFlow", "wake failed", RuntimeException("connect to [2001:db8::1]:7842 failed", cause))
        val line = lines.single()
        assertEquals(PLog.WARN, line.priority)
        assertClean(line.message)
        assertTrue(line.message, line.message.startsWith("wake failed\njava.lang.RuntimeException: connect to [<ipv6:public>]:7842"))
        assertTrue("cause 链也在且已脱敏", line.message.contains("Caused by: java.lang.IllegalStateException: dial wss://<host>/relay from <ipv4:public>:54560"))
    }

    @Test
    fun `a Flow probe line with raw native error text comes out clean`() {
        // 生产路径：DaemonDesktopProbe 拼 `Flow probe result=… ${trace.render()} error=…: ${t.message}`，
        // 经 PPassApplication / AndroidFlowRuntime 注入的 FlowLogger 交给 PLog.i。render 自己只出类别，
        // 但 errorMessage / 异常 message 是 iroh 原文，可能带地址——靠出口兜。
        val trace = CallTrace(
            method = "hello", tokenRelay = "https://relay.family-example.org./",
            tokenDirectAddrs = listOf("203.0.113.7:4433", "[2001:db8:85a3::8a2e:370:7334]:4433"),
            homeRelayAtStart = "https://aps1-1.relay.n0.iroh.link./", onlineAfterMs = 0, connectMs = null, roundTripMs = null,
            totalMs = 15_000, path = classifyPaths(listOf(PathFacts(true, false, "198.51.100.20:54560", 40))), pathCount = 1,
            errorClass = "IrohException", errorKind = "Connect",
            errorMessage = "timed out: remote_addr=Ip(203.0.113.7:4433) relay=https://relay.family-example.org./",
            peerKnownAddr = KnownAddr("https://relay.family-example.org./", listOf("203.0.113.7:4433")),
        )
        PLog.i("PPassFlow", "Flow probe result=unreachable totalMs=15001 bindMs=3 ${trace.render()} error=IrohException: dial 2001:db8::1 failed")
        val line = lines.single().message
        assertClean(line)
        assertTrue(line, line.contains("tokenDirect=[v4:public,v6:public]"))
        assertTrue(line, line.contains("tokenRelay=custom"))
        assertTrue(line, line.contains("msg=timed out: remote_addr=Ip(<ipv4:public>:4433) relay=https://<host>/"))
    }
}
