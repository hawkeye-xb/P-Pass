package com.hawkeyexb.ppass

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.hawkeyexb.ppass.backup.BackupScopeStore
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.MediaScanner
import com.hawkeyexb.ppass.backup.ScopeRead
import com.hawkeyexb.ppass.backup.SourceAvailability
import com.hawkeyexb.ppass.backup.effectiveBackupScope
import com.hawkeyexb.ppass.backup.folder.FolderAccess
import com.hawkeyexb.ppass.backup.folder.FolderEntry
import com.hawkeyexb.ppass.backup.folder.FolderRecord
import com.hawkeyexb.ppass.backup.folder.isFolderId
import com.hawkeyexb.ppass.backup.scopeNeedsFirstChoice
import com.hawkeyexb.ppass.backup.startOfLocalDaySec
import com.hawkeyexb.ppass.transport.PairDesktopIdentity
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.ui.FolderBucketUi
import com.hawkeyexb.ppass.ui.PhotosGuide
import com.hawkeyexb.ppass.ui.selectedExistingCount
import com.hawkeyexb.ppass.update.UpdateUiState

internal sealed class PairPhase {
    data object Asking : PairPhase()
    data class Code(val code: String, val desktop: PairDesktopIdentity) : PairPhase()
}

internal sealed class Screen {
    data object Welcome : Screen()
    data object Scan : Screen()
    data object ManualPair : Screen()
    data class Waiting(val qr: String) : Screen()
    data class Trouble(
        val titleRes: Int,
        val bodyRes: Int? = null,
        val offerAppUpdate: Boolean = false,
        val errorCode: String? = null,
    ) : Screen()
    data class Home(val pairing: Pairing) : Screen()
    data class Buckets(val pairing: Pairing, val current: Set<Long>, val firstTime: Boolean) : Screen()
    data class Decision(val pairing: Pairing) : Screen()
}

internal fun launchScreen(pairing: Pairing?, onboarded: (String) -> Boolean): Screen = when {
    pairing == null -> Screen.Welcome
    onboarded(pairing.daemonNodeId) -> Screen.Home(pairing)
    else -> Screen.Decision(pairing)
}

internal class DecisionLock {
    var busy by mutableStateOf(false)
        private set
    fun tryLock(): Boolean {
        if (busy) return false
        busy = true
        return true
    }
    fun unlock() { busy = false }
}

internal fun repairScanTarget(cameraGranted: Boolean): Screen =
    if (cameraGranted) Screen.Scan else Screen.Welcome

internal fun cameraPermissionResultTarget(granted: Boolean): Screen =
    if (granted) Screen.Scan else Screen.ManualPair

internal fun screenAfterPairingCleared(screen: Screen, clearedPairingId: String): Screen {
    val shown = when (screen) {
        is Screen.Home -> screen.pairing.pairingId
        is Screen.Buckets -> screen.pairing.pairingId
        is Screen.Decision -> screen.pairing.pairingId
        else -> return screen
    }
    return if (shown == clearedPairingId) Screen.Welcome else screen
}

internal fun isOnboardingScreen(screen: Screen): Boolean =
    screen is Screen.Decision || (screen is Screen.Buckets && screen.firstTime)

internal fun runPickedEnqueue(
    uriCount: Int,
    enqueue: () -> Int,
    onSuccess: () -> Unit,
    onFailure: (Throwable?) -> Unit,
    notifyFailure: (Int) -> Unit,
): Boolean {
    if (uriCount <= 0) return false
    val added = try {
        enqueue()
    } catch (t: Throwable) {
        onFailure(t)
        notifyFailure(R.string.command_failed)
        return false
    }
    if (added <= 0) {
        onFailure(null)
        notifyFailure(R.string.command_failed)
        return false
    }
    onSuccess()
    return true
}

internal fun scopeSinceDate(sinceSec: Long?, nowMs: Long): String {
    val sec = sinceSec ?: startOfLocalDaySec(nowMs)
    val date = java.time.Instant.ofEpochSecond(sec).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
    val pattern = android.text.format.DateFormat.getBestDateTimePattern(java.util.Locale.getDefault(), "MMMd")
    return java.time.format.DateTimeFormatter.ofPattern(pattern).format(date)
}

internal fun systemBackTarget(screen: Screen): Screen? = when (screen) {
    Screen.Welcome, is Screen.Home, is Screen.Decision -> null
    Screen.Scan, Screen.ManualPair -> Screen.Welcome
    is Screen.Waiting, is Screen.Trouble -> Screen.Scan
    is Screen.Buckets -> if (screen.firstTime) Screen.Decision(screen.pairing) else Screen.Home(screen.pairing)
}

internal fun guideForCurrentScope(guide: PhotosGuide, firstChoicePending: Boolean): PhotosGuide =
    if (guide == PhotosGuide.EnableScope && !firstChoicePending) PhotosGuide.None else guide

internal enum class RuleEnableRoute { Apply, Request, Settings, ChooseScope }

internal fun ruleEnableRoute(
    access: MediaAccess,
    canPrompt: Boolean,
    scope: ScopeRead,
    folderCount: Int,
): RuleEnableRoute = when {
    scopeNeedsFirstChoice(scope, folderCount) -> RuleEnableRoute.ChooseScope
    !ruleScopeUsesAlbums(scope) -> RuleEnableRoute.Apply
    access == MediaAccess.FULL -> RuleEnableRoute.Apply
    access == MediaAccess.PARTIAL && !canPrompt -> RuleEnableRoute.Settings
    else -> RuleEnableRoute.Request
}

internal fun ruleScopeUsesAlbums(scope: ScopeRead): Boolean = when (scope) {
    ScopeRead.NeverSaved -> false
    is ScopeRead.Saved -> scope.ids.any { !isFolderId(it) }
    is ScopeRead.Unreadable -> true
}

internal fun systemCanPromptAlbumAccess(requestedOnce: Boolean, rationale: Boolean): Boolean =
    !requestedOnce || rationale

internal fun resolveFolderBucketIds(
    folderKeys: Collection<String>,
    idByUri: Map<String, String>,
    records: List<FolderRecord>,
): Set<Long> = folderKeys.mapNotNull { key ->
    val sourceId = idByUri[key] ?: key
    records.firstOrNull { it.id == sourceId }?.bucketId
}.toSet()

internal fun updateRowValueOf(context: Context, state: UpdateUiState): String? = when (state) {
    is UpdateUiState.Downloading ->
        if (state.total > 0) {
            context.getString(
                R.string.update_row_downloading,
                (state.received * 100 / state.total).toInt(),
            )
        } else {
            context.getString(R.string.update_downloading_unknown_total)
        }
    is UpdateUiState.Verifying ->
        context.getString(R.string.update_verifying)
    is UpdateUiState.ReadyToInstall ->
        context.getString(R.string.update_row_ready)
    else -> null
}

internal data class BucketScreenFolderProjection(
    val existingFolderBuckets: Set<Long>,
    val effectiveBuckets: Set<Long>?,
    val folderCards: List<FolderBucketUi>,
    val selectedFolders: Set<String>,
)

internal fun projectBucketScreenFolders(
    context: Context,
    scopeStore: BackupScopeStore,
    records: List<FolderRecord>,
    folderEntries: List<FolderEntry>,
    pendingFolderUris: List<String>,
    knownSources: Set<Long>?,
    savedSince: Long?,
): BucketScreenFolderProjection {
    val existingFolderBuckets = records.mapTo(HashSet()) { it.bucketId }
    val effective = effectiveBackupScope(
        scopeStore.scope(), knownSources, existingFolderBuckets, savedSince,
    )
    val folderCards = records.map { record ->
        val entry = folderEntries.firstOrNull { it.sourceId == record.id }
        FolderBucketUi(
            key = record.id,
            bucket = MediaScanner.Bucket(record.bucketId, record.displayName, record.items.size),
            registered = true,
            needsPermission = entry?.needsPermission == true,
        )
    } + pendingFolderUris.map { raw ->
        val name = android.net.Uri.parse(raw).lastPathSegment
            ?.substringAfterLast(':')?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
            ?: context.getString(R.string.folder_settings_title)
        FolderBucketUi(raw, MediaScanner.Bucket(0L, name, 0), registered = false)
    }
    val selectedFolders = records.filter { effective?.buckets?.contains(it.bucketId) == true }
        .mapTo(HashSet()) { it.id }
    return BucketScreenFolderProjection(
        existingFolderBuckets = existingFolderBuckets,
        effectiveBuckets = effective?.buckets,
        folderCards = folderCards,
        selectedFolders = selectedFolders,
    )
}
