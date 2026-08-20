// T-054 REAL-DEVICE acceptance: runs ON the phone, speaks to the real
// resident daemon on the Mac over the real network. Full pipeline:
// pair (owner auto-allows via IPC on the Mac side) → push fake photos
// → commit → idempotent rerun. Driven by tools/device-backup.sh.
package com.hawkeyexb.ppass

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.hawkeyexb.ppass.backup.BackupRunner
import com.hawkeyexb.ppass.backup.Candidate
import com.hawkeyexb.ppass.backup.blake3Hex
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.PairOutcome
import com.hawkeyexb.ppass.transport.pairWithQr
import com.hawkeyexb.ppass.transport.parsePairingQr
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DeviceBackupTest {

    @Test
    fun fullPipelineOnRealDeviceAgainstResidentDaemon() {
        val args = InstrumentationRegistry.getArguments()
        val qr = args.getString("qr")
        assumeTrue("no -e qr argument — skipping", !qr.isNullOrBlank())

        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val dir = ctx.filesDir

        runBlocking {
            val client = DaemonClient()
            client.bind(IdentityStore(dir).secretKey())
            try {
                // E2E-02: 见 DaemonHelloTest——新码只带 r=。
                val daemon = addrOf(parsePairingQr(qr!!.trim()))
                // Already paired (persistent identity)? backup.begin is
                // member-gated — an ok means we're in, skip pairing.
                val already = runCatching {
                    client.call(
                        daemon,
                        com.hawkeyexb.ppass.proto.Methods.BACKUP_BEGIN,
                        kotlinx.serialization.json.buildJsonObject {},
                    )
                }.getOrNull()?.ok == true
                if (!already) {
                    // Pair; the daemon side auto-allows through its IPC.
                    val outcome = pairWithQr(client, qr.trim(), deviceName = "三星S24自动验证")
                    assertTrue("pair: $outcome", outcome is PairOutcome.Joined)
                }
                val files = (1..8).map { i ->
                    File(dir, "AUTO_%02d.jpg".format(i)).also { f ->
                        f.writeBytes(ByteArray(300_000 + i) { b ->
                            ((b * 17 + i * 131) and 0xFF).toByte()
                        })
                    }
                }
                val candidates = files.map { f ->
                    Candidate(
                        hash = f.inputStream().use { blake3Hex(it) },
                        fileName = f.name,
                        mediaType = "image/jpeg",
                        bytes = f.length(),
                        open = { f.inputStream() },
                    )
                }

                val runner = BackupRunner(client)
                val first = runner.run(daemon, candidates, generation = null)
                assertEquals("all pushed", 8, first.pushed)
                assertEquals("all ingested", 8, first.ingested)

                val second = runner.run(daemon, candidates, generation = null)
                assertEquals("idempotent rerun", 0, second.pushed)
                assertEquals("rerun dups", 8, second.duplicates)

                println("DEVICE BACKUP OK: ingested=${first.ingested} rerun_dup=${second.duplicates}")
            } finally {
                client.close()
            }
        }
    }
}
