package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** UI state polling may read a ledger but must never bootstrap a native runtime. */
class MOB62SnapshotReadOnlyTest {
    @Test
    fun snapshotReadPathDoesNotCallRuntimeFor() {
        val source = File("src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidFlowRuntime.kt").readText()
        val start = source.indexOf("internal fun flowLedgerSnapshot")
        val end = source.indexOf("/**", start + 1).let { if (it < 0) source.length else it }
        val body = source.substring(start, end)

        assertFalse(
            "UI snapshot must not lazily create a native runtime",
            body.contains("runtimeFor("),
        )
        assertTrue(
            "snapshot must read an existing runtime or durable ledger without native setup",
            body.contains("flowRuntimes") || body.contains("DiscoveryLedgerStore"),
        )
    }
}
