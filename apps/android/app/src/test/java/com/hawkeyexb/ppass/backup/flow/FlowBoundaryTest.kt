package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FlowBoundaryTest {
    private fun repoRoot(): File {
        var dir = File(checkNotNull(System.getProperty("user.dir")) { "user.dir unavailable" })
        while (!File(dir, "apps/android").isDirectory) {
            dir = checkNotNull(dir.parentFile) { "apps/android not found" }
        }
        return dir
    }

    @Test
    fun flow_sources_are_physically_namespaced_and_do_not_reference_legacy_batch_apis() {
        val flowRoot = File(
            repoRoot(),
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow",
        )
        val sources = flowRoot.walkTopDown().filter { it.extension == "kt" }.toList()
        assertTrue("REBUILD-00 requires Flow sources", sources.isNotEmpty())

        val legacyApis = listOf(
            "BackupWorker",
            "BackupRunner",
            "ConfirmedStore",
            "ReuploadQueue",
            "WatermarkStore",
        )
        sources.forEach { source ->
            val code = source.readText()
            assertTrue("${source.name} must declare the Flow package", code.contains("package com.hawkeyexb.ppass.backup.flow"))
            legacyApis.forEach { api ->
                assertFalse(
                    "${source.name} must not import or fully qualify legacy $api",
                    code.contains("com.hawkeyexb.ppass.backup.$api"),
                )
            }
        }
    }

    @Test
    fun legacy_entrypoints_are_explicitly_marked_frozen() {
        val backupRoot = File(repoRoot(), "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup")
        for (name in listOf("BackupRunner.kt", "ConfirmedStore.kt", "ReuploadQueue.kt")) {
            assertTrue(
                "$name must retain the REBUILD-00 legacy marker",
                File(backupRoot, name).readText().contains("LEGACY"),
            )
        }
    }

    @Test
    fun process_flow_wake_is_not_blocked_behind_legacy_watch_reconciliation() {
        val app = File(repoRoot(), "apps/android/app/src/main/java/com/hawkeyexb/ppass/PPassApplication.kt").readText()
        val backgroundWake = app.substringAfter("thread(name = \"ppass-boot-check\") {")
        val flowWake = backgroundWake.indexOf("requestFlowWake(this)")
        val legacyReconcile = backgroundWake.indexOf("reconcileWatchOnProcessStart(")

        assertTrue("process Flow wake must precede legacy watch reconciliation", flowWake in 0 until legacyReconcile)
        assertTrue("legacy reconciliation failure must not kill the Flow process", backgroundWake.contains("runCatching {"))
    }
}
