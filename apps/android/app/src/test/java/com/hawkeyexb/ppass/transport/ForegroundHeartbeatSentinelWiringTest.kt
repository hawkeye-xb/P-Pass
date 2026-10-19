// UI-10 item 4: SentinelStore had recordReachable but zero production
// callers anywhere in the app — the home/photos "失联 N 天" field was frozen
// dead data (source-read finding, 2026-09-06). The ForegroundHeartbeat's 30s
// hello was the only connectivity signal actually running; this locks down
// that its outcome now reaches the store.
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.backup.SentinelStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ForegroundHeartbeatSentinelWiringTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-ui10-heartbeat-$case").toFile()

    @Test
    fun successful_heartbeat_records_reachable() {
        val dir = tempDir("success")
        val store = SentinelStore(dir)

        applyHeartbeatOutcome(store, Result.success(Unit))

        assertTrue("a successful beat must record a fresh lastReachableAt", store.load().lastReachableAt > 0)
    }

    @Test
    fun failed_heartbeat_does_not_touch_reachable_at() {
        val dir = tempDir("failure")
        val store = SentinelStore(dir)
        store.recordReachable(1_000L)

        applyHeartbeatOutcome(store, Result.failure<Unit>(RuntimeException("unreachable")))

        assertEquals(
            "a failed beat must not advance the last-known-reachable timestamp",
            1_000L,
            store.load().lastReachableAt,
        )
    }

    @Test
    fun null_sentinel_is_a_no_op_and_never_throws() {
        // Regression guard: any call site that hasn't been updated to pass a
        // SentinelStore (default constructor arg) must not crash the heartbeat.
        applyHeartbeatOutcome(null, Result.success(Unit))
        applyHeartbeatOutcome(null, Result.failure<Unit>(RuntimeException("x")))
    }
}
