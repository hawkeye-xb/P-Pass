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

/**
 * @param producerEnabled `AutoBackupPrefs.enabled()`——生产者此刻是否真的开着。#540：意图在、白名单在、
 * 生产者却停着时，旧写法只看中断标志，算出 Armed（「自动进行」），而 JobScheduler 里 0 个任务。
 * 故意不给默认值：每个调用方都得接上真相源。
 */
fun backgroundBackupStateOf(
    userEnabled: Boolean,
    systemWhitelisted: Boolean,
    producerEnabled: Boolean,
    watcherScheduled: Boolean,
    watcherInterrupted: Boolean,
): BackgroundBackupState = when {
    !userEnabled -> BackgroundBackupState.OffByUser
    !systemWhitelisted -> BackgroundBackupState.NeedsSystemAuthorization
    !producerEnabled || watcherInterrupted || !watcherScheduled -> BackgroundBackupState.SystemStoppedWatcher
    else -> BackgroundBackupState.Armed
}
