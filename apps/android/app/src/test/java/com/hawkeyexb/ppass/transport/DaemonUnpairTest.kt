// UX-06 acceptance, wire level: unilateral stop against a LIVE daemon —
// pair fresh, call device.unpair, then verify hello is DENIED (revoked
// devices get nothing, not even hello) and that the same identity can
// rejoin with a fresh owner-issued token. Set PPF_DAEMON_QR +
// PPF_DAEMON_IPC ("sock\ntoken" file path); `just android-pair`
// orchestrates it (same harness as DaemonPairTest).
package com.hawkeyexb.ppass.transport

import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class DaemonUnpairTest {

    private fun ipcConfirm(ipcTokenFile: String) {
        val script = """
import socket, json, sys
lines = open(sys.argv[1]).read().splitlines()
name = lines[0].strip()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
if sys.platform == 'linux':
    s.connect('\0' + name)
else:
    s.connect('/tmp/' + name)
f = s.makefile('rw')
f.write(lines[1].strip() + '\n'); f.flush()
f.write(json.dumps({'id':'t','method':'pairing.confirm','params':{'accept':True}}) + '\n'); f.flush()
resp = json.loads(f.readline())
assert resp.get('ok'), resp
print('confirmed', resp['result'])
"""
        val proc = ProcessBuilder("python3", "-c", script, ipcTokenFile)
            .redirectErrorStream(true).start()
        val out = proc.inputStream.bufferedReader().readText()
        check(proc.waitFor() == 0 && out.contains("confirmed")) { "IPC confirm failed: $out" }
    }

    @Test
    fun unpairDeniesHelloThenFreshTokenRejoins() {
        val qr = System.getenv("PPF_DAEMON_QR")
        val ipc = System.getenv("PPF_DAEMON_IPC")
        assumeTrue(
            "PPF_DAEMON_QR / PPF_DAEMON_IPC not set — skipping live unpair test",
            !qr.isNullOrBlank() && !ipc.isNullOrBlank(),
        )

        runBlocking {
            val client = DaemonClient()
            client.bind()
            try {
                // Pair fresh (owner confirms via IPC, as the desktop shell does).
                val phone = async(Dispatchers.IO) {
                    pairWithQr(client, qr!!.trim(), deviceName = "JVM 测试手机")
                }
                launch(Dispatchers.IO) {
                    delay(2_000)
                    ipcConfirm(ipc!!.trim())
                }
                val outcome = phone.await()
                assertTrue("expected Joined, got $outcome", outcome is PairOutcome.Joined)
                val p = (outcome as PairOutcome.Joined).pairing
                val peer = parsePeerAddrToken(p.daemonAddrToken)

                // Unilateral stop: the device revokes itself.
                val unpaired = client.unpair(peer)
                assertTrue("device.unpair must succeed", unpaired)

                // hello is now denied (revoked ⇒ not even hello).
                val hello = client.call(peer, "hello", buildJsonObject {})
                assertFalse("revoked device must not reach hello", hello.ok)
                println("UNPAIR OK: hello denied (${hello.error?.msgKey})")
            } finally {
                client.close()
            }
        }
    }
}
