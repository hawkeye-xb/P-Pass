// T-051 acceptance: a REAL round trip — this JVM test binds an actual
// iroh endpoint (the iroh-ffi jar ships desktop natives) and speaks
// hello to a live storage daemon, exactly like the phone will.
//
// Needs a daemon: set PPF_DAEMON_QR to a fresh pairing QR string
// (`ppf://pair?...&a=...`). Skipped when unset so CI stays hermetic;
// `just android-hello` runs the full script locally.
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.ProtoJson
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class DaemonHelloTest {

    @Test
    fun helloRoundTripAgainstLiveDaemon() {
        val qr = System.getenv("PPF_DAEMON_QR")
        assumeTrue("PPF_DAEMON_QR not set — skipping live-daemon test", !qr.isNullOrBlank())

        runBlocking {
            val parsed = parsePairingQr(qr!!.trim())
            assertNotNull("QR must carry an address (a=)", parsed.addr)

            val client = DaemonClient()
            client.bind()
            try {
                val resp = client.call(parsed.addr!!, Methods.HELLO, buildJsonObject {})
                assertTrue("hello must succeed: ${resp.error}", resp.ok)
                val hello: Hello =
                    ProtoJson.decodeFromJsonElement(Hello.serializer(), resp.result!!)
                assertEquals(1, hello.protoVer)
                assertTrue(
                    "daemon must announce thumbnail.v1: ${hello.capabilities}",
                    hello.capabilities.contains("thumbnail.v1"),
                )
                println("HELLO OK: ${hello.deviceName} caps=${hello.capabilities}")
            } finally {
                client.close()
            }
        }
    }
}
