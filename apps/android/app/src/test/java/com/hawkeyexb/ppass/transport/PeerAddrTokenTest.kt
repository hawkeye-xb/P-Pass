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
            """{"id":"$idHex","addrs":[{"Relay":"https://aps1-1.relay.n0.iroh.link./"},{"Ip":"192.168.1.20:51124"},{"Ip":"203.0.113.131:51124"}]}"""
        )
        val p = parsePeerAddrToken(t)
        assertEquals(idHex, p.idHex)
        assertEquals("https://aps1-1.relay.n0.iroh.link./", p.relayUrl)
        assertEquals(listOf("192.168.1.20:51124", "203.0.113.131:51124"), p.directAddresses)
    }

    @Test
    fun ipOnlyTokenHasNoRelay() {
        val t = token("""{"id":"$idHex","addrs":[{"Ip":"192.168.1.5:41145"}]}""")
        val p = parsePeerAddrToken(t)
        assertNull(p.relayUrl)
        assertEquals(listOf("192.168.1.5:41145"), p.directAddresses)
    }

    @Test
    fun garbageIsRejected() {
        assertThrows(Exception::class.java) {
            parsePeerAddrToken(token("""{"id":"tooshort","addrs":[]}"""))
        }
    }

}
