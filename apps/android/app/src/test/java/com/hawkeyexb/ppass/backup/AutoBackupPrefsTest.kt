// UX-06: AutoBackupPrefs — pause-state persistence. tmp+rename is
// crash-safe; corrupt file falls back to defaults (not paused).
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
    fun defaults_to_not_paused() {
        assertFalse(AutoBackupPrefs(tmp.root).paused())
    }

    @Test
    fun set_paused_persists_and_loads_back() {
        val prefs = AutoBackupPrefs(tmp.root)
        prefs.setPaused(true)
        assertTrue(AutoBackupPrefs(tmp.root).paused())
        prefs.setPaused(false)
        assertFalse(AutoBackupPrefs(tmp.root).paused())
    }

    @Test
    fun corrupt_file_falls_back_to_not_paused() {
        File(tmp.root, "auto_backup_prefs.json").writeText("{not json!!")
        assertFalse(AutoBackupPrefs(tmp.root).paused())
    }

    @Test
    fun no_tmp_file_left_behind_after_save() {
        val prefs = AutoBackupPrefs(tmp.root)
        prefs.setPaused(true)
        assertFalse(File(tmp.root, "auto_backup_prefs.json.tmp").exists())
        assertTrue(File(tmp.root, "auto_backup_prefs.json").isFile)
    }

    @Test
    fun json_is_valid_kotlinx_serialization() {
        val prefs = AutoBackupPrefs(tmp.root)
        prefs.setPaused(true)
        val raw = File(tmp.root, "auto_backup_prefs.json").readText()
        assertEquals("""{"paused":true}""", raw)
    }
}
