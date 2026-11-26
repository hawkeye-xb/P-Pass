package com.hawkeyexb.ppass.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.BuildConfig
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.BackgroundBackupState
import com.hawkeyexb.ppass.backup.BackupTriplet
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.flow.WaitReason

sealed class BackupUiState {
    data object Idle : BackupUiState()
    data class Scanning(val found: Int) : BackupUiState()
    data class Hashing(val done: Int, val total: Int) : BackupUiState()
    data object Preparing : BackupUiState()
    data class Sending(val done: Int, val total: Int, val currentFile: String = "") : BackupUiState()
    data class AllSafe(val ingested: Int, val duplicates: Int) : BackupUiState()
    data object Paused : BackupUiState()
    data class Waiting(val reason: WaitReason) : BackupUiState()
    data object NoAlbums : BackupUiState()
    data class Trouble(val text: String) : BackupUiState()
}

@Composable
internal fun HomeScreen(
    storageName: String,
    state: BackupUiState,
    onBackupNow: () -> Unit,
    triplet: BackupTriplet? = null,
    wifiOnly: Boolean = true,
    onWifiOnlyChange: (Boolean) -> Unit = {},
    notifyOnFailure: Boolean = true,
    onNotifyOnFailureChange: (Boolean) -> Unit = {},
    autoBackupEnabled: Boolean = true,
    onToggleAutoBackup: (Boolean) -> Unit = {},
    backgroundBackupState: BackgroundBackupState = BackgroundBackupState.OffByUser,
    onResolveBackgroundBackup: () -> Unit = {},
    onDisconnect: () -> Unit = {},
    connection: ConnectionState = ConnectionState(ConnectionState.Status.Unknown),
    onRepair: () -> Unit = {},
    onStorageDetailOpenChange: (Boolean) -> Unit = {},
    pairedAt: Long = 0L,
    selectedBucketCount: Int? = null,
    selectedFolderCount: Int = 0,
    scopeUnreadable: Boolean = false,
    scopeTimeLabel: String? = null,
    countsReadable: Boolean = true,
    scopeSaved: Boolean = true,
    onOpenBucketPicker: () -> Unit = {},
    onPickPhotos: () -> Unit = {},
    pickedBatch: com.hawkeyexb.ppass.backup.picked.PickedBatchSummary? = null,
    mediaAccess: MediaAccess = MediaAccess.FULL,
    onOpenAppSettings: () -> Unit = {},
    desktopLowSpace: Boolean = false,
    commandPending: Boolean = false,
    missingSourceNotice: com.hawkeyexb.ppass.backup.flow.MissingSourceNotice? = null,
    transferProgress: Float? = null,
    transferRow: com.hawkeyexb.ppass.backup.flow.TransferRow? = null,
    cancelRemainingCount: Long? = null,
    onRequestCancelRemaining: () -> Unit = {},
    skippedCount: Long? = null,
    onRestoreSkipped: () -> Unit = {},
    cancelConfirmCount: Int? = null,
    onConfirmCancelRemaining: () -> Unit = {},
    onDismissCancelRemaining: () -> Unit = {},
    onAcknowledgeMissingSource: () -> Unit = {},
    acknowledgedMissingSourceCount: Int = 0,
    waitReasonRes: Int? = null,
    outdated: com.hawkeyexb.ppass.proto.OutdatedSide? = null,
    updateRowValue: String? = null,
    onCheckUpdate: (() -> Unit)? = null,
    autoBackupRuleOn: Boolean = true,
    scopeHasStart: Boolean = false,
    onToggleAutoBackupRule: (Boolean) -> Unit = {},
    autoBackupRuleHintRes: Int? = null,
    mediaFolders: List<FolderUi> = emptyList(),
    onFolderAdd: () -> Unit = {},
    onFolderRemove: (FolderUi) -> Unit = {},
    onFolderReauthorize: (FolderUi) -> Unit = {},
    onFoldersOpenChange: (Boolean) -> Unit = {},
    hasUsableSource: Boolean = false,
    mixedAlbumIncomplete: Boolean = false,
    hasSelectedAlbum: Boolean = true,
    onPickFiles: () -> Unit = {},
    notice: (@Composable () -> Unit)? = null,
) {
    val line = statusLineOf(state, triplet?.k ?: 0L)
    val busy = line is StatusLine.Working

    var showStorageDetail by remember { mutableStateOf(false) }
    var showMore by remember { mutableStateOf(false) }
    var showFolders by remember { mutableStateOf(false) }
    androidx.compose.runtime.LaunchedEffect(showFolders) { onFoldersOpenChange(showFolders) }
    androidx.compose.material3.ProvideTextStyle(
        androidx.compose.material3.LocalTextStyle.current.copy(fontFamily = PPFont.Sans),
    ) {
    if (showFolders) {
        FolderScreen(
            folders = mediaFolders,
            onAdd = onFolderAdd,
            onRemove = onFolderRemove,
            onReauthorize = onFolderReauthorize,
            onBack = { showFolders = false },
        )
    } else if (showStorageDetail) {
        BackHandler { showStorageDetail = false }
        StorageComputerDetail(
            storageName = storageName,
            pairedAt = pairedAt,
            confirmedCount = triplet?.m ?: 0L,
            lastSuccessAt = triplet?.lastSuccessAt ?: 0L,
            connection = connection,
            onBack = { showStorageDetail = false },
            onDisconnect = onDisconnect,
        )
    } else if (showMore) {
        BackHandler { showMore = false; onStorageDetailOpenChange(false) }
        MorePage(
            onOpenStorage = { showStorageDetail = true },
            onCheckUpdate = onCheckUpdate,
            updateRowValue = updateRowValue,
            onBack = { showMore = false; onStorageDetailOpenChange(false) },
        )
    } else {

    if (cancelConfirmCount != null) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = onDismissCancelRemaining,
            title = { Text(pluralStringResource(R.plurals.cancel_remaining_confirm_title, cancelConfirmCount, cancelConfirmCount)) },
            text = { Text(stringResource(R.string.cancel_remaining_confirm_body)) },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = onConfirmCancelRemaining) {
                    Text(pluralStringResource(R.plurals.cancel_remaining_label, cancelConfirmCount, cancelConfirmCount), color = PPColor.Act)
                }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = onDismissCancelRemaining) {
                    Text(stringResource(R.string.back), color = PPColor.Ink)
                }
            },
        )
    }

    Column(
        Modifier.fillMaxSize().background(PPColor.Paper)
            .verticalScroll(rememberScrollState())
            .padding(20.dp, 14.dp, 20.dp, 8.dp),
    ) {
        val heroBlocked = autoBackupRuleOn && mediaAccess != MediaAccess.FULL && !hasUsableSource && hasSelectedAlbum
        Surface(
            color = if (heroBlocked) PPColor.ActBg else PPColor.SafeBg,
            shape = RoundedCornerShape(PPSize.RadiusCard),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(20.dp)) {
                if (!autoBackupRuleOn) {
                    Text(stringResource(R.string.auto_backup_off_hero), color = PPColor.Ink, fontSize = 15.sp)
                } else if (mixedAlbumIncomplete) {
                    Text(stringResource(R.string.hero_mixed_album_incomplete), color = PPColor.Act, fontSize = 15.sp)
                    Spacer(Modifier.height(12.dp))
                    OutlinedButton(
                        onClick = onOpenBucketPicker,
                        modifier = Modifier.height(40.dp),
                        shape = RoundedCornerShape(14.dp),
                        border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Act.copy(alpha = 0.4f)),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = PPColor.Act),
                    ) { Text(stringResource(R.string.hero_adjust_scope_action), fontSize = 15.sp, fontWeight = FontWeight.Bold) }
                } else if (mediaAccess != MediaAccess.FULL && !hasUsableSource && hasSelectedAlbum) {
                    Text(stringResource(R.string.auto_backup_blocked_hero), color = PPColor.Ink, fontSize = 15.sp)
                    if (blockedHeroOffersSettings(autoBackupRuleOn, mediaAccess, hasSelectedAlbum)) {
                        Spacer(Modifier.height(12.dp))
                        OutlinedButton(
                            onClick = onOpenAppSettings,
                            modifier = Modifier.height(40.dp),
                            shape = RoundedCornerShape(14.dp),
                            border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Act.copy(alpha = 0.4f)),
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = PPColor.Act),
                        ) { Text(stringResource(R.string.auto_backup_blocked_action), fontSize = 15.sp, fontWeight = FontWeight.Bold) }
                    }
                } else {
                val t = triplet
                val heroRender = heroRenderOf(mediaAccess, t, countsReadable = countsReadable, scopeSaved = scopeSaved,
                    hasUsableSource = hasUsableSource, hasSelectedAlbum = hasSelectedAlbum)
                if (showsFromTodayEmpty(heroRender, t, scopeHasStart)) {
                    Text(stringResource(R.string.auto_backup_from_today_empty), color = PPColor.Ink, fontSize = 15.sp)
                } else if (heroRender == HeroRender.Triplet && t != null) {
                    val numberColor = heroNumberColor(mediaAccess, t, connection)
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(
                            groupThousands(t.m),
                            fontSize = 40.sp, fontFamily = PPFont.Serif,
                            color = numberColor,
                        )
                        Text(
                            stringResource(R.string.hero_of_n, groupThousands(t.n)),
                            fontSize = 18.sp, fontFamily = PPFont.Serif,
                            color = numberColor,
                            modifier = Modifier.padding(start = 6.dp, bottom = 4.dp),
                        )
                    }
                    Spacer(Modifier.height(6.dp))
                    val lastText = lastSuccessText(t.lastSuccessAt)
                    val pendingSuffix = if (t.k > 0) {
                        " · " + stringResource(R.string.pending_count, t.k)
                    } else ""
                    Text(
                        lastText + pendingSuffix,
                        fontSize = 14.sp, color = PPColor.Ink60,
                    )
                } else if (heroRender == HeroRender.Unreconciled) {
                    Text(
                        stringResource(R.string.hero_unreconciled_title),
                        fontSize = 16.sp, fontWeight = FontWeight.Bold, color = PPColor.Waiting,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        stringResource(R.string.hero_unreconciled_body),
                        fontSize = 14.sp, lineHeight = 21.sp, color = PPColor.Ink60,
                    )
                } else {
                    Text(
                        stringResource(
                            when (heroRender) {
                                HeroRender.CountsUnreadable -> R.string.hero_counts_unreadable
                                HeroRender.NoAlbums -> R.string.backup_scope_none
                                else -> R.string.triplet_unavailable
                            },
                        ),
                        fontSize = 15.sp, color = PPColor.Ink60,
                    )
                }
                }

                if (!autoBackupRuleOn || !heroBlocked) {
                Spacer(Modifier.height(14.dp))
                HorizontalDivider(color = PPColor.Safe.copy(alpha = 0.18f))
                Spacer(Modifier.height(12.dp))

                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        if (busy) {
                            val slots = heroBusySlotsOf(line as StatusLine.Working, transferRow, transferProgress)
                            val textMaxLines = heroBusyTextMaxLines(slots)
                            Text(
                                slots.fileNameOverride ?: workingText(line),
                                fontSize = 13.5.sp, fontWeight = FontWeight.Medium,
                                color = PPColor.Ink60,
                                maxLines = textMaxLines, softWrap = false, overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                when (slots.secondLine.kind) {
                                    HeroBusySecondLine.Kind.EMPTY -> ""
                                    HeroBusySecondLine.Kind.SLOW -> stringResource(R.string.state_sending_slow, slots.secondLine.quietSeconds)
                                    HeroBusySecondLine.Kind.DETAIL ->
                                        stringResource(R.string.state_sending_detail, slots.secondLine.bytesText!!, slots.secondLine.done, slots.secondLine.total)
                                    HeroBusySecondLine.Kind.COUNT_ONLY ->
                                        stringResource(R.string.state_sending, slots.secondLine.done, slots.secondLine.total)
                                },
                                fontSize = 13.sp,
                                color = slots.secondLineColor,
                                maxLines = textMaxLines, softWrap = false, overflow = TextOverflow.Ellipsis,
                            )
                            Spacer(Modifier.height(8.dp))
                            val progress = transferProgress
                            // 没有进度时也占住同高的槽，忙碌块换行时卡片不跳动。
                            val barHeight = heroBusyProgressSlotHeight(slots)
                            if (progress != null) {
                                // Material3 1.3 LinearProgressIndicator 默认带 gapSize=4.dp 与末端停靠圆点，必须清零才是连续直条
                                val barColor = slots.progressColor
                                androidx.compose.material3.LinearProgressIndicator(
                                    progress = { progress },
                                    modifier = Modifier.fillMaxWidth().height(barHeight),
                                    color = barColor,
                                    trackColor = barColor.copy(alpha = 0.18f),
                                    gapSize = 0.dp,
                                    drawStopIndicator = {},
                                )
                            } else {
                                Spacer(Modifier.fillMaxWidth().height(barHeight))
                            }
                        } else {
                            val waitReason = visibleOutdatedSide(outdated, mediaAccess, connection.needsRepair)?.let(::outdatedTextRes)
                                ?: visibleWaitReasonRes(
                                    state = state,
                                    mediaAccess = mediaAccess,
                                    pairingLost = connection.needsRepair,
                                    reasonRes = waitReasonRes,
                                    wifiOnly = wifiOnly,
                                    hasUsableSource = hasUsableSource,
                                    pickedOpen = (pickedBatch?.open ?: 0) > 0,
                                )
                            val allSafeAllowed = allSafeTextAllowed(
                                mediaAccess = mediaAccess,
                                triplet = triplet,
                                pairingLost = connection.needsRepair,
                                missingSourceCount = missingSourceNotice?.count ?: 0,
                            )
                            val idleLine: String? = when {
                                waitReason != null -> stringResource(waitReason)
                                !autoBackupRuleOn -> when (line) {
                                    is StatusLine.Pending -> pluralStringResource(R.plurals.state_pending, line.k.toInt(), line.k)
                                    is StatusLine.AllSafe ->
                                        if (allSafeAllowed) stringResource(R.string.state_safe) else null
                                    else -> null
                                }
                                else -> idleStatusText(
                                    line,
                                    allSafeAllowed,
                                    backgroundBackupState,
                                    wifiOnly,
                                )
                            }
                            if (idleLine != null) {
                                Text(
                                    idleLine,
                                    fontSize = 13.5.sp,
                                    color = heroIdleLineColor(waitReason = waitReason, line = line, allSafeAllowed = allSafeAllowed),
                                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                                )
                            }
                        }
                    }
                    val heroAction = heroActionOf(state, connection)
                    val outdatedNow = visibleOutdatedSide(outdated, mediaAccess, connection.needsRepair)
                    val expiredFolders = mediaFolders.filter { it.needsPermission }
                    if (outdatedNow != null && offersAppUpdate(outdatedNow) && onCheckUpdate != null) {
                        Spacer(Modifier.width(12.dp))
                        HeroSecondaryButton(label = stringResource(R.string.update_check_now), onClick = onCheckUpdate)
                    } else if (heroAction != null) {
                        Spacer(Modifier.width(12.dp))
                        HeroSecondaryButton(
                            label = when {
                                commandPending -> stringResource(R.string.backup_command_processing)
                                heroAction == HeroAction.Pause -> stringResource(R.string.backup_pause)
                                else -> stringResource(R.string.backup_resume)
                            },
                            enabled = !commandPending,
                            onClick = onBackupNow,
                        )
                    } else if (state is BackupUiState.Waiting && state.reason == WaitReason.SOURCE_UNAVAILABLE && !connection.needsRepair) {
                        Spacer(Modifier.width(12.dp))
                        HeroSecondaryButton(
                            label = stringResource(
                                if (expiredFolders.size == 1) R.string.folder_reauthorize else R.string.folder_banner_open_scope,
                            ),
                            onClick = {
                                if (expiredFolders.size == 1) onFolderReauthorize(expiredFolders.single())
                                else onOpenBucketPicker()
                            },
                        )
                    }
                }
                }
                SingleTransferStatus.heroLine(pickedBatch)?.let { picked ->
                    Spacer(Modifier.height(8.dp))
                    when (picked) {
                        is SingleTransferStatus.Line.Progress -> Text(
                            stringResource(R.string.picked_progress, picked.done, picked.total),
                            fontSize = 13.sp, color = PPColor.Ink60,
                            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                        )
                        is SingleTransferStatus.Line.Result -> {
                            val head = picked.delivered?.let { stringResource(R.string.picked_result_delivered, it) }
                            val tail = picked.failed.takeIf { it > 0 }?.let { stringResource(R.string.picked_result_failed, it) }
                            Text(
                                listOfNotNull(head, tail).joinToString(" · "),
                                fontSize = 13.sp, color = PPColor.Ink60,
                                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                            )
                        }
                    }
                }
            }
        }

        if (desktopLowSpaceHintVisible(desktopLowSpace, mediaAccess, connection.needsRepair)) {
            Spacer(Modifier.height(10.dp))
            Text(
                stringResource(R.string.desktop_low_space_hint),
                fontSize = 13.5.sp, fontWeight = FontWeight.Medium,
                color = PPColor.Waiting,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 2.dp),
            )
        }

        if (notice != null) {
            Spacer(Modifier.height(12.dp))
            notice()
        }

        if (state is BackupUiState.Trouble && !connection.needsRepair) {
            Spacer(Modifier.height(12.dp))
            Surface(
                color = PPColor.ActBg,
                shape = RoundedCornerShape(PPSize.RadiusCard),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(18.dp)) {
                    val copy = troubleTextOf(
                        rawError = state.text,
                        humanBody = stringResource(R.string.run_failed),
                    )
                    Text(
                        stringResource(R.string.state_trouble),
                        fontSize = 16.sp, fontWeight = FontWeight.Bold, color = PPColor.Act,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        copy.main,
                        fontSize = 14.sp, lineHeight = 21.sp, color = PPColor.Ink60,
                    )
                    if (copy.detail.isNotEmpty()) {
                        var showDetail by remember { mutableStateOf(false) }
                        Spacer(Modifier.height(6.dp))
                        TextButton(onClick = { showDetail = !showDetail }) {
                            Text(
                                stringResource(
                                    if (showDetail) R.string.trouble_details_hide
                                    else R.string.trouble_details_show
                                ),
                                fontSize = 13.sp, fontWeight = FontWeight.Bold,
                                color = PPColor.Ink40,
                                textDecoration = TextDecoration.Underline,
                            )
                        }
                        if (showDetail) {
                            Text(
                                copy.detail,
                                fontSize = 12.sp, lineHeight = 17.sp,
                                fontFamily = FontFamily.Monospace, color = PPColor.Ink40,
                            )
                        }
                    }
                    Spacer(Modifier.height(12.dp))
                    Button(
                        onClick = onBackupNow,
                        modifier = Modifier.fillMaxWidth().height(PPSize.TapMin),
                        shape = RoundedCornerShape(PPSize.RadiusControl),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = PPColor.Ink, contentColor = PPColor.Paper,
                        ),
                    ) {
                        Text(
                            stringResource(R.string.try_again),
                            fontSize = 17.sp, fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
        }

        if (connection.needsRepair) {
            Spacer(Modifier.height(12.dp))
            Surface(
                color = PPColor.ActBg,
                shape = RoundedCornerShape(PPSize.RadiusCard),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(18.dp)) {
                    Text(
                        stringResource(R.string.pairing_lost_title),
                        fontSize = 16.sp, fontWeight = FontWeight.Bold, color = PPColor.Act,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        stringResource(R.string.pairing_lost_body),
                        fontSize = 14.sp, lineHeight = 21.sp, color = PPColor.Ink60,
                    )
                    Spacer(Modifier.height(12.dp))
                    Button(
                        onClick = onRepair,
                        modifier = Modifier.fillMaxWidth().height(PPSize.TapMin),
                        shape = RoundedCornerShape(PPSize.RadiusControl),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = PPColor.Ink, contentColor = PPColor.Paper,
                        ),
                    ) {
                        Text(
                            stringResource(R.string.reconnect),
                            fontSize = 17.sp, fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
        }

        if (missingSourceNotice != null) {
            Spacer(Modifier.height(12.dp))
            NoticeCard(
                HomeNotice(
                    kind = HomeNoticeKind.SOURCE_MISSING,
                    body = pluralStringResource(R.plurals.missing_source_notice_body, missingSourceNotice.count, missingSourceNotice.count),
                    dismissLabel = stringResource(R.string.missing_source_notice_dismiss),
                    onDismiss = onAcknowledgeMissingSource,
                )
            )
        }
        Spacer(Modifier.height(18.dp))
        Surface(
            color = PPColor.Paper,
            shape = RoundedCornerShape(PPSize.RadiusCard),
            border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column {
                RuleSwitchRow(
                    label = stringResource(R.string.auto_backup_rule_label),
                    checked = autoBackupRuleOn,
                    onCheckedChange = onToggleAutoBackupRule,
                    hint = autoBackupRuleHintRes?.let { stringResource(it) },
                    hintColor = PPColor.Waiting,
                    heading = true,
                )
                if (autoBackupRuleOn) {
                    HorizontalDivider(color = PPColor.Divider)
                    CellRow(
                        label = stringResource(R.string.backup_scope),
                        value = if (scopeUnreadable) {
                            stringResource(R.string.backup_scope_unreadable)
                        } else {
                            run {
                                val albumCount = selectedBucketCount?.minus(selectedFolderCount) ?: 0
                                val albums = backupScopeRowCount(albumCount)?.let {
                                    pluralStringResource(R.plurals.backup_scope_n, it, it)
                                }
                                val folders = if (selectedFolderCount > 0) {
                                    pluralStringResource(R.plurals.backup_scope_folder_n, selectedFolderCount, selectedFolderCount)
                                } else null
                                val sources = listOfNotNull(albums, folders).joinToString(" · ")
                                if (sources.isEmpty()) stringResource(R.string.backup_scope_none)
                                else if (scopeTimeLabel != null) stringResource(R.string.backup_scope_with_time, sources, scopeTimeLabel)
                                else sources
                            }
                        },
                        onClick = onOpenBucketPicker,
                    )
                    HorizontalDivider(color = PPColor.Divider)
                    RuleSwitchRow(
                        label = stringResource(R.string.auto_backup_pause),
                        checked = autoBackupEnabled,
                        onCheckedChange = onToggleAutoBackup,
                        hint = if (backgroundBackupState != BackgroundBackupState.OffByUser &&
                            backgroundBackupState != BackgroundBackupState.Armed
                        ) {
                            stringResource(
                                when (backgroundBackupState) {
                                    BackgroundBackupState.NeedsSystemAuthorization ->
                                        R.string.background_backup_needs_authorization
                                    BackgroundBackupState.SystemStoppedWatcher ->
                                        R.string.background_backup_system_stopped
                                    else -> error("unreachable: OffByUser/Armed excluded above")
                                },
                            )
                        } else null,
                        hintColor = PPColor.Waiting,
                        onHintClick = onResolveBackgroundBackup,
                    )
                }
                if (cancelRemainingCount != null) {
                    HorizontalDivider(color = PPColor.Divider)
                    CellRow(
                        label = pluralStringResource(R.plurals.cancel_remaining_label, cancelRemainingCount.toInt(), cancelRemainingCount),
                        onClick = if (commandPending) null else onRequestCancelRemaining,
                    )
                }
                if (skippedCount != null) {
                    HorizontalDivider(color = PPColor.Divider)
                    CellRow(
                        label = stringResource(R.string.cancelled_round_cell_label),
                        value = stringResource(R.string.cancelled_round_cell_value, skippedCount.toInt()),
                        onClick = if (commandPending) null else onRestoreSkipped,
                    )
                }
                if (acknowledgedMissingSourceCount > 0) {
                    HorizontalDivider(color = PPColor.Divider)
                    CellRow(
                        label = stringResource(R.string.missing_source_archive_label),
                        value = stringResource(
                            R.string.missing_source_archive_value,
                            acknowledgedMissingSourceCount,
                        ),
                    )
                }
            }
        }

        Spacer(Modifier.height(18.dp))
        val photoPickerAvailable = SingleTransferFilePicker.hasDedicatedPhotoPicker(LocalContext.current)
        val selectionRows = SettingsLayout.selectionRows(photoPickerAvailable)
        Surface(
            color = PPColor.Paper,
            shape = RoundedCornerShape(PPSize.RadiusCard),
            border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column {
                selectionRows.forEachIndexed { index, entry ->
                    if (index > 0) HorizontalDivider(color = PPColor.Divider)
                    CellRow(
                        label = stringResource(entry.labelRes),
                        onClick = { entry.request(photos = onPickPhotos, files = onPickFiles) },
                        heading = entry.isHeading(photoPickerAvailable),
                    )
                }
            }
        }

        Spacer(Modifier.height(18.dp))
        Surface(
            color = PPColor.Paper,
            shape = RoundedCornerShape(PPSize.RadiusCard),
            border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column {
                RuleSwitchRow(
                    label = stringResource(R.string.setting_wifi_only),
                    checked = wifiOnly,
                    onCheckedChange = onWifiOnlyChange,
                    heading = true,
                )
                HorizontalDivider(color = PPColor.Divider)
                RuleSwitchRow(
                    label = stringResource(R.string.rule_notify),
                    checked = notifyOnFailure,
                    onCheckedChange = onNotifyOnFailureChange,
                )
                HorizontalDivider(color = PPColor.Divider)
                CellRow(
                    label = stringResource(R.string.more_label),
                    onClick = { showMore = true; onStorageDetailOpenChange(true) },
                )
            }
        }

        Spacer(Modifier.height(8.dp))
    }
    }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MorePage(
    onOpenStorage: () -> Unit,
    onCheckUpdate: (() -> Unit)?,
    updateRowValue: String?,
    onBack: () -> Unit,
) {
    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = PPColor.Paper,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        stringResource(R.string.more_label),
                        style = MaterialTheme.typography.headlineSmall.copy(fontFamily = PPFont.Serif),
                        color = PPColor.Ink,
                        modifier = Modifier.semantics { heading() },
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.back),
                            tint = PPColor.Ink,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = PPColor.Paper,
                    scrolledContainerColor = PPColor.Paper,
                    navigationIconContentColor = PPColor.Ink,
                    titleContentColor = PPColor.Ink,
                ),
            )
        },
    ) { innerPadding ->
    Column(Modifier.fillMaxSize().padding(innerPadding).padding(20.dp, 14.dp, 20.dp, 8.dp)) {
        Spacer(Modifier.height(16.dp))
        Surface(
            color = PPColor.Paper,
            shape = RoundedCornerShape(PPSize.RadiusCard),
            border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column {
                CellRow(
                    label = stringResource(R.string.storage_computer),
                    onClick = onOpenStorage,
                )
                HorizontalDivider(color = PPColor.Divider)
                val buildStamp = BuildConfig.BUILD_STAMP
                CellRow(
                    label = stringResource(R.string.setting_version),
                    value = if (buildStamp.isBlank()) {
                        "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})"
                    } else {
                        "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) $buildStamp"
                    },
                )
                if (onCheckUpdate != null) {
                    HorizontalDivider(color = PPColor.Divider)
                    CellRow(
                        label = stringResource(R.string.update_check_now),
                        value = updateRowValue,
                        onClick = onCheckUpdate,
                    )
                }
            }
        }
    }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StorageComputerDetail(
    storageName: String,
    pairedAt: Long,
    confirmedCount: Long,
    lastSuccessAt: Long,
    connection: ConnectionState,
    onBack: () -> Unit,
    onDisconnect: () -> Unit,
) {
    var armed by remember { mutableStateOf(false) }
    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = PPColor.Paper,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        stringResource(R.string.storage_computer),
                        style = MaterialTheme.typography.headlineSmall.copy(fontFamily = PPFont.Serif),
                        color = PPColor.Ink,
                        modifier = Modifier.semantics { heading() },
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.back),
                            tint = PPColor.Ink,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = PPColor.Paper,
                    scrolledContainerColor = PPColor.Paper,
                    navigationIconContentColor = PPColor.Ink,
                    titleContentColor = PPColor.Ink,
                ),
            )
        },
    ) { innerPadding ->
    Column(Modifier.fillMaxSize().padding(innerPadding).padding(20.dp, 14.dp, 20.dp, 8.dp)) {
        Spacer(Modifier.height(16.dp))
        Surface(
            color = PPColor.Paper,
            shape = RoundedCornerShape(PPSize.RadiusCard),
            border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(20.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier.size(9.dp).clip(androidx.compose.foundation.shape.CircleShape)
                            .background(storageDetailDotColor(connection.status)),
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(storageName, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink)
                }
                Spacer(Modifier.height(10.dp))
                Text(storageDetailBody(connection, lastSuccessAt, pairedAt, confirmedCount),
                    fontSize = 14.sp, lineHeight = 24.sp, color = PPColor.Ink60,
                )
            }
        }
        Spacer(Modifier.weight(1f))
        if (armed) {
            Surface(
                color = PPColor.ActBg,
                shape = RoundedCornerShape(PPSize.RadiusCard),
                border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Act),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(18.dp)) {
                    Text(
                        stringResource(R.string.disconnect_armed_title),
                        fontSize = 15.sp, fontWeight = FontWeight.Bold, color = PPColor.Act,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        stringResource(R.string.disconnect_armed_body),
                        fontSize = 13.5.sp, lineHeight = 20.sp, color = PPColor.Ink60,
                    )
                    Spacer(Modifier.height(12.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        OutlinedButton(
                            onClick = { armed = false },
                            modifier = Modifier.weight(1f).height(48.dp),
                            shape = RoundedCornerShape(14.dp),
                        ) { Text(stringResource(R.string.cancel), fontSize = 15.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink) }
                        Button(
                            onClick = onDisconnect,
                            modifier = Modifier.weight(1f).height(48.dp),
                            shape = RoundedCornerShape(14.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = PPColor.Act, contentColor = PPColor.Paper,
                            ),
                        ) { Text(stringResource(R.string.disconnect_confirm), fontSize = 15.sp, fontWeight = FontWeight.Bold) }
                    }
                }
            }
        } else {
            OutlinedButton(
                onClick = { armed = true },
                modifier = Modifier.fillMaxWidth().height(48.dp),
                shape = RoundedCornerShape(14.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Act.copy(alpha = 0.4f)),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = PPColor.Act),
            ) { Text(stringResource(R.string.disconnect), fontSize = 15.sp, fontWeight = FontWeight.Bold) }
        }
        Spacer(Modifier.height(8.dp))
    }
    }
}

internal fun storageDetailDotColor(status: ConnectionState.Status): Color = when (status) {
    ConnectionState.Status.Connected -> PPColor.Safe
    ConnectionState.Status.PairingLost -> PPColor.Act
    ConnectionState.Status.Reconnecting -> PPColor.Waiting
    ConnectionState.Status.Offline, ConnectionState.Status.Unknown -> PPColor.Idle
}

internal data class StorageDetailLines(
    val statusRes: Int,
    val statusTakesLastSuccess: Boolean,
    val showPairedLine: Boolean,
)

internal fun storageDetailLines(status: ConnectionState.Status, pairedAt: Long): StorageDetailLines = when (status) {
    ConnectionState.Status.PairingLost ->
        StorageDetailLines(R.string.storage_detail_lost, statusTakesLastSuccess = false, showPairedLine = false)
    ConnectionState.Status.Connected ->
        StorageDetailLines(R.string.storage_detail_connected, statusTakesLastSuccess = true, showPairedLine = pairedAt > 0)
    ConnectionState.Status.Reconnecting,
    ConnectionState.Status.Offline,
    ConnectionState.Status.Unknown ->
        StorageDetailLines(R.string.storage_detail_offline, statusTakesLastSuccess = true, showPairedLine = pairedAt > 0)
}

@Composable
internal fun storageDetailBody(
    connection: ConnectionState,
    lastSuccessAt: Long,
    pairedAt: Long,
    confirmedCount: Long,
): String {
    val lines = storageDetailLines(connection.status, pairedAt)
    val line1 = if (lines.statusTakesLastSuccess) {
        stringResource(lines.statusRes, lastSuccessText(lastSuccessAt))
    } else {
        stringResource(lines.statusRes)
    }
    if (!lines.showPairedLine) return line1
    val line2 = stringResource(R.string.storage_detail_paired, pairedDateText(pairedAt), groupThousands(confirmedCount))
    return "$line1\n$line2"
}

internal fun pairedDateText(pairedAt: Long, locale: java.util.Locale = java.util.Locale.getDefault()): String =
    java.text.DateFormat.getDateInstance(java.text.DateFormat.LONG, locale).format(java.util.Date(pairedAt))

@Composable
private fun workingText(line: StatusLine.Working): String = when (val s = line.state) {
    is BackupUiState.Scanning -> stringResource(R.string.state_scanning, s.found)
    is BackupUiState.Hashing -> stringResource(R.string.state_hashing, s.done, s.total)
    is BackupUiState.Preparing -> stringResource(R.string.state_preparing)
    is BackupUiState.Sending -> if (s.currentFile.isNotEmpty()) {
        stringResource(R.string.state_sending_file, s.currentFile, s.done, s.total)
    } else {
        stringResource(R.string.state_sending, s.done, s.total)
    }
    else -> stringResource(R.string.idle_auto_hint)
}

@Composable
private fun idleStatusText(
    line: StatusLine,
    allSafeAllowed: Boolean,
    backgroundBackupState: BackgroundBackupState,
    wifiOnly: Boolean,
): String = when (line) {
    is StatusLine.NoAlbums -> stringResource(R.string.backup_scope_none)
    is StatusLine.Pending -> pluralStringResource(R.plurals.state_pending, line.k.toInt(), line.k)
    is StatusLine.AllSafe ->
        if (allSafeAllowed) stringResource(R.string.state_safe)
        else stringResource(idleHintRes(backgroundBackupState, wifiOnly))
    is StatusLine.Ready -> stringResource(idleHintRes(backgroundBackupState, wifiOnly))
    is StatusLine.Waiting -> stringResource(R.string.backup_waiting_constraints)
    is StatusLine.Paused -> stringResource(R.string.state_paused)
    is StatusLine.Working, is StatusLine.Trouble -> stringResource(R.string.idle_auto_hint)
}

@Composable
private fun HeroSecondaryButton(label: String, onClick: () -> Unit, enabled: Boolean = true) {
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.height(44.dp),
        shape = RoundedCornerShape(14.dp),
        border = androidx.compose.foundation.BorderStroke(
            1.dp,
            if (enabled) PPColor.BorderStrong else PPColor.BorderStrong.copy(alpha = 0.5f),
        ),
        colors = ButtonDefaults.outlinedButtonColors(
            containerColor = PPColor.Paper,
            contentColor = PPColor.Ink,
            disabledContentColor = PPColor.Ink40,
        ),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 18.dp),
    ) {
        Text(label, fontSize = 15.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun lastSuccessText(ts: Long): String =
    when (val last = lastSuccessOf(ts, System.currentTimeMillis())) {
        is LastSuccess.Never -> stringResource(R.string.last_success_never)
        is LastSuccess.JustNow ->
            stringResource(R.string.dog_last_success, stringResource(R.string.last_just_now))
        is LastSuccess.MinutesAgo -> stringResource(
            R.string.dog_last_success, stringResource(R.string.last_mins_ago, last.mins)
        )
        is LastSuccess.HoursAgo -> stringResource(
            R.string.dog_last_success, stringResource(R.string.last_hours_ago, last.hours)
        )
        is LastSuccess.At -> stringResource(
            R.string.dog_last_success,
            java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.getDefault())
                .format(java.util.Date(last.ts)),
        )
    }

internal fun groupThousands(n: Long): String =
    java.text.NumberFormat.getIntegerInstance().format(n)

private val CellRowHeight = 52.dp

@Composable
private fun RuleSwitchRow(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    hint: String? = null,
    hintColor: Color = PPColor.Ink40,
    onHintClick: (() -> Unit)? = null,
    heading: Boolean = false,
) {
    val spec = ruleSwitchRowSpec(hasHintAction = onHintClick != null)
    ListItem(
        headlineContent = { Text(label, fontSize = 15.sp, color = PPColor.Ink) },
        supportingContent = if (hint != null) {
            {
                Text(
                    hint,
                    fontSize = 12.sp, lineHeight = 17.sp, color = hintColor,
                    modifier = if (onHintClick != null) {
                        Modifier.clickable(role = spec.hintRole, onClick = onHintClick)
                    } else {
                        Modifier
                    },
                )
            }
        } else {
            null
        },
        trailingContent = {
            Switch(
                checked = checked,
                onCheckedChange = if (spec.switchInteractive) onCheckedChange else null,
                colors = SwitchDefaults.colors(
                    checkedTrackColor = PPColor.Safe,
                    checkedThumbColor = PPColor.Paper,
                    checkedBorderColor = PPColor.Safe,
                ),
            )
        },
        colors = ListItemDefaults.colors(
            containerColor = Color.Transparent,
            headlineColor = PPColor.Ink,
            supportingColor = hintColor,
        ),
        modifier = Modifier.fillMaxWidth()
            .let { if (heading) it.semantics { heading() } else it }
            .toggleable(
                value = checked,
                onValueChange = onCheckedChange,
                role = spec.rowRole,
            )
            .heightIn(min = CellRowHeight),
    )
}

internal fun cellRowStacks(
    labelWidthPx: Int,
    valueWidthPx: Int,
    availableWidthPx: Int,
    trailingWidthPx: Int,
): Boolean = labelWidthPx + valueWidthPx + trailingWidthPx > availableWidthPx

@Composable
internal fun CellRow(label: String, value: String? = null, onClick: (() -> Unit)? = null, heading: Boolean = false) {
    val measurer = rememberTextMeasurer()
    val clickable = onClick != null
    val labelStyle = LocalTextStyle.current.copy(fontSize = 15.sp)
    val valueStyle = LocalTextStyle.current.copy(fontSize = 14.sp)
    val chevronStyle = LocalTextStyle.current.copy(fontSize = 16.sp)
    val gapPx = with(LocalDensity.current) { 4.dp.roundToPx() }
    // ListItem 自己给左右各 16dp 内边距，尾部内容前再留 8dp：判定按真实可用宽算，避免长文案被裁。
    val horizontalPaddingPx = with(LocalDensity.current) { 32.dp.roundToPx() }
    val trailingPaddingPx = with(LocalDensity.current) { 8.dp.roundToPx() }
    BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterStart) {
        val available = constraints.maxWidth - horizontalPaddingPx -
            if (value != null || clickable) trailingPaddingPx else 0
        val stacked = remember(label, value, available, clickable, measurer, labelStyle, valueStyle, chevronStyle) {
            if (value == null) {
                false
            } else {
                val labelWidth = measurer.measure(AnnotatedString(label), labelStyle).size.width
                val valueWidth = measurer.measure(AnnotatedString(value), valueStyle).size.width
                val trailing = if (clickable) {
                    measurer.measure(AnnotatedString("›"), chevronStyle).size.width + gapPx
                } else {
                    0
                }
                cellRowStacks(labelWidth, valueWidth, available, trailing)
            }
        }
        ListItem(
            headlineContent = { Text(label, fontSize = 15.sp, color = PPColor.Ink) },
            supportingContent = if (stacked) {
                { Text(value!!, fontSize = 14.sp, color = PPColor.Ink40) }
            } else {
                null
            },
            trailingContent = if (!stacked && value == null && !clickable) {
                null
            } else {
                {
                    if (stacked) {
                        if (clickable) Text("›", fontSize = 16.sp, color = PPColor.Ink40)
                    } else {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            if (value != null) Text(value, fontSize = 14.sp, color = PPColor.Ink40)
                            if (clickable) Spacer(Modifier.width(4.dp))
                            if (clickable) Text("›", fontSize = 16.sp, color = PPColor.Ink40)
                        }
                    }
                }
            },
            colors = ListItemDefaults.colors(
                containerColor = Color.Transparent,
                headlineColor = PPColor.Ink,
                supportingColor = PPColor.Ink40,
                trailingIconColor = PPColor.Ink40,
            ),
            modifier = Modifier.fillMaxWidth()
                .let { if (heading) it.semantics { heading() } else it }
                .let { if (onClick != null) it.clickable(role = Role.Button, onClick = onClick) else it }
                .heightIn(min = CellRowHeight),
        )
    }
}
