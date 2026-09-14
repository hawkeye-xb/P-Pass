package com.hawkeyexb.ppass.backup

/**
 * The user-visible background-backup truth. The stored policy is intentionally
 * not enough: Android permission and the watcher health are separate facts.
 */
sealed interface BackgroundBackupState {
    data object OffByUser : BackgroundBackupState
    data object NeedsSystemAuthorization : BackgroundBackupState
    data object Armed : BackgroundBackupState
    data object SystemStoppedWatcher : BackgroundBackupState
}

fun backgroundBackupStateOf(
    userEnabled: Boolean,
    systemWhitelisted: Boolean,
    watcherScheduled: Boolean,
    watcherInterrupted: Boolean,
): BackgroundBackupState = when {
    !userEnabled -> BackgroundBackupState.OffByUser
    !systemWhitelisted -> BackgroundBackupState.NeedsSystemAuthorization
    watcherInterrupted || !watcherScheduled -> BackgroundBackupState.SystemStoppedWatcher
    else -> BackgroundBackupState.Armed
}
