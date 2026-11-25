package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.BackgroundBackupState

enum class HomeNoticeKind {
    PAIRING_LOST,
    BACKUP_INTERRUPTED,
    PARTIAL_ACCESS,
    SOURCE_MISSING,
    LOCATION_REDACTED,
    ENABLE_BACKGROUND_BACKUP,
}

val HOME_NOTICE_PRIORITY: List<HomeNoticeKind> = listOf(
    HomeNoticeKind.PAIRING_LOST,
    HomeNoticeKind.BACKUP_INTERRUPTED,
    HomeNoticeKind.PARTIAL_ACCESS,
    HomeNoticeKind.LOCATION_REDACTED,
    HomeNoticeKind.SOURCE_MISSING,
    HomeNoticeKind.ENABLE_BACKGROUND_BACKUP,
)

data class HomeNotice(
    val kind: HomeNoticeKind,
    val body: String,
    val actionLabel: String? = null,
    val onAction: () -> Unit = {},
    val critical: Boolean = false,
    val dismissLabel: String? = null,
    val onDismiss: () -> Unit = {},
    val closeLabel: String? = null,
    val onClose: () -> Unit = {},
)

fun topNotice(notices: List<HomeNotice>): HomeNotice? =
    notices.minByOrNull { n ->
        HOME_NOTICE_PRIORITY.indexOf(n.kind).let { if (it < 0) Int.MAX_VALUE else it }
    }

@Composable
fun NoticeCard(notice: HomeNotice) {
    val bg = if (notice.critical) PPColor.ActBg else PPColor.WaitingBg
    val bodyColor = if (notice.critical) PPColor.Act else PPColor.Ink60
    if (notice.closeLabel != null) {
        ClosableNoticeCard(notice.body, notice.actionLabel, notice.onAction, notice.closeLabel, notice.onClose, notice.critical)
        return
    }
    Surface(
        color = bg,
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            Modifier.padding(16.dp, 13.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                notice.body,
                fontSize = 13.5.sp, lineHeight = 20.sp, color = bodyColor,
                modifier = Modifier.weight(1f).semantics { liveRegion = LiveRegionMode.Polite },
            )
            if (notice.dismissLabel != null) {
                TextButton(onClick = notice.onDismiss) {
                    Text(
                        notice.dismissLabel,
                        fontSize = 13.sp, fontWeight = FontWeight.Medium, color = PPColor.Ink40,
                    )
                }
            }
            if (notice.actionLabel != null) {
                TextButton(onClick = notice.onAction) {
                    Text(
                        notice.actionLabel,
                        fontSize = 14.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink,
                        textDecoration = TextDecoration.Underline,
                    )
                }
            }
        }
    }
}

@Composable
fun ClosableNoticeCard(
    body: String,
    actionLabel: String?,
    onAction: () -> Unit,
    closeLabel: String,
    onClose: () -> Unit,
    critical: Boolean = false,
) {
    val bg = if (critical) PPColor.ActBg else PPColor.WaitingBg
    val bodyColor = if (critical) PPColor.Act else PPColor.Ink60
    Surface(color = bg, shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(start = 16.dp, top = 2.dp, bottom = 2.dp),
        ) {
            Text(
                body,
                fontSize = 13.5.sp, lineHeight = 20.sp, color = bodyColor,
                modifier = Modifier.weight(1f).padding(vertical = 10.dp).semantics { liveRegion = LiveRegionMode.Polite },
            )
            if (actionLabel != null) {
                TextButton(onClick = onAction) {
                    Text(
                        actionLabel,
                        fontSize = 14.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink,
                        textDecoration = TextDecoration.Underline,
                    )
                }
            }
            IconButton(onClick = onClose) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription = closeLabel,
                    tint = PPColor.Ink40,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}

@Composable
fun NoticeHost(
    backgroundBackupState: BackgroundBackupState = BackgroundBackupState.OffByUser,
    onResolveBackgroundBackup: () -> Unit = {},
    locationRedacted: Boolean = false,
    onAllowLocation: () -> Unit = {},
) {
    val candidates = buildList {
        val backgroundRes = backgroundBackupNoticeRes(backgroundBackupState)
        if (backgroundRes != null) add(
            HomeNotice(
                kind = HomeNoticeKind.BACKUP_INTERRUPTED,
                body = stringResource(backgroundRes.first),
                actionLabel = stringResource(backgroundRes.second),
                onAction = onResolveBackgroundBackup,
            )
        )
        if (locationRedacted) add(
            HomeNotice(
                kind = HomeNoticeKind.LOCATION_REDACTED,
                body = stringResource(R.string.location_redacted_notice),
                actionLabel = stringResource(R.string.location_redacted_notice_action),
                onAction = onAllowLocation,
            )
        )
    }
    topNotice(candidates)?.let { NoticeCard(it) }
}

internal fun backgroundBackupNoticeRes(state: BackgroundBackupState): Pair<Int, Int>? = when (state) {
    BackgroundBackupState.NeedsSystemAuthorization ->
        R.string.background_backup_needs_authorization to R.string.background_backup_action_allow
    BackgroundBackupState.SystemStoppedWatcher ->
        R.string.background_backup_system_stopped to R.string.background_backup_action_turn_on
    else -> null
}
