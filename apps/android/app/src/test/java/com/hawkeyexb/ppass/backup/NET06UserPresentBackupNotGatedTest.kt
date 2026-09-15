// NET-06: `triggerUserPresentBackup` fires because a human is looking at the
// screen right now (scope confirm, app foreground) — it must run even when
// the *background* auto-backup switch is off. Before this fix it silently
// no-op'd whenever the user had chosen "暂不开启" for background backup,
// which looked to a real user like "I selected an album and nothing
// happened" (found during the NET-06 real-device regression, 2026-09-15;
// this is a MOB-65 regression, unrelated to the offer/poll rewrite itself).
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class NET06UserPresentBackupNotGatedTest {
    @Test
    fun user_present_backup_is_not_gated_by_the_automatic_backup_switch() {
        val source = File("src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt").readText()
        val fnBody = source.substringAfter("fun triggerUserPresentBackup(context: Context)")
            .substringBefore("\n\nfun triggerManualBackup")
        assertTrue(
            "confirming a scope while a human is present must not be silenced by the " +
                "background auto-backup switch — pass automatic=false",
            fnBody.contains("automatic = false"),
        )
    }
}
