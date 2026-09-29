package com.hawkeyexb.ppass.backup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class BackgroundBackupStateTest {
    @Test
    fun user_who_never_enabled_background_backup_sees_it_off() {
        assertEquals(
            BackgroundBackupState.OffByUser,
            backgroundBackupStateOf(
                userEnabled = false,
                systemWhitelisted = true,
                producerEnabled = true,
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
                producerEnabled = true,
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
                producerEnabled = true,
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
                producerEnabled = true,
                watcherScheduled = false,
                watcherInterrupted = false,
            ),
        )
        assertEquals(
            BackgroundBackupState.SystemStoppedWatcher,
            backgroundBackupStateOf(
                userEnabled = true,
                systemWhitelisted = true,
                producerEnabled = true,
                watcherScheduled = true,
                watcherInterrupted = true,
            ),
        )
    }

    /**
     * #540：白名单在 App 外加回之后，意图在、白名单在、中断标志没立——但生产者还停在挂起态。
     * 旧写法（不看生产者）算出 Armed，设置页写「插电 + Wi-Fi 时自动进行」，JobScheduler 里 0 个任务。
     */
    @Test
    fun suspended_producers_are_never_presented_as_armed() {
        val state = backgroundBackupStateOf(
            userEnabled = true,
            systemWhitelisted = true,
            producerEnabled = false,
            watcherScheduled = true,
            watcherInterrupted = false,
        )
        assertNotEquals("挂起期间不许显示「自动进行」", BackgroundBackupState.Armed, state)
        assertEquals(BackgroundBackupState.SystemStoppedWatcher, state)
    }
}
