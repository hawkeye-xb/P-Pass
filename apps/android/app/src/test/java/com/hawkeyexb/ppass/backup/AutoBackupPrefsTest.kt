// MOB-65: The setting owns only whether automatic wakes are allowed. It is
// deliberately not the durable "current round paused" Flow state.
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AutoBackupPrefsTest {

    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun defaults_to_automatic_backup_enabled() {
        assertTrue(AutoBackupPrefs(tmp.root).enabled())
    }

    @Test
    fun enabled_value_persists_and_loads_back() {
        val prefs = AutoBackupPrefs(tmp.root)
        prefs.setEnabled(false)
        assertFalse(AutoBackupPrefs(tmp.root).enabled())
        prefs.setEnabled(true)
        assertTrue(AutoBackupPrefs(tmp.root).enabled())
    }

    @Test
    fun legacy_paused_value_migrates_to_the_inverse_enabled_value() {
        File(tmp.root, "auto_backup_prefs.json").writeText("""{"paused":true}""")
        assertFalse(AutoBackupPrefs(tmp.root).enabled())

        File(tmp.root, "auto_backup_prefs.json").writeText("""{"paused":false}""")
        assertTrue(AutoBackupPrefs(tmp.root).enabled())
    }

    @Test
    fun corrupt_file_falls_back_to_automatic_backup_enabled() {
        File(tmp.root, "auto_backup_prefs.json").writeText("{not json!!")
        assertTrue(AutoBackupPrefs(tmp.root).enabled())
    }

    @Test
    fun no_tmp_file_left_behind_after_save() {
        val prefs = AutoBackupPrefs(tmp.root)
        prefs.setEnabled(false)
        assertFalse(File(tmp.root, "auto_backup_prefs.json.tmp").exists())
        assertTrue(File(tmp.root, "auto_backup_prefs.json").isFile)
    }

    @Test
    fun json_is_valid_kotlinx_serialization() {
        val prefs = AutoBackupPrefs(tmp.root)
        prefs.setEnabled(false)
        val raw = File(tmp.root, "auto_backup_prefs.json").readText()
        assertEquals("""{"autoEnabled":false}""", raw)
    }

    @Test
    fun disabling_automatic_backup_cancels_only_automatic_work_names() {
        val cancelled = autoBackupWorkNames()

        assertEquals(
            setOf(
                BACKUP_WORK_NAME,
                CATCHUP_WORK_NAME,
                PROCESS_CATCHUP_WORK_NAME,
                MEDIA_WATCH_BACKUP_WORK_NAME,
            ),
            cancelled.toSet(),
        )
        assertFalse("an explicit user request is not automatic work", cancelled.contains(MANUAL_BACKUP_WORK_NAME))
    }

    @Test
    fun disabling_automatic_backup_never_turns_into_a_current_round_pause() {
        val source = File("src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt").readText()
        val disableBody = source.substringAfter("fun disableAutoBackup(context: Context)")
            .substringBefore("/** Re-enables normal automatic producers")

        assertTrue("the switch must persist the automatic policy", disableBody.contains("setEnabled(false)"))
        assertTrue("the switch must cancel only its automatic producers", disableBody.contains("autoBackupWorkNames()"))
        assertFalse("automatic policy is not a user pause", disableBody.contains("pauseFlow("))
        assertFalse("automatic policy is not a user resume", disableBody.contains("continueFlow("))
        assertFalse("automatic policy must not cancel a manual request", disableBody.contains(MANUAL_BACKUP_WORK_NAME))
    }
}
