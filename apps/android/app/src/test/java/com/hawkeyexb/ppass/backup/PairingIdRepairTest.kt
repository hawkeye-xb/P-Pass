// UI-10 item 1: `AndroidFlowRuntime.runtimeFor()` returns null when
// `pairingId` is blank — the home screen then rendered plain Idle with a
// clickable-but-silently-inert Pause/Continue, no explanation (source-read
// finding, 2026-09-06). This locks down the pure decision (repair attempt vs.
// pairing-lost escalation), independent of any real network call.
package com.hawkeyexb.ppass.backup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingIdRepairTest {

    @Test
    fun blank_pairing_id_needs_repair_nonblank_does_not() {
        assertTrue(needsPairingIdRepair(""))
        assertTrue(needsPairingIdRepair("   "))
        assertFalse(needsPairingIdRepair("9d0a7a4a6b5b3e7d01cb91f4cfb4c274"))
    }

    @Test
    fun successful_hello_with_a_real_pairing_id_repairs_silently() {
        val outcome = applyPairingIdRepairOutcome(Result.success("fresh-pid-value"))
        assertEquals(PairingIdRepairResult.Repaired("fresh-pid-value"), outcome)
    }

    @Test
    fun successful_hello_with_a_blank_pairing_id_still_escalates_to_lost() {
        // Desktop answered but has nothing to offer — not a network failure,
        // but there is no pairing id to repair to either.
        assertEquals(PairingIdRepairResult.Lost, applyPairingIdRepairOutcome(Result.success(null)))
        assertEquals(PairingIdRepairResult.Lost, applyPairingIdRepairOutcome(Result.success("")))
    }

    @Test
    fun failed_hello_escalates_to_lost() {
        val outcome = applyPairingIdRepairOutcome(Result.failure(RuntimeException("unreachable")))
        assertEquals(PairingIdRepairResult.Lost, outcome)
    }

    /** #1072: an incompatible desktop (e.g. a pre-v2 one) says nothing about the pairing — no red card, retry later. */
    @Test
    fun version_mismatch_is_deferred_not_lost() {
        for (side in com.hawkeyexb.ppass.proto.OutdatedSide.entries) {
            val outcome = applyPairingIdRepairOutcome(Result.failure(com.hawkeyexb.ppass.proto.ProtocolOutdatedException(side)))
            assertEquals(PairingIdRepairResult.Deferred, outcome)
        }
    }
}
