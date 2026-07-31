// Test-fixture: pair this device with the daemon in the -e qr argument
// and PERSIST the pairing into the app's own files dir — the UI app
// then opens already-connected. Owner side auto-allows via IPC.
package com.hawkeyexb.ppass

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.PairOutcome
import com.hawkeyexb.ppass.transport.PairingStore
import com.hawkeyexb.ppass.transport.pairWithQr
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SetupPairingTest {
    @Test
    fun pairAndPersist() {
        val qr = InstrumentationRegistry.getArguments().getString("qr")
        assumeTrue(!qr.isNullOrBlank())
        val dir = InstrumentationRegistry.getInstrumentation().targetContext.filesDir
        runBlocking {
            val client = DaemonClient()
            client.bind(IdentityStore(dir).secretKey())
            try {
                val outcome = pairWithQr(client, qr!!.trim(), deviceName = "SM-S9210")
                assertTrue("pair: $outcome", outcome is PairOutcome.Joined)
                PairingStore(dir).save((outcome as PairOutcome.Joined).pairing)
                println("PAIRING PERSISTED: ${outcome.pairing.storageDeviceName}")
            } finally {
                client.close()
            }
        }
    }
}
