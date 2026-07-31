// Diagnostic: layer-by-layer network probe on the real device —
// separates "UDP is blocked" from "iroh can't connect" from "pairing
// logic". Run with -e daemon_qr <qr>.
package com.hawkeyexb.ppass

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.parsePairingQr
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NetProbeTest {

    /** Raw UDP out: a DNS query to 223.5.5.5:53 must come back. */
    @Test
    fun udpEgressWorks() {
        val sock = DatagramSocket()
        sock.soTimeout = 5000
        // Minimal DNS query for example.com A record.
        val q = byteArrayOf(
            0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0,
            7, 'e'.code.toByte(), 'x'.code.toByte(), 'a'.code.toByte(),
            'm'.code.toByte(), 'p'.code.toByte(), 'l'.code.toByte(), 'e'.code.toByte(),
            3, 'c'.code.toByte(), 'o'.code.toByte(), 'm'.code.toByte(),
            0, 0, 1, 0, 1,
        )
        sock.send(DatagramPacket(q, q.size, InetAddress.getByName("223.5.5.5"), 53))
        val buf = ByteArray(512)
        val resp = DatagramPacket(buf, buf.size)
        sock.receive(resp) // throws SocketTimeoutException if UDP is dead
        println("PROBE UDP OK: got ${resp.length} bytes from DNS")
        sock.close()
    }

    /** iroh hello with verbose logging and a short timeout. */
    @Test
    fun irohHelloToDaemon() {
        val qr = InstrumentationRegistry.getArguments().getString("daemon_qr")
        assumeTrue("no -e daemon_qr", !qr.isNullOrBlank())
        try {
            computer.iroh.setLogLevel(computer.iroh.LogLevel.DEBUG)
        } catch (_: Throwable) {}

        runBlocking {
            val client = DaemonClient()
            client.bind()
            try {
                val addr = parsePairingQr(qr!!.trim()).addr!!
                val resp = withTimeout(30_000) {
                    client.call(addr, Methods.HELLO, buildJsonObject {})
                }
                println("PROBE HELLO OK: ${resp.result}")
            } finally {
                client.close()
            }
        }
    }
}
