// #548：CallTrace.render() 在源头只记类别——公网 IPv4 / IPv6、自建 relay 域名、iroh 手里的对端地址
// 一个原文都不出现。出口 PLog 的脱敏是兜底，不是 render 输出原文的理由。
//
// 反证：还原旧 render（直接 append remoteAddr / tokenDirectAddrs / tokenRelay / homeRelay / peerKnown 原文），红。
package com.hawkeyexb.ppass.transport

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallTraceRenderTest {

    private val customRelay = "https://relay.family-example.org./"
    private val publicV4 = "203.0.113.7:4433"
    private val publicV6 = "[2001:db8:85a3::8a2e:370:7334]:4433"

    private fun trace(path: PathFacts) = CallTrace(
        method = "hello", tokenRelay = customRelay, tokenDirectAddrs = listOf(publicV4, publicV6, "192.168.1.5:7000"),
        homeRelayAtStart = customRelay, onlineAfterMs = 12, connectMs = 900, roundTripMs = 1000, totalMs = 15_000,
        path = classifyPaths(listOf(path)), pathCount = 1,
        errorClass = "IrohException", errorKind = "Connect", errorMessage = "timed out",
        peerKnownAddr = KnownAddr(customRelay, listOf("198.51.100.20:54560", "[2001:db8::1]:7842")),
    )

    private val forbidden = listOf(
        "203.0.113.7", "2001:db8", "198.51.100.20", "relay.family-example.org", "family-example", "192.168.1.5",
    )

    @Test
    fun `direct path - only categories, no raw address or relay domain`() {
        val line = trace(PathFacts(true, false, "198.51.100.20:54560", 40)).render()
        for (f in forbidden) assertFalse("`$f` leaked: $line", line.contains(f))
        for (part in listOf(
            "homeRelay=custom", "path=direct", "remote=v4:public", "tokenRelay=custom",
            "tokenDirect=[v4:public,v6:public,v4:lan]", "peerKnown=relay:custom direct:[v4:public,v6:public]",
        )) assertTrue("$part in $line", line.contains(part))
    }

    @Test
    fun `relay path reports the relay class, n0 relay is named as n0`() {
        val line = trace(PathFacts(true, true, "https://aps1-1.relay.n0.iroh.link./", 180)).render()
        for (f in forbidden) assertFalse("`$f` leaked: $line", line.contains(f))
        assertTrue(line, line.contains("path=relay remote=n0 rttMs=180"))
    }

    @Test
    fun `address and relay classes`() {
        assertEquals("v4:public", addrClass("203.0.113.7:4433"))
        assertEquals("v4:lan", addrClass("10.0.0.5:1"))
        assertEquals("v6:public", addrClass("[2001:db8::1]:9"))
        assertEquals("v6:lan", addrClass("[fe80::1]:9"))
        assertEquals("v6:public", addrClass("2001:db8::1"))
        assertEquals("other", addrClass("not-an-ip"))
        assertEquals("other", addrClass(""))
        assertEquals("n0", relayClass("https://aps1-1.relay.n0.iroh.link./"))
        assertEquals("custom", relayClass("https://relay.family-example.org"))
        assertEquals("custom", relayClass("https://iroh.link.evil.example/"))
        assertEquals("-", relayClass(null))
        assertEquals("-", relayClass(""))
    }
}
