package com.hawkeyexb.ppass.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.BackgroundBackupState
import com.hawkeyexb.ppass.backup.BackupTriplet
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.flow.TransferPace
import com.hawkeyexb.ppass.backup.flow.TransferRow
import com.hawkeyexb.ppass.backup.flow.WaitReason

sealed class StatusLine {
    data object Ready : StatusLine()
    data class Working(val state: BackupUiState) : StatusLine()
    data class Pending(val k: Long) : StatusLine()
    data object AllSafe : StatusLine()
    data object NoAlbums : StatusLine()
    data object Trouble : StatusLine()
    data object Waiting : StatusLine()
    data object Paused : StatusLine()
}

fun statusLineOf(state: BackupUiState, pendingK: Long): StatusLine = when (state) {
    is BackupUiState.Trouble -> StatusLine.Trouble
    is BackupUiState.Scanning,
    is BackupUiState.Hashing,
    is BackupUiState.Preparing,
    is BackupUiState.Sending,
    -> StatusLine.Working(state)
    is BackupUiState.NoAlbums -> StatusLine.NoAlbums
    is BackupUiState.Waiting -> StatusLine.Waiting
    is BackupUiState.Paused -> StatusLine.Paused
    is BackupUiState.Idle,
    is BackupUiState.AllSafe,
    -> when {
        pendingK > 0 -> StatusLine.Pending(pendingK)
        state is BackupUiState.AllSafe -> StatusLine.AllSafe
        else -> StatusLine.Ready
    }
}

enum class HeroAction { Pause, Resume }

fun heroActionOf(state: BackupUiState, pairingLost: Boolean): HeroAction? = when {
    pairingLost -> null
    isBackupRunning(state) -> HeroAction.Pause
    state is BackupUiState.Paused -> HeroAction.Resume
    else -> null
}

internal fun heroActionOf(state: BackupUiState, connection: ConnectionState): HeroAction? =
    heroActionOf(state, connection.needsRepair)

fun isBackupRunning(state: BackupUiState): Boolean =
    state is BackupUiState.Scanning ||
        state is BackupUiState.Hashing ||
        state is BackupUiState.Preparing ||
        state is BackupUiState.Sending

enum class HeroRender {
    AccessBlocked,
    CountsUnreadable,
    NoAlbums,
    Unreadable,
    Unreconciled,
    Triplet,
}

enum class HeroSurfaceTone {
    Act,
    Waiting,
    Neutral,
    Safe,
}

internal fun backupScopeRowCount(selectedBucketCount: Int?): Int? = selectedBucketCount?.takeIf { it > 0 }

internal fun selectedExistingCount(selected: Set<Long>?, existing: Set<Long>?): Int? = when {
    selected == null -> null
    existing == null -> selected.size
    else -> selected.count { it in existing }
}

fun heroRenderOf(
    mediaAccess: MediaAccess,
    triplet: BackupTriplet?,
    countsReadable: Boolean = true,
    scopeSaved: Boolean = true,
    hasUsableSource: Boolean = false,
    hasSelectedAlbum: Boolean = true,
): HeroRender = when {
    mediaAccess != MediaAccess.FULL && !hasUsableSource && hasSelectedAlbum -> HeroRender.AccessBlocked
    !countsReadable -> HeroRender.CountsUnreadable
    triplet == null -> if (scopeSaved) HeroRender.Unreadable else HeroRender.NoAlbums
    triplet.confirmedRaw > triplet.n -> HeroRender.Unreconciled
    else -> HeroRender.Triplet
}

fun heroNumberIsSafe(
    mediaAccess: MediaAccess,
    triplet: BackupTriplet?,
    pairingLost: Boolean,
): Boolean =
    mediaAccess == MediaAccess.FULL &&
        triplet != null &&
        !pairingLost &&
        !triplet.hasFailedNeedsUser &&
        !triplet.pausedByUser

internal fun heroNumberColor(
    mediaAccess: MediaAccess,
    triplet: BackupTriplet?,
    connection: ConnectionState,
): Color = if (heroNumberIsSafe(mediaAccess, triplet, connection.needsRepair)) PPColor.Safe else PPColor.Ink

internal data class HeroBusySecondLine(
    val kind: Kind,
    val quietSeconds: Int = 0,
    val bytesText: String? = null,
    val done: Int = 0,
    val total: Int = 0,
) {
    enum class Kind { EMPTY, SLOW, DETAIL, COUNT_ONLY }
}

internal data class HeroBusySlots(
    val fileNameOverride: String?,
    val secondLine: HeroBusySecondLine,
    val secondLineColor: Color,
    val progress: Float?,
    val progressColor: Color,
    /** 忙碌块的两行文字是否都钉成单行（超出省略），避免文件名把卡片撑高。 */
    val singleLine: Boolean = true,
    /** 进度槽高度；没有进度可画时也按这个高度占位，忙碌块换行时卡片不跳动。 */
    val progressSlotHeightDp: Int = 6,
)

/** 英雄区底部进度槽最小高度，避免忙碌态与空闲态切换时卡片整体跳动。 */
internal const val HERO_PROGRESS_ROW_MIN_HEIGHT_DP = 56

/** 忙碌块文字的 maxLines：单行模式下超出省略。 */
internal fun heroBusyTextMaxLines(slots: HeroBusySlots): Int = if (slots.singleLine) 1 else Int.MAX_VALUE

/** 进度条与占位槽共用的高度，保证两种状态占同样的位置。 */
internal fun heroBusyProgressSlotHeight(slots: HeroBusySlots): Dp = slots.progressSlotHeightDp.dp

internal fun heroBusySlotsOf(
    line: StatusLine.Working,
    transferRow: TransferRow?,
    transferProgress: Float?,
): HeroBusySlots {
    val sending = line.state as? BackupUiState.Sending
    val row = transferRow?.takeIf { sending != null }
    val slow = row?.pace == TransferPace.SLOW
    val secondLine = when {
        row == null || sending == null -> HeroBusySecondLine(HeroBusySecondLine.Kind.EMPTY)
        slow -> HeroBusySecondLine(HeroBusySecondLine.Kind.SLOW, quietSeconds = row.quietSeconds)
        row.bytesText != null -> HeroBusySecondLine(
            HeroBusySecondLine.Kind.DETAIL,
            bytesText = row.bytesText,
            done = sending.done,
            total = sending.total,
        )
        else -> HeroBusySecondLine(HeroBusySecondLine.Kind.COUNT_ONLY, done = sending.done, total = sending.total)
    }
    return HeroBusySlots(
        fileNameOverride = row?.fileName,
        secondLine = secondLine,
        secondLineColor = if (slow) PPColor.Waiting else PPColor.Ink60,
        progress = transferProgress,
        progressColor = if (slow) PPColor.Waiting else PPColor.Safe,
    )
}

internal data class RuleSwitchRowSpec(
    val rowRole: Role = Role.Switch,
    val switchInteractive: Boolean = false,
    val hintRole: Role? = null,
)

internal fun ruleSwitchRowSpec(hasHintAction: Boolean): RuleSwitchRowSpec =
    RuleSwitchRowSpec(
        rowRole = Role.Switch,
        switchInteractive = false,
        hintRole = if (hasHintAction) Role.Button else null,
    )

fun allSafeTextAllowed(
    mediaAccess: MediaAccess,
    triplet: BackupTriplet?,
    pairingLost: Boolean,
    missingSourceCount: Int,
): Boolean =
    heroNumberIsSafe(mediaAccess, triplet, pairingLost) &&
        heroRenderOf(mediaAccess, triplet) != HeroRender.Unreconciled &&
        missingSourceCount == 0 &&
        (triplet?.skippedByUser ?: 0L) == 0L

internal fun heroIdleLineColor(waitReason: Int?, line: StatusLine, allSafeAllowed: Boolean): Color =
    when {
        waitReason != null -> PPColor.Waiting
        line is StatusLine.AllSafe && allSafeAllowed -> PPColor.Safe
        else -> PPColor.Ink60
    }

internal fun heroSurfaceTone(
    autoRule: Boolean,
    render: HeroRender,
    mixedAlbumIncomplete: Boolean,
    state: BackupUiState,
    triplet: BackupTriplet?,
    fromTodayEmpty: Boolean,
    allSafeAllowed: Boolean,
    hasWaitReason: Boolean = false,
): HeroSurfaceTone {
    if (!autoRule) return HeroSurfaceTone.Neutral
    if (render == HeroRender.AccessBlocked || mixedAlbumIncomplete) return HeroSurfaceTone.Act
    if (render == HeroRender.NoAlbums) return HeroSurfaceTone.Neutral
    if (
        render == HeroRender.Unreconciled ||
        isBackupRunning(state) ||
        state is BackupUiState.Paused ||
        state is BackupUiState.Waiting ||
        hasWaitReason ||
        (triplet?.k ?: 0L) > 0L
    ) {
        return HeroSurfaceTone.Waiting
    }
    if (render == HeroRender.CountsUnreadable || render == HeroRender.Unreadable || fromTodayEmpty) {
        return HeroSurfaceTone.Neutral
    }
    if (state is BackupUiState.Trouble || state is BackupUiState.NoAlbums) {
        return HeroSurfaceTone.Neutral
    }
    val hasConfirmedOrAllSafe =
        state is BackupUiState.AllSafe || ((triplet?.n ?: 0L) > 0L && (triplet?.m ?: 0L) > 0L)
    return if (allSafeAllowed && hasConfirmedOrAllSafe) HeroSurfaceTone.Safe else HeroSurfaceTone.Neutral
}

internal fun heroSurfaceBackground(tone: HeroSurfaceTone): Color = when (tone) {
    HeroSurfaceTone.Act -> PPColor.ActBg
    HeroSurfaceTone.Waiting -> PPColor.WaitingBg
    HeroSurfaceTone.Neutral -> PPColor.Linen
    HeroSurfaceTone.Safe -> PPColor.SafeBg
}

internal fun heroSurfaceDivider(tone: HeroSurfaceTone): Color = when (tone) {
    HeroSurfaceTone.Act -> PPColor.Act.copy(alpha = 0.18f)
    HeroSurfaceTone.Waiting -> PPColor.Waiting.copy(alpha = 0.18f)
    HeroSurfaceTone.Neutral -> PPColor.Hairline
    HeroSurfaceTone.Safe -> PPColor.Safe.copy(alpha = 0.18f)
}

internal fun showsFromTodayEmpty(
    render: HeroRender,
    triplet: BackupTriplet?,
    scopeHasStart: Boolean,
): Boolean = render == HeroRender.Triplet && triplet != null && triplet.n == 0L && triplet.m == 0L && scopeHasStart

fun visibleWaitReasonRes(
    state: BackupUiState,
    mediaAccess: MediaAccess,
    pairingLost: Boolean,
    reasonRes: Int?,
    wifiOnly: Boolean = true,
    hasUsableSource: Boolean = false,
    pickedOpen: Boolean = false,
): Int? {
    if (mediaAccess != MediaAccess.FULL && !hasUsableSource && !pickedOpen) return null
    if (pairingLost) return null
    if (state !is BackupUiState.Waiting) return null
    if (state.reason == WaitReason.WIFI && !wifiOnly) return R.string.backup_waiting_constraints
    return reasonRes
}

fun desktopLowSpaceHintVisible(lowSpace: Boolean, mediaAccess: MediaAccess, pairingLost: Boolean): Boolean =
    lowSpace && mediaAccess == MediaAccess.FULL && !pairingLost

internal fun idleHintRes(backgroundBackupState: BackgroundBackupState, wifiOnly: Boolean): Int = when (backgroundBackupState) {
    BackgroundBackupState.NeedsSystemAuthorization -> R.string.background_backup_needs_authorization
    BackgroundBackupState.SystemStoppedWatcher -> R.string.background_backup_system_stopped
    BackgroundBackupState.Armed, BackgroundBackupState.OffByUser ->
        if (wifiOnly) R.string.idle_auto_hint else R.string.idle_auto_hint_any_network
}

internal fun blockedHeroOffersSettings(ruleOn: Boolean, access: MediaAccess, hasSelectedAlbum: Boolean = true): Boolean =
    ruleOn && access != MediaAccess.FULL && hasSelectedAlbum

sealed class LastSuccess {
    data object Never : LastSuccess()
    data object JustNow : LastSuccess()
    data class MinutesAgo(val mins: Long) : LastSuccess()
    data class HoursAgo(val hours: Long) : LastSuccess()
    data class At(val ts: Long) : LastSuccess()
}

fun lastSuccessOf(ts: Long, now: Long): LastSuccess {
    if (ts <= 0L) return LastSuccess.Never
    val mins = (now - ts) / 60_000
    return when {
        mins < 1 -> LastSuccess.JustNow
        mins < 60 -> LastSuccess.MinutesAgo(mins)
        mins < 60 * 24 -> LastSuccess.HoursAgo(mins / 60)
        else -> LastSuccess.At(ts)
    }
}

data class TroubleText(val main: String, val detail: String)

fun troubleTextOf(rawError: String, humanBody: String): TroubleText =
    TroubleText(main = humanBody, detail = rawError.trim())

enum class TimelineFilter { All, LocalOnly, Family }

fun <T> filterTimeline(
    items: List<T>,
    filter: TimelineFilter,
    mine: Set<String>,
    hashOf: (T) -> String,
): List<T> = when (filter) {
    TimelineFilter.All -> items
    TimelineFilter.LocalOnly -> items.filter { hashOf(it) in mine }
    TimelineFilter.Family -> items.filter { hashOf(it) !in mine }
}
