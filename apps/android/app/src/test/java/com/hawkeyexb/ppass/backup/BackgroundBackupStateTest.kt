package com.hawkeyexb.ppass.backup

import org.junit.Assert.assertEquals
import org.junit.Test

class BackgroundBackupStateTest {
    @Test
    fun user_who_never_enabled_background_backup_sees_it_off() {
        assertEquals(
            BackgroundBackupState.OffByUser,
            backgroundBackupStateOf(
                userEnabled = false,
                systemWhitelisted = true,
                watcherScheduled = true,
                watcherInterrupted = false,
            ),
        )
    }

    @Test
    fun enabling_without_system_authorization_requires_authorization_not_a_fake_on_switch() {
        assertEquals(
            BackgroundBackupState.NeedsSystemAuthorization,
            backgroundBackupStateOf(
                userEnabled = true,
                systemWhitelisted = false,
                watcherScheduled = false,
                watcherInterrupted = false,
            ),
        )
    }

    @Test
    fun granted_authorization_and_a_scheduled_watcher_make_background_backup_armed() {
        assertEquals(
            BackgroundBackupState.Armed,
            backgroundBackupStateOf(
                userEnabled = true,
                systemWhitelisted = true,
                watcherScheduled = true,
                watcherInterrupted = false,
            ),
        )
    }

    @Test
    fun a_missing_or_interrupted_watcher_is_not_presented_as_enabled() {
        assertEquals(
            BackgroundBackupState.SystemStoppedWatcher,
            backgroundBackupStateOf(
                userEnabled = true,
                systemWhitelisted = true,
                watcherScheduled = false,
                watcherInterrupted = false,
            ),
        )
        assertEquals(
            BackgroundBackupState.SystemStoppedWatcher,
            backgroundBackupStateOf(
                userEnabled = true,
                systemWhitelisted = true,
                watcherScheduled = true,
                watcherInterrupted = true,
            ),
        )
    }
}
