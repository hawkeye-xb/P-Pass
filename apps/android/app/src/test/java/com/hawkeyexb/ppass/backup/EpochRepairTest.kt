// UI-10 item 1: `AndroidFlowRuntime.runtimeFor()` returns null when
// `pairingEpoch` is blank — the home screen then rendered plain Idle with a
// clickable-but-silently-inert Pause/Continue, no explanation (source-read
// finding, 2026-09-06). This locks down the pure decision (repair attempt vs.
// pairing-lost escalation), independent of any real network call.
package com.hawkeyexb.ppass.backup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EpochRepairTest {

    @Test
    fun blank_epoch_needs_repair_nonblank_does_not() {
        assertTrue(needsEpochRepair(""))
        assertTrue(needsEpochRepair("   "))
        assertFalse(needsEpochRepair("9d0a7a4a6b5b3e7d01cb91f4cfb4c274"))
    }

    @Test
    fun successful_hello_with_a_real_epoch_repairs_silently() {
        val outcome = applyEpochRepairOutcome(Result.success("fresh-epoch-value"))
        assertEquals(EpochRepairResult.Repaired("fresh-epoch-value"), outcome)
    }

    @Test
    fun successful_hello_with_a_blank_epoch_still_escalates_to_lost() {
        // Desktop answered but has nothing to offer — not a network failure,
        // but there is no epoch to repair to either.
        assertEquals(EpochRepairResult.Lost, applyEpochRepairOutcome(Result.success(null)))
        assertEquals(EpochRepairResult.Lost, applyEpochRepairOutcome(Result.success("")))
    }

    @Test
    fun failed_hello_escalates_to_lost() {
        val outcome = applyEpochRepairOutcome(Result.failure(RuntimeException("unreachable")))
        assertEquals(EpochRepairResult.Lost, outcome)
    }
}
