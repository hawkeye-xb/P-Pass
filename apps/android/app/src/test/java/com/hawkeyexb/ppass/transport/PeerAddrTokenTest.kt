package com.hawkeyexb.ppass.transport

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class PeerAddrTokenTest {

    /** Encode the daemon's PeerAddr JSON the way transport::PeerAddr does. */
    private fun token(json: String): String =
        java.util.Base64.getUrlEncoder().withoutPadding()
            .encodeToString(json.toByteArray(Charsets.UTF_8))

    private val idHex = "ab".repeat(32)

    @Test
    fun parsesRelayAndDirectAddresses() {
        val t = token(
            """{"id":"$idHex","addrs":[{"Relay":"https://aps1-1.relay.n0.iroh.link./"},{"Ip":"10.1.150.82:51124"},{"Ip":"138.113.121.131:51124"}]}"""
        )
        val p = parsePeerAddrToken(t)
        assertEquals(idHex, p.idHex)
        assertEquals("https://aps1-1.relay.n0.iroh.link./", p.relayUrl)
        assertEquals(listOf("10.1.150.82:51124", "138.113.121.131:51124"), p.directAddresses)
    }

    @Test
    fun ipOnlyTokenHasNoRelay() {
        val t = token("""{"id":"$idHex","addrs":[{"Ip":"192.168.1.5:41145"}]}""")
        val p = parsePeerAddrToken(t)
        assertNull(p.relayUrl)
        assertEquals(listOf("192.168.1.5:41145"), p.directAddresses)
    }

    @Test
    fun pairingQrRoundTrip() {
        val addrToken = token("""{"id":"$idHex","addrs":[{"Ip":"10.0.0.2:41145"}]}""")
        val nodeHex = "cd".repeat(32)
        val tokenHex = "11".repeat(32)
        val qr = parsePairingQr("ppf://pair?node=$nodeHex&t=$tokenHex&a=$addrToken")
        assertEquals(nodeHex, qr.nodeIdHex)
        assertEquals(tokenHex, qr.token)
        assertEquals(listOf("10.0.0.2:41145"), qr.addr!!.directAddresses)
    }

    @Test
    fun legacyQrWithoutAddressStillParses() {
        val qr = parsePairingQr("ppf://pair?node=${"ee".repeat(32)}&t=${"22".repeat(32)}")
        assertNull(qr.addr)
    }

    @Test
    fun garbageIsRejected() {
        assertThrows(Exception::class.java) { parsePairingQr("https://example.com") }
        assertThrows(Exception::class.java) {
            parsePeerAddrToken(token("""{"id":"tooshort","addrs":[]}"""))
        }
    }
}
