package com.hawkeyexb.ppass

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundBackupResetOnUnpairTest {
    @Test
    fun disconnecting_clears_background_backup_intent_instead_of_reenabling_it() {
        val source = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        val cleanup = source.substringAfter("private fun clearLocalPairing(")
            .substringBefore("\n}")

        assertTrue(cleanup.contains("setRequested(false)"))
        assertTrue(cleanup.contains("setEnabled(false)"))
        assertFalse(cleanup.contains("setEnabled(true)"))
    }
}
