// T-052 acceptance, wire level: full pairing against a LIVE daemon —
// the Kotlin client plays the phone, this test plays the owner
// clicking Allow through the daemon's local IPC (same as the desktop
// shell does). Set PPF_DAEMON_QR + PPF_DAEMON_IPC ("sock\ntoken" file
// path); `just android-pair` orchestrates it.
package com.hawkeyexb.ppass.transport

import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class DaemonPairTest {

    private fun ipcConfirm(ipcTokenFile: String) {
        // android.jar hides JDK16's UnixDomainSocketAddress from the
        // unit-test compile classpath — shell out to python3 instead
        // (this test only runs on a dev machine, never on-device).
        val script = """
import socket, json, sys
lines = open(sys.argv[1]).read().splitlines()
name = lines[0].strip()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
# ipc.rs uses interprocess GenericNamespaced: Linux = abstract namespace
# (connect "\0"+name, no filesystem path), macOS = /tmp/<name> file.
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
    fun fullPairingAgainstLiveDaemon() {
        val qr = System.getenv("PPF_DAEMON_QR")
        val ipc = System.getenv("PPF_DAEMON_IPC")
        assumeTrue(
            "PPF_DAEMON_QR / PPF_DAEMON_IPC not set — skipping live pair test",
            !qr.isNullOrBlank() && !ipc.isNullOrBlank(),
        )

        runBlocking {
            val client = DaemonClient()
            client.bind()
            try {
                // The phone side blocks inside pair.request until the
                // owner allows — run the owner in parallel.
                val phone = async(Dispatchers.IO) {
                    pairWithQr(client, qr!!.trim(), deviceName = "JVM 测试手机")
                }
                launch(Dispatchers.IO) {
                    delay(2_000) // let the request reach the pending queue
                    ipcConfirm(ipc!!.trim())
                }
                val outcome = phone.await()
                assertTrue("expected Joined, got $outcome", outcome is PairOutcome.Joined)
                val p = (outcome as PairOutcome.Joined).pairing
                assertTrue(p.storageDeviceName.isNotEmpty())
                assertTrue(p.daemonAddrToken.isNotEmpty())
                println("PAIR OK: joined '${p.storageDeviceName}' (daemon ${p.daemonNodeId.take(10)}…)")
            } finally {
                client.close()
            }
        }
    }
}
