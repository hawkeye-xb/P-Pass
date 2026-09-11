package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Scope changes are an explicit foreground action. They must not depend on a
 * previously enqueued CATCHUP WorkManager request, because KEEP preserves that
 * request's old network constraint after the user changes settings.
 */
class MOB72ScopeWakeWiringTest {
    @Test
    fun savingExpandedScopeUsesTheCurrentRuntimeWakeInsteadOfOnlyKeepScheduledCatchup() {
        val source = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        val start = source.indexOf("if (added.isNotEmpty())")
        val end = source.indexOf("screen = Screen.Home(s.pairing)", start)
        val saveScope = source.substring(start, end)

        assertTrue(
            "scope expansion must backfill and wake the current runtime in one background path",
            saveScope.contains("requestFlowScopeBackfillAndWake(context, constraintsSatisfied)"),
        )
        assertFalse(
            "a direct scope wake must replace the old split backfill-plus-KEEP-only path",
            saveScope.contains("requestFlowScopeBackfill(context)"),
        )
    }
}
