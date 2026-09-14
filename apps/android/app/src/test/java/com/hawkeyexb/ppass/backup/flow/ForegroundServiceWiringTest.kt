// NET-12: source assertion guarding the *wiring*, not just the pure
// decision. `foregroundActionFor` (FlowUiProjection.kt) is already fully
// JVM-tested by ForegroundServiceDecisionTest, but a pure function nobody
// calls protects nothing — this is the regression guard for the actual
// call site, in the same spirit as ForegroundSyncNotFrozenTest.
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class ForegroundServiceWiringTest {

    private fun codeOf(file: File): String =
        file.readText()
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .lines()
            .filterNot { it.trimStart().startsWith("//") }
            .joinToString("\n")

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return dir
    }

    @Test
    fun every_flush_audit_outbox_call_site_syncs_the_transfer_foreground_service() {
        val runtime = codeOf(
            File(
                repoRoot(),
                "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidFlowRuntime.kt",
            ),
        )
        val callSites = runtime.lines()
            .withIndex()
            .filter { (_, l) -> l.contains("flushAuditOutbox(") && !l.contains("fun flushAuditOutbox") }
        assertTrue("源码锚点已消失：找不到任何 flushAuditOutbox 调用", callSites.isNotEmpty())

        // Every Flow trigger reaches flushAuditOutbox as its shared
        // postcondition (wake/pause/continue/retry/cancel/restore/receipt/
        // failure) — that single point must sync the foreground service,
        // or a live transfer goes right back to zero protection (NET-12
        // regression: real device killed twice on 2026-09-14 from exactly
        // this gap).
        val syncCallCount = runtime.split("FlowTransferForeground.sync(").size - 1
        assertTrue(
            "flushAuditOutbox 必须调用 FlowTransferForeground.sync(...) 同步前台服务——" +
                "少了它，传输期间又会回到 NET-12 之前那种毫无保护的状态",
            syncCallCount >= 1,
        )
    }
}
