// T-054 acceptance: the ENTIRE phone backup pipeline against a live
// daemon — pair, then scan(fake photos) → manifest → push → commit,
// then run again and assert idempotent zero-work convergence.
// Needs PPF_DAEMON_QR + PPF_DAEMON_IPC; `just android-backup` drives it.
package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.PairOutcome
import com.hawkeyexb.ppass.transport.pairWithQr
import com.hawkeyexb.ppass.transport.parsePairingQr
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DaemonBackupTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun ipcConfirm(ipcTokenFile: String) {
        val script = """
import socket, json, sys
lines = open(sys.argv[1]).read().splitlines()
name = lines[0].strip()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
# ipc.rs uses interprocess GenericNamespaced: Linux = abstract namespace
# (connect "\0"+name), macOS = /tmp/<name> file.
if sys.platform == 'linux':
    s.connect('\0' + name)
else:
    s.connect('/tmp/' + name)
f = s.makefile('rw')
f.write(lines[1].strip() + '\n'); f.flush()
f.write(json.dumps({'id':'t','method':'pairing.confirm','params':{'accept':True}}) + '\n'); f.flush()
resp = json.loads(f.readline())
assert resp.get('ok'), resp
print('confirmed')
"""
        val proc = ProcessBuilder("python3", "-c", script, ipcTokenFile)
            .redirectErrorStream(true).start()
        val out = proc.inputStream.bufferedReader().readText()
        check(proc.waitFor() == 0 && out.contains("confirmed")) { "IPC confirm failed: $out" }
    }

    private fun fakePhoto(i: Int): File {
        val f = tmp.newFile("IMG_%04d.jpg".format(i))
        // Deterministic per-index content, non-trivial size.
        val data = ByteArray(200_000 + i) { b -> ((b * 31 + i * 7) and 0xFF).toByte() }
        f.writeBytes(data)
        return f
    }

    @Test
    fun fullBackupPipelineAgainstLiveDaemon() {
        val qr = System.getenv("PPF_DAEMON_QR")
        val ipc = System.getenv("PPF_DAEMON_IPC")
        assumeTrue(
            "PPF_DAEMON_QR / PPF_DAEMON_IPC not set — skipping live backup test",
            !qr.isNullOrBlank() && !ipc.isNullOrBlank(),
        )

        runBlocking {
            val client = DaemonClient()
            client.bind()
            try {
                // Pair first (owner auto-allows through IPC).
                val paired = async(Dispatchers.IO) {
                    pairWithQr(client, qr!!.trim(), deviceName = "JVM 备份手机")
                }
                launch(Dispatchers.IO) { delay(2_000); ipcConfirm(ipc!!.trim()) }
                val outcome = paired.await()
                assertTrue("pair: $outcome", outcome is PairOutcome.Joined)

                val daemon = parsePairingQr(qr!!.trim()).addr!!
                val files = (1..12).map { fakePhoto(it) }
                val candidates = files.map { f ->
                    Candidate(
                        hash = blake3Hex(f.inputStream()),
                        fileName = f.name,
                        mediaType = "image/jpeg",
                        bytes = f.length(),
                        open = { f.inputStream() },
                    )
                }

                val runner = BackupRunner(client)
                val first = runner.run(daemon, candidates, generation = 100)
                assertEquals("all 12 pushed", 12, first.pushed)
                assertEquals("all 12 ingested", 12, first.ingested)

                // Idempotent rerun: nothing missing, nothing pushed.
                val second = runner.run(daemon, candidates, generation = 100)
                assertEquals("rerun pushes nothing", 0, second.pushed)
                assertEquals("rerun ingests nothing", 0, second.ingested)
                assertEquals("rerun sees 12 duplicates", 12, second.duplicates)

                println(
                    "BACKUP OK: pushed=${first.pushed} ingested=${first.ingested}; " +
                        "rerun pushed=${second.pushed} dup=${second.duplicates}"
                )
            } finally {
                client.close()
            }
        }
    }
}
