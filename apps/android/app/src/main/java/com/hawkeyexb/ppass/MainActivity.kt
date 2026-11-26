package com.hawkeyexb.ppass

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.work.WorkManager
import com.hawkeyexb.ppass.backup.AutoBackupPrefs
import com.hawkeyexb.ppass.backup.BackgroundBackupState
import com.hawkeyexb.ppass.backup.BackupHealthPrefs
import com.hawkeyexb.ppass.backup.BackupScopeStore
import com.hawkeyexb.ppass.backup.BackupSettings
import com.hawkeyexb.ppass.backup.BackupUiStateHolder
import com.hawkeyexb.ppass.backup.DisconnectRuntime
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.MediaScanner
import com.hawkeyexb.ppass.backup.OnboardedDesktopsStore
import com.hawkeyexb.ppass.backup.ScopeRead
import com.hawkeyexb.ppass.backup.SettingsWriter
import com.hawkeyexb.ppass.backup.applyDisconnectManifest
import com.hawkeyexb.ppass.backup.backgroundBackupStateOf
import com.hawkeyexb.ppass.backup.disableAutoBackup
import com.hawkeyexb.ppass.backup.enableAutoBackup
import com.hawkeyexb.ppass.backup.flow.AndroidMediaImporter
import com.hawkeyexb.ppass.backup.flow.TriggerReason
import com.hawkeyexb.ppass.backup.flow.clearFlowRuntime
import com.hawkeyexb.ppass.backup.flow.isOnUnmetered
import com.hawkeyexb.ppass.backup.flow.requestFlowScopeBackfillAndWake
import com.hawkeyexb.ppass.backup.flow.requestFlowWake
import com.hawkeyexb.ppass.backup.flow.requestFlowWakeAfterRepair
import com.hawkeyexb.ppass.backup.initialScopeTime
import com.hawkeyexb.ppass.backup.initialSelection
import com.hawkeyexb.ppass.backup.isKnownDesktop
import com.hawkeyexb.ppass.backup.rescheduleAutoBackup
import com.hawkeyexb.ppass.backup.restoreAutoBackupAfterAuthorizationReturned
import com.hawkeyexb.ppass.backup.restoreAutoBackupAfterRepair
import com.hawkeyexb.ppass.backup.resumeAfterInterruption
import com.hawkeyexb.ppass.backup.savePairingOrError
import com.hawkeyexb.ppass.backup.scheduleAutoBackup
import com.hawkeyexb.ppass.backup.sinceToSave
import com.hawkeyexb.ppass.backup.sinceWidened
import com.hawkeyexb.ppass.backup.suspendAutoBackupUntilAuthorized
import com.hawkeyexb.ppass.backup.triggerUserPresentBackup
import com.hawkeyexb.ppass.backup.unregisteredStatePaths
import com.hawkeyexb.ppass.battery.AndroidBackgroundAuthorizationAdapter
import com.hawkeyexb.ppass.log.PLog
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.ForegroundHeartbeat
import com.hawkeyexb.ppass.transport.PairFailure
import com.hawkeyexb.ppass.transport.PairOutcome
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.PairingStore
import com.hawkeyexb.ppass.transport.ProtocolVersionGate
import com.hawkeyexb.ppass.transport.bindThenPair
import com.hawkeyexb.ppass.transport.disconnectAndNotifyInBackground
import com.hawkeyexb.ppass.transport.pairWithQr
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import com.hawkeyexb.ppass.transport.sendUnpairNoticeOnce
import com.hawkeyexb.ppass.ui.BucketScreen
import com.hawkeyexb.ppass.ui.DecisionScreen
import com.hawkeyexb.ppass.ui.FolderUi
import com.hawkeyexb.ppass.ui.GuideFacts
import com.hawkeyexb.ppass.ui.HomeScreen
import com.hawkeyexb.ppass.ui.IdentityGate
import com.hawkeyexb.ppass.ui.LoaderTimelineChannel
import com.hawkeyexb.ppass.ui.NoticeHost
import com.hawkeyexb.ppass.ui.PPColor
import com.hawkeyexb.ppass.ui.PPSize
import com.hawkeyexb.ppass.ui.PPTheme
import com.hawkeyexb.ppass.ui.PairCodeScreen
import com.hawkeyexb.ppass.ui.PairStatusScreen
import com.hawkeyexb.ppass.ui.PhotosGuide
import com.hawkeyexb.ppass.ui.PhotosScreen
import com.hawkeyexb.ppass.ui.ScanScreen
import com.hawkeyexb.ppass.ui.TimelineLoader
import com.hawkeyexb.ppass.ui.TimelineSubscriptionHolder
import com.hawkeyexb.ppass.ui.TwoTabs
import com.hawkeyexb.ppass.ui.UpdateDialog
import com.hawkeyexb.ppass.ui.WelcomeScreen
import com.hawkeyexb.ppass.ui.evictPhotoPreviews
import com.hawkeyexb.ppass.ui.offersAppUpdate
import com.hawkeyexb.ppass.ui.outdatedTextRes
import com.hawkeyexb.ppass.ui.pairRefusalDetailRes
import com.hawkeyexb.ppass.ui.pairRefusalErrorCode
import com.hawkeyexb.ppass.ui.pairRefusalTitleRes
import com.hawkeyexb.ppass.ui.photosGuideOf
import com.hawkeyexb.ppass.ui.scopeEmptyHintShown
import com.hawkeyexb.ppass.ui.selectedExistingCount
import com.hawkeyexb.ppass.ui.twoTabsBackground
import com.hawkeyexb.ppass.update.UpdateUiController
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal fun scopeSinceOptionLabel(context: Context, sinceSec: Long?, nowMs: Long = System.currentTimeMillis()): String =
    context.getString(R.string.scope_time_since_date, scopeSinceDate(sinceSec, nowMs))

internal fun scopeValueLabel(context: Context, sinceSec: Long?, nowMs: Long = System.currentTimeMillis()): String =
    if (sinceSec == null) {
        ""
    } else {
        context.getString(R.string.scope_value_since, scopeSinceDate(sinceSec, nowMs))
    }

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { PPTheme { IdentityGate((application as PPassApplication).identity) { PPassApp() } } }
    }
}

@Composable
fun PPassApp() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }
    var pickedBatch by remember { mutableStateOf<com.hawkeyexb.ppass.backup.picked.PickedBatchSummary?>(null) }
    val pickPhotosLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(com.hawkeyexb.ppass.backup.picked.PickedUploads.MAX_PICK),
    ) { uris ->
        scope.launch(Dispatchers.IO) {
            runPickedEnqueue(
                uriCount = uris.size,
                enqueue = { com.hawkeyexb.ppass.backup.picked.PickedUploads.enqueue(context, uris) },
                onSuccess = {
                    val store = com.hawkeyexb.ppass.backup.picked.PickedUploads.store(context)
                    store.clearSettled()
                    pickedBatch = com.hawkeyexb.ppass.backup.picked.PickedUploads.store(context).summary()
                    com.hawkeyexb.ppass.backup.flow.requestFlowWake(context, com.hawkeyexb.ppass.backup.flow.TriggerReason.PICKED_ADDED)
                },
                onFailure = { err -> PLog.w("PPassFlow", "picked: enqueue failed", err) },
                notifyFailure = { resId -> scope.launch { snackbarHostState.showSnackbar(context.getString(resId)) } },
            )
        }
    }
    val filePickLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val uris = if (result.resultCode == android.app.Activity.RESULT_OK) {
            com.hawkeyexb.ppass.ui.SingleTransferFilePicker.urisFromResult(result.data)
        } else emptyList()
        scope.launch(Dispatchers.IO) {
            runPickedEnqueue(
                uriCount = uris.size,
                enqueue = { com.hawkeyexb.ppass.backup.picked.PickedUploads.enqueue(context, uris) },
                onSuccess = {
                    val store = com.hawkeyexb.ppass.backup.picked.PickedUploads.store(context)
                    store.clearSettled()
                    pickedBatch = com.hawkeyexb.ppass.backup.picked.PickedUploads.store(context).summary()
                    com.hawkeyexb.ppass.backup.flow.requestFlowWake(context, com.hawkeyexb.ppass.backup.flow.TriggerReason.PICKED_ADDED)
                },
                onFailure = { err -> PLog.w("PPassFlow", "picked: file enqueue failed", err) },
                notifyFailure = { resId -> scope.launch { snackbarHostState.showSnackbar(context.getString(resId)) } },
            )
        }
    }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        while (true) {
            pickedBatch = withContext(Dispatchers.IO) { runCatching { com.hawkeyexb.ppass.backup.picked.PickedUploads.store(context).summary() }.getOrNull() }
            kotlinx.coroutines.delay(1000)
        }
    }
    val settingsWriter = remember {
        SettingsWriter { res -> scope.launch { snackbarHostState.showSnackbar(context.getString(res)) } }
    }
    val app = context.applicationContext as PPassApplication
    val identity = app.identity
    val pairings = remember { PairingStore(context.filesDir) }
    val client = remember { app.daemonClient }

    var screen by remember {
        mutableStateOf(launchScreen(pairings.load(), OnboardedDesktopsStore(context.filesDir)::wasOnboarded))
    }
    val removedNotice = remember { com.hawkeyexb.ppass.backup.PairingRemovedNoticeStore(context.filesDir) }
    fun removedNoticeDue(): Boolean {
        if (!removedNotice.pending()) return false
        if (pairings.load() != null) {
            removedNotice.clear()
            return false
        }
        return true
    }
    var showRemovedNotice by remember { mutableStateOf(removedNoticeDue()) }
    LaunchedEffect(Unit) {
        app.pairingRejectionCleanup.clearedPairingId.collect { cleared ->
            if (cleared != null) {
                screen = screenAfterPairingCleared(screen, cleared)
                showRemovedNotice = removedNoticeDue()
            }
        }
    }
    var ruleHintRes by remember { mutableStateOf<Int?>(null) }
    var mediaAccess by remember { mutableStateOf(mediaAccess(context)) }
    var albumAccessCanPrompt by remember { mutableStateOf(canPromptForFullMediaAccess(context)) }
    var mediaLocation by remember { mutableStateOf(AndroidMediaImporter.canReadMediaLocation(context)) }
    val locationPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        mediaLocation = AndroidMediaImporter.canReadMediaLocation(context)
        val activity = context as? android.app.Activity
        if (!granted && activity != null &&
            !activity.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_MEDIA_LOCATION)
        ) openAppDetailsSettings(context)
    }
    var resumeCount by remember { mutableStateOf(0) }
    var tab by remember { mutableStateOf(0) }
    var backupInterrupted by remember {
        mutableStateOf(BackupHealthPrefs(context.filesDir).load().interruptedUnacknowledged)
    }
    val foregroundCatchup = {
        if (pairings.load() != null) {
            if (AutoBackupPrefs(context.filesDir).enabled()) {
                if (!backupInterrupted) scheduleAutoBackup(context)
            }
            triggerUserPresentBackup(context)
        }
    }
    LaunchedEffect(backupInterrupted) { foregroundCatchup() }

    val cameraPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted -> screen = cameraPermissionResultTarget(granted) }

    val bucketAlbumPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { _ ->
        mediaAccess = mediaAccess(context)
        mediaLocation = AndroidMediaImporter.canReadMediaLocation(context)
        albumAccessCanPrompt = canPromptForFullMediaAccess(context)
        PLog.i("PPassFlow", "scope: photo access after prompt=$mediaAccess")
    }
    val launchAlbumAccessPrompt: (androidx.activity.result.ActivityResultLauncher<Array<String>>, Array<String>) -> Unit =
        { launcher, permissions ->
            launcher.launch(permissions)
            com.hawkeyexb.ppass.backup.AlbumAccessPromptPrefs(context).markRequested()
        }

    val updateController = remember {
        UpdateUiController(context, scope, BuildConfig.VERSION_NAME)
    }
    val updateState by updateController.state.collectAsState()
    val updateDialogSuppressed by updateController.dialogSuppressed.collectAsState()
    LaunchedEffect(Unit) { updateController.onColdStart() }
    LaunchedEffect(Unit) {
        updateController.notices.collect { notice ->
            snackbarHostState.showSnackbar(
                if (notice.arg != null) {
                    context.getString(notice.textRes, notice.arg)
                } else {
                    context.getString(notice.textRes)
                },
            )
        }
    }
    if (!isOnboardingScreen(screen) && !updateDialogSuppressed) {
        UpdateDialog(
            state = updateState,
            onConfirmDownload = updateController::onUserConfirmDownload,
            onLater = updateController::onUserLater,
            onRetry = updateController::onUserRetry,
            onDismissFailed = updateController::onUserDismissFailed,
            onInstall = updateController::onUserInstall,
            onReopenInstall = updateController::onReopenInstall,
            onGiveUpInstall = updateController::onGiveUpInstall,
        )
    }

    if (showRemovedNotice) {
        val acknowledge = {
            removedNotice.clear()
            showRemovedNotice = false
        }
        AlertDialog(
            onDismissRequest = acknowledge,
            title = { Text(stringResource(R.string.pairing_lost_title)) },
            text = { Text(stringResource(R.string.pairing_lost_body)) },
            confirmButton = {
                TextButton(onClick = acknowledge) { Text(stringResource(R.string.notice_dismiss_label)) }
            },
        )
    }

    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    val backgroundAuthorization = remember { AndroidBackgroundAuthorizationAdapter(context) }
    var batteryWhitelisted by remember { mutableStateOf(backgroundAuthorization.isGranted()) }

    fun computeDaysUnreachable(): Int? {
        val last = com.hawkeyexb.ppass.backup.SentinelStore(context.filesDir).load().lastReachableAt
        if (last <= 0) return null
        return ((System.currentTimeMillis() - last) / (24 * 60 * 60 * 1000L)).toInt()
    }
    var daysUnreachable by remember { mutableStateOf(computeDaysUnreachable()) }
    val timeline = remember {
        TimelineSubscriptionHolder(
            scope = scope,
            currentPairing = { pairings.load() },
            channelFor = { p ->
                LoaderTimelineChannel(
                    TimelineLoader(client, parsePeerAddrToken(p.daemonAddrToken)) {
                        client.bind(identity.secretKey())
                    }
                )
            },
            log = { PLog.i("PPassTimeline", it) },
        )
    }
    val heartbeat = remember {
        ForegroundHeartbeat(
            client, pairings, scope, com.hawkeyexb.ppass.backup.SentinelStore(context.filesDir),
            onReachable = {
                com.hawkeyexb.ppass.backup.flow.onFlowDesktopReachable(context)
                timeline.onDesktopReachable()
            },
            onPairingLost = { pid, failure ->
                com.hawkeyexb.ppass.backup.flow.flowDeliveryPairingLoss.record(
                    com.hawkeyexb.ppass.backup.flow.PairingId(pid), failure,
                )
            },
        )
    }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> {
                    batteryWhitelisted = backgroundAuthorization.isGranted()
                    if (batteryWhitelisted) {
                        settingsWriter.quiet("autoBackup", "restore on resume") {
                            restoreAutoBackupAfterAuthorizationReturned(context, backgroundAuthorized = true, source = "resume")
                        }
                    }

                    daysUnreachable = computeDaysUnreachable()
                    val accessBefore = mediaAccess
                    mediaAccess = mediaAccess(context)
                    if (mediaAccess != accessBefore) PLog.i("PPassFlow", "photo access on resume: $accessBefore -> $mediaAccess")
                    mediaLocation = AndroidMediaImporter.canReadMediaLocation(context)
                    albumAccessCanPrompt = canPromptForFullMediaAccess(context)
                    resumeCount++
                    heartbeat.start()
                    timeline.start()
                    foregroundCatchup()
                    if (pairings.load() != null) {
                        com.hawkeyexb.ppass.backup.flow.healFlowSourceUnavailableIfReadable(context)
                    }
                    updateController.onResume()
                }
                Lifecycle.Event.ON_STOP -> {
                    heartbeat.stop()
                    timeline.stop()
                }
                else -> {}
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            heartbeat.stop()
            timeline.stop()
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }

    fun hasExistingLedgerFor(pairing: Pairing): Boolean =
        isKnownDesktop(OnboardedDesktopsStore(context.filesDir), pairing.daemonNodeId) {
            BackupScopeStore(context, pairing.daemonNodeId).selectedBucketIds()?.isNotEmpty() == true
        }

    fun enterBucketPicker(pairing: Pairing, firstTime: Boolean) {
        screen = Screen.Buckets(
            pairing,
            BackupScopeStore(context).selectedBucketIds() ?: emptySet(),
            firstTime,
        )
    }

    val rulePrefs = remember { com.hawkeyexb.ppass.backup.autoBackupRulePrefs(context) }
    var ruleOn by remember { mutableStateOf(runCatching { rulePrefs.enabled() }.getOrDefault(false)) }
    var pendingRulePairing by remember { mutableStateOf<Pairing?>(null) }
    val applyRuleAccess: (Pairing?, MediaAccess) -> Unit = { pairing, access ->
        when (access) {
            MediaAccess.FULL -> if (pairing != null) {
                rulePrefs.set(true)
                ruleOn = true
                ruleHintRes = null
                val scopeStore = BackupScopeStore(context)
                val folderCount = com.hawkeyexb.ppass.backup.folder.FolderAccess.registry(context).allRecords().size
                if (com.hawkeyexb.ppass.backup.scopeNeedsFirstChoice(scopeStore.readScope(), folderCount)) {
                    screen = Screen.Buckets(pairing, scopeStore.selectedBucketIds() ?: emptySet(), false)
                } else {
                    requestFlowWake(context, TriggerReason.MANUAL)
                }
            }
            MediaAccess.PARTIAL -> {
                ruleHintRes = null
                scope.launch(Dispatchers.IO) {
                    val n = com.hawkeyexb.ppass.backup.picked.PickedUploads.enqueueAllowedImages(context)
                    PLog.i("PPassFlow", "auto-rule: partial photo access, sent allowed photos n=$n, rule stays off")
                    if (n > 0) {
                        com.hawkeyexb.ppass.backup.flow.requestFlowWake(context, com.hawkeyexb.ppass.backup.flow.TriggerReason.PICKED_ADDED)
                    }
                }
            }
            else -> ruleHintRes = R.string.auto_backup_rule_denied_hint
        }
    }
    var ruleAwaitingSettings by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(resumeCount) {
        if (!ruleAwaitingSettings) return@LaunchedEffect
        ruleAwaitingSettings = false
        val now = mediaAccess(context)
        PLog.i("PPassFlow", "auto-rule: back from settings, photo access=$now")
        applyRuleAccess(pairings.load(), now)
    }
    val rulePermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { _ ->
        val pairing = pendingRulePairing
        pendingRulePairing = null
        mediaAccess = mediaAccess(context)
        mediaLocation = AndroidMediaImporter.canReadMediaLocation(context)
        applyRuleAccess(pairing, mediaAccess)
    }
    val onToggleRule: (Pairing, Boolean) -> Unit = { pairing, on ->
        if (!on) {
            rulePrefs.set(false)
            ruleOn = false
            ruleHintRes = null
        } else {
            val routeScope = BackupScopeStore(context).readScope()
            val routeFolderCount = com.hawkeyexb.ppass.backup.folder.FolderAccess.registry(context).allRecords().size
            when (ruleEnableRoute(mediaAccess(context), canPromptForFullMediaAccess(context), routeScope, routeFolderCount)) {
                RuleEnableRoute.ChooseScope -> {
                    PLog.i("PPassFlow", "auto-rule: no effective scope, enabling rule then opening scope page to choose sources")
                    rulePrefs.set(true)
                    ruleOn = true
                    ruleHintRes = null
                    screen = Screen.Buckets(pairing, BackupScopeStore(context).selectedBucketIds() ?: emptySet(), false)
                }
                RuleEnableRoute.Apply -> applyRuleAccess(pairing, MediaAccess.FULL)
                RuleEnableRoute.Settings -> {
                    ruleAwaitingSettings = true
                    PLog.i("PPassFlow", "auto-rule: partial photo access, prompt locked; opening app settings for full access")
                    openAppDetailsSettings(context)
                }
                RuleEnableRoute.Request -> {
                    pendingRulePairing = pairing
                    launchAlbumAccessPrompt(rulePermission, withMediaLocation(requiredMediaPermissions()))
                }
            }
        }
    }
    val markDecided: (Pairing, String) -> Unit = { pairing, how ->
        if (settingsWriter.write("onboarded", pairing.daemonNodeId.take(8)) {
                OnboardedDesktopsStore(context.filesDir).markOnboarded(pairing.daemonNodeId)
            }
        ) {
            PLog.i("PPassFlow", "onboarding: marked onboarded via=$how desktop=${pairing.daemonNodeId.take(8)}")
        }
    }
    val decisionLock = remember { DecisionLock() }
    LaunchedEffect(screen) { if (screen !is Screen.Decision) decisionLock.unlock() }
    var decisionPickPairing by remember { mutableStateOf<Pairing?>(null) }
    val decisionPickLauncherResult: (List<android.net.Uri>) -> Unit = handlePick@{ uris ->
        val pairing = decisionPickPairing
        decisionPickPairing = null
        if (pairing == null || uris.isEmpty()) {
            PLog.i("PPassFlow", "onboarding: pick cancelled, staying on decision")
            decisionLock.unlock()
            return@handlePick
        }
        scope.launch {
            val registered = withContext(Dispatchers.IO) {
                runPickedEnqueue(
                    uriCount = uris.size,
                    enqueue = { com.hawkeyexb.ppass.backup.picked.PickedUploads.enqueue(context, uris) },
                    onSuccess = {},
                    onFailure = { err -> PLog.w("PPassFlow", "onboarding: picked enqueue failed", err) },
                    notifyFailure = { resId -> scope.launch { snackbarHostState.showSnackbar(context.getString(resId)) } },
                )
            }
            if (!registered) {
                PLog.i("PPassFlow", "onboarding: pick registered nothing, staying on decision")
                decisionLock.unlock()
                return@launch
            }
            pickedBatch = withContext(Dispatchers.IO) {
                runCatching { com.hawkeyexb.ppass.backup.picked.PickedUploads.store(context).summary() }.getOrNull()
            }
            com.hawkeyexb.ppass.backup.flow.requestFlowWake(context, com.hawkeyexb.ppass.backup.flow.TriggerReason.PICKED_ADDED)
            markDecided(pairing, "pick")
            if (screen == Screen.Decision(pairing)) screen = Screen.Home(pairing)
        }
    }
    val decisionPickLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(com.hawkeyexb.ppass.backup.picked.PickedUploads.MAX_PICK),
        onResult = decisionPickLauncherResult,
    )
    val decisionFileLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        decisionPickLauncherResult(if (result.resultCode == android.app.Activity.RESULT_OK) {
            com.hawkeyexb.ppass.ui.SingleTransferFilePicker.urisFromResult(result.data)
        } else emptyList())
    }
    val launchDecisionFile: (Pairing) -> Unit = { pairing ->
        decisionPickPairing = pairing
        runCatching { decisionFileLauncher.launch(com.hawkeyexb.ppass.ui.SingleTransferFilePicker.intent()) }
            .onFailure {
                PLog.w("PPassFlow", "onboarding: file picker failed to open", it)
                decisionPickPairing = null
                decisionLock.unlock()
            }
    }
    val launchDecisionPick: (Pairing) -> Unit = { pairing ->
        decisionPickPairing = pairing
        runCatching {
            decisionPickLauncher.launch(
                androidx.activity.result.PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo),
            )
        }.onFailure {
            PLog.w("PPassFlow", "onboarding: picker failed to open", it)
            decisionPickPairing = null
            decisionLock.unlock()
        }
    }
    val onDecisionChooseScope: (Pairing) -> Unit = { pairing ->
        if (settingsWriter.write("autoRule", true) { rulePrefs.set(true) }) {
            ruleOn = true
            ruleHintRes = null
            PLog.i("PPassFlow", "onboarding: auto backup enabled, opening scope")
            screen = Screen.Buckets(pairing, emptySet(), firstTime = true)
        } else {
            decisionLock.unlock()
        }
    }

    systemBackTarget(screen)?.let { target ->
        BackHandler { screen = target }
    }

    Box(Modifier.fillMaxSize()) {
    when (val s = screen) {
        is Screen.Welcome -> WelcomeScreen(
            onScan = {
                if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
                    == PackageManager.PERMISSION_GRANTED
                ) {
                    screen = Screen.Scan
                } else {
                    cameraPermission.launch(Manifest.permission.CAMERA)
                }
            },
            onManual = { screen = Screen.ManualPair },
        )

        is Screen.Scan -> ScanScreen(
            onQr = { qr -> screen = Screen.Waiting(qr) },
            onCancel = { screen = Screen.Welcome },
            startManual = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED,
        )

        is Screen.ManualPair -> ScanScreen(
            onQr = { qr -> screen = Screen.Waiting(qr) },
            onCancel = { screen = Screen.Welcome },
            startManual = true,
        )

        is Screen.Waiting -> {
            var phase by remember(s.qr) { mutableStateOf<PairPhase>(PairPhase.Asking) }
            when (val ph = phase) {
                PairPhase.Asking -> PairStatusScreen(
                    title = androidx.compose.ui.res.stringResource(R.string.pair_waiting_title),
                    body = null,
                    action = androidx.compose.ui.res.stringResource(R.string.cancel) to
                        { screen = Screen.Welcome },
                    loading = true,
                )
                is PairPhase.Code -> PairCodeScreen(
                    code = ph.code,
                    desktopName = ph.desktop.name,
                    fingerprint = ph.desktop.fingerprint,
                    onCancel = { screen = Screen.Welcome },
                )
            }
            LaunchedEffect(s.qr) {
                val outcome = bindThenPair(
                    bind = { client.bind(identity.secretKey()) },
                    pair = {
                        pairWithQr(
                            client,
                            s.qr,
                            deviceName(context),
                            onCode = { code, desktop, _ -> phase = PairPhase.Code(code, desktop) },
                            storageDeviceNameFallback = context.getString(R.string.storage_device_default),
                            knownDesktop = { OnboardedDesktopsStore(context.filesDir).wasOnboarded(it) },
                        )
                    },
                )
                if (screen != s) return@LaunchedEffect
                when (outcome) {
                    is PairOutcome.Joined -> {
                        val saveError = savePairingOrError { pairings.save(outcome.pairing) }
                        if (saveError != null) {
                            PLog.w("PPassFlow", "pairing joined but saving it failed: $saveError")
                            screen = Screen.Trouble(R.string.pair_lapsed_title, R.string.pair_save_failed)
                            return@LaunchedEffect
                        }
                        requestFlowWakeAfterRepair(context)
                        if (hasExistingLedgerFor(outcome.pairing)) {
                            settingsWriter.quiet("autoBackup", "restore after repair") {
                                restoreAutoBackupAfterRepair(
                                    context,
                                    backgroundAuthorization.isGranted(),
                                )
                            }
                            screen = Screen.Home(outcome.pairing)
                        } else {
                            settingsWriter.write("autoBackup", "new desktop, ask again") {
                                AutoBackupPrefs(context.filesDir).setRequested(false)
                            }
                            rulePrefs.set(false)
                            ruleOn = false
                            screen = Screen.Decision(outcome.pairing)
                        }
                    }
                    is PairOutcome.Refused -> {
                        outcome.wireReason?.let { PLog.w("PPassFlow", "pairing refused for a reason with no wording: $it") }
                        screen = Screen.Trouble(
                            pairRefusalTitleRes(outcome.cause),
                            bodyRes = pairRefusalDetailRes(outcome.cause),
                            errorCode = pairRefusalErrorCode(outcome.cause),
                        )
                    }
                    is PairOutcome.NeedsUpdate -> screen = Screen.Trouble(
                        R.string.pair_needs_update_title,
                        outdatedTextRes(outcome.side),
                        offerAppUpdate = offersAppUpdate(outcome.side),
                    )
                    is PairOutcome.Failed -> {
                        PLog.w("PPassFlow", "pairing failed: ${outcome.diagnostic}")
                        screen = when (outcome.kind) {
                            PairFailure.UNREACHABLE -> Screen.Trouble(R.string.pair_failed_title, R.string.pair_failed_body)
                            PairFailure.NOT_A_CODE -> Screen.Trouble(R.string.not_a_code)
                            PairFailure.NO_ADDRESS -> Screen.Trouble(R.string.pair_needs_update_title, R.string.pair_unparseable_code)
                        }
                    }
                }
            }
        }

        is Screen.Decision -> {
            LaunchedEffect(s.pairing.daemonNodeId) {
                PLog.i("PPassFlow", "onboarding: decision shown desktop=${s.pairing.daemonNodeId.take(8)}")
            }
            DecisionScreen(
                computerName = s.pairing.storageDeviceName,
                busy = decisionLock.busy,
                onChooseScope = { if (decisionLock.tryLock()) onDecisionChooseScope(s.pairing) },
                onPickPhotos = { if (decisionLock.tryLock()) launchDecisionPick(s.pairing) },
                onPickFiles = { if (decisionLock.tryLock()) launchDecisionFile(s.pairing) },
            )
        }

        is Screen.Trouble -> PairStatusScreen(
            title = androidx.compose.ui.res.stringResource(s.titleRes),
            body = s.bodyRes?.let { androidx.compose.ui.res.stringResource(it) },
            footnote = s.errorCode?.let { androidx.compose.ui.res.stringResource(R.string.error_code_line, it) },
            action = if (s.offerAppUpdate) {
                androidx.compose.ui.res.stringResource(R.string.update_check_now) to
                    { updateController.onCheckRowClick() }
            } else {
                androidx.compose.ui.res.stringResource(R.string.scan_again) to
                    { screen = Screen.Scan }
            },
        )

        is Screen.Home -> {
            val holder = remember { BackupUiStateHolder(context, client, identity, s.pairing) }
            DisposableEffect(holder) {
                onDispose { holder.dispose() }
            }
            LaunchedEffect(holder) {
                holder.notices.collect { snackbarHostState.showSnackbar(context.getString(it)) }
            }
            LaunchedEffect(holder, resumeCount) { holder.onResume() }
            LaunchedEffect(holder, mediaAccess) { holder.onMediaAccess(mediaAccess) }
            val backupSettings = remember { BackupSettings(context.filesDir) }
            var wifiOnly by remember { mutableStateOf(backupSettings.load().wifiOnly) }
            val notifyOnFailurePrefs = remember {
                com.hawkeyexb.ppass.backup.NotifyOnFailurePrefs(context.filesDir)
            }
            var notifyOnFailure by remember {
                mutableStateOf(notifyOnFailurePrefs.enabled() && hasNotificationPermission(context))
            }
            var notificationRequestInFlight by remember { mutableStateOf(false) }
            val prefs = remember { AutoBackupPrefs(context.filesDir) }
            var userRequestedBackgroundBackup by remember { mutableStateOf(prefs.requested()) }
            var mediaFolders by remember { mutableStateOf<List<FolderUi>>(emptyList()) }
            var folderRevision by remember { mutableStateOf(0) }
            var foldersError by remember { mutableStateOf<Int?>(null) }
            var folderToReauthorize by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf<String?>(null) }
            LaunchedEffect(folderRevision, resumeCount) {
                val entries = withContext(Dispatchers.IO) {
                    com.hawkeyexb.ppass.backup.folder.FolderAccess.listEntries(context)
                }
                mediaFolders = entries.map { FolderUi(it.sourceId, it.name, it.needsPermission) }
                if (entries.none { it.needsPermission }) {
                    com.hawkeyexb.ppass.backup.flow.healFlowSourceUnavailableIfReadable(context)
                }
            }
            LaunchedEffect(foldersError) {
                foldersError?.let {
                    snackbarHostState.showSnackbar(context.getString(it))
                    foldersError = null
                }
            }
            val folderPicker = rememberLauncherForActivityResult(
                ActivityResultContracts.OpenDocumentTree(),
            ) { uri ->
                if (uri == null) {
                    folderToReauthorize = null
                    return@rememberLauncherForActivityResult
                }
                val reauth = folderToReauthorize
                folderToReauthorize = null
                scope.launch {
                    val (changed, errorRes) = withContext(Dispatchers.IO) {
                        if (reauth != null) {
                            val ok = com.hawkeyexb.ppass.backup.folder.FolderAccess.reauthorize(context, reauth, uri)
                            if (ok) {
                                com.hawkeyexb.ppass.backup.folder.FolderAccess.changed(context)
                                com.hawkeyexb.ppass.backup.flow.healFlowSourceUnavailableIfReadable(context)
                                true to null
                            } else {
                                false to R.string.folder_reauthorize_failed
                            }
                        } else {
                            val added = com.hawkeyexb.ppass.backup.folder.FolderAccess.addFolder(context, uri)
                            if (added != null) {
                                com.hawkeyexb.ppass.backup.folder.FolderAccess.changed(context)
                                com.hawkeyexb.ppass.backup.flow.healFlowSourceUnavailableIfReadable(context)
                                true to null
                            } else {
                                false to R.string.folder_add_failed
                            }
                        }
                    }
                    if (errorRes != null) foldersError = errorRes
                    if (changed) folderRevision++
                }
            }
            val autoPrefsRevision by AutoBackupPrefs.revision.collectAsState()
            val autoBackupProducing = remember(autoPrefsRevision) { prefs.enabled() }
            var batteryRequestInFlight by remember { mutableStateOf(false) }
            val notificationPermission = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestPermission(),
            ) { granted ->
                notificationRequestInFlight = false
                notifyOnFailure = settingsWriter.persist("notifyOnFailure", granted, notifyOnFailurePrefs::setEnabled) {
                    notifyOnFailurePrefs.enabled()
                } && hasNotificationPermission(context)
            }
            val batteryPermission = rememberLauncherForActivityResult(
                ActivityResultContracts.StartActivityForResult(),
            ) {
                batteryRequestInFlight = false
                batteryWhitelisted = backgroundAuthorization.isGranted()
                if (batteryWhitelisted) {
                    val saved = if (backupInterrupted) {
                        settingsWriter.write("backupInterruption", "acknowledged") { resumeAfterInterruption(context) }
                            .also { backupInterrupted = !it }
                    } else settingsWriter.write("autoBackup", true) { enableAutoBackup(context) }
                    if (saved) {
                        scope.launch {
                            snackbarHostState.showSnackbar(
                                context.getString(R.string.background_backup_authorized),
                            )
                        }
                    }
                } else if (settingsWriter.write("autoBackup", "suspended") { suspendAutoBackupUntilAuthorized(context) }) {
                    scope.launch {
                        snackbarHostState.showSnackbar(
                            context.getString(R.string.background_backup_authorization_denied),
                        )
                    }
                }
                userRequestedBackgroundBackup = prefs.requested()
            }
            var pendingWifiOff by remember { mutableStateOf(false) }
            var photoViewerOpen by remember { mutableStateOf(false) }
            var storageDetailOpen by remember { mutableStateOf(false) }
            LaunchedEffect(batteryWhitelisted) {
                userRequestedBackgroundBackup = prefs.requested()
                if (!batteryWhitelisted && userRequestedBackgroundBackup) {
                    settingsWriter.write("autoBackup", "suspended") { suspendAutoBackupUntilAuthorized(context) }
                }
            }
            val backgroundBackupState = backgroundBackupStateOf(
                userEnabled = userRequestedBackgroundBackup,
                systemWhitelisted = batteryWhitelisted,
                producerEnabled = autoBackupProducing,
                watcherScheduled = !backupInterrupted,
                watcherInterrupted = backupInterrupted,
            )
            val resolveBackgroundBackup = {
                if (batteryWhitelisted) {
                    val resumed = settingsWriter.write("backupInterruption", "acknowledged") {
                        resumeAfterInterruption(context)
                        restoreAutoBackupAfterAuthorizationReturned(context, backgroundAuthorized = true, source = "resolve")
                    }
                    backupInterrupted = BackupHealthPrefs(context.filesDir).load().interruptedUnacknowledged
                    if (resumed) {
                        scope.launch {
                            snackbarHostState.showSnackbar(
                                context.getString(R.string.background_backup_resuming),
                            )
                        }
                    }
                } else if (!batteryRequestInFlight) {
                    batteryRequestInFlight = true
                    batteryPermission.launch(backgroundAuthorization.requestIntent())
                }
                Unit
            }
            val onToggleAutoBackup: (Boolean) -> Unit = { enabled ->
                if (!enabled) {
                    batteryRequestInFlight = false
                    if (settingsWriter.write("autoBackup", false) { disableAutoBackup(context) }) {
                        settingsWriter.write("backupInterruption", "acknowledged") {
                            BackupHealthPrefs(context.filesDir).acknowledge()
                        }
                        backupInterrupted = BackupHealthPrefs(context.filesDir).load().interruptedUnacknowledged
                    }
                    userRequestedBackgroundBackup = prefs.requested()
                } else if (batteryWhitelisted) {
                    if (backupInterrupted) {
                        val resumed = settingsWriter.write("backupInterruption", "acknowledged") {
                            resumeAfterInterruption(context)
                        }
                        backupInterrupted = BackupHealthPrefs(context.filesDir).load().interruptedUnacknowledged
                        if (resumed) userRequestedBackgroundBackup = true
                    } else {
                        settingsWriter.write("autoBackup", true) { enableAutoBackup(context) }
                        userRequestedBackgroundBackup = prefs.requested()
                    }
                } else if (!batteryRequestInFlight) {
                    if (settingsWriter.write("autoBackup", "requested") { prefs.setRequested(true) }) {
                        batteryRequestInFlight = true
                        batteryPermission.launch(backgroundAuthorization.requestIntent())
                    }
                    userRequestedBackgroundBackup = prefs.requested()
                }
            }
            val offerStore = remember { com.hawkeyexb.ppass.backup.BackgroundBackupOfferStore(context.filesDir) }
            var offerDismissed by remember { mutableStateOf(offerStore.dismissed()) }
            val offerBatteryPermission = rememberLauncherForActivityResult(
                ActivityResultContracts.StartActivityForResult(),
            ) {
                batteryRequestInFlight = false
                batteryWhitelisted = backgroundAuthorization.isGranted()
                if (batteryWhitelisted && settingsWriter.write("autoBackup", true) { enableAutoBackup(context) }) {
                    scope.launch { snackbarHostState.showSnackbar(context.getString(R.string.background_backup_authorized)) }
                }
                userRequestedBackgroundBackup = prefs.requested()
            }
            val onEnableFromOffer = {
                if (batteryWhitelisted) {
                    onToggleAutoBackup(true)
                } else if (!batteryRequestInFlight) {
                    batteryRequestInFlight = true
                    offerBatteryPermission.launch(backgroundAuthorization.requestIntent())
                }
            }
            var selectedBucketCount by remember { mutableStateOf(BackupScopeStore(context).selectedBucketIds()?.size) }
            var selectedFolderCount by remember { mutableStateOf(0) }
            var hasUsableFolder by remember { mutableStateOf(false) }
            var scopeUnreadable by remember { mutableStateOf(false) }
            var scopeSince by remember { mutableStateOf(BackupScopeStore(context).sinceSec()) }
            val scopeOn = ruleOn && (scopeUnreadable || (selectedBucketCount ?: 0) > 0)
            LaunchedEffect(mediaAccess, resumeCount) {
                scopeUnreadable = withContext(Dispatchers.IO) { BackupScopeStore(context).readScope() is ScopeRead.Unreadable }
                scopeSince = withContext(Dispatchers.IO) { BackupScopeStore(context).sinceSec() }
                val listed = withContext(Dispatchers.IO) {
                    if (mediaAccess == MediaAccess.FULL) {
                        runCatching { MediaScanner(context.contentResolver).listBuckets() }.getOrNull()
                    } else {
                        null
                    }
                }
                val effectiveSelected = withContext(Dispatchers.IO) {
                    val store = BackupScopeStore(context)
                    val folderIds = com.hawkeyexb.ppass.backup.folder.FolderAccess.registry(context).allRecords()
                        .mapTo(HashSet()) { it.bucketId }
                    com.hawkeyexb.ppass.backup.effectiveBackupScope(store.scope(), store.knownBucketIds(), folderIds, store.sinceSec())?.buckets
                }
                hasUsableFolder = withContext(Dispatchers.IO) {
                    val store = BackupScopeStore(context)
                    val folderIds = com.hawkeyexb.ppass.backup.folder.FolderAccess.registry(context).allRecords()
                        .mapTo(HashSet()) { it.bucketId }
                    com.hawkeyexb.ppass.backup.SourceAvailability.hasUsableFolder(
                        selected = store.selectedBucketIds(),
                        known = store.knownBucketIds() ?: emptySet(),
                        existingFolders = folderIds,
                    )
                }
                val folderIds = withContext(Dispatchers.IO) {
                    com.hawkeyexb.ppass.backup.folder.FolderAccess.registry(context).allRecords().mapTo(HashSet()) { it.bucketId }
                }
                selectedFolderCount = effectiveSelected?.count { com.hawkeyexb.ppass.backup.folder.isFolderId(it) && it in folderIds } ?: 0
                selectedBucketCount = selectedExistingCount(effectiveSelected, listed?.map { it.id }?.toSet()?.plus(folderIds))
            }
            val scope = rememberCoroutineScope()
            LaunchedEffect(Unit) {
                runCatching { client.bind(identity.secretKey()) }
                    .onFailure { PLog.w("PPassBind", "home warm-up bind failed: $it") }
            }
            val mediaPermission = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestMultiplePermissions()
            ) { grants ->
                mediaLocation = AndroidMediaImporter.canReadMediaLocation(context)
                if (requiredMediaPermissions().any { grants[it] == true }) holder.backupNow()
            }
            val onRepairPairing = {
                scope.launch {
                    withContext(Dispatchers.IO) { clearLocalPairingLogged(context, s.pairing) }
                    val cameraGranted = ContextCompat.checkSelfPermission(
                        context, Manifest.permission.CAMERA,
                    ) == PackageManager.PERMISSION_GRANTED
                    screen = repairScanTarget(cameraGranted)
                    if (!cameraGranted) cameraPermission.launch(Manifest.permission.CAMERA)
                }
                Unit
            }
            val outdatedSide = ProtocolVersionGate.outdated.collectAsState().value
            val connection = holder.connectionState(timeline, daysUnreachable)
            TwoTabs(
                tab = tab,
                onTab = { tab = it },
                background = twoTabsBackground(viewerOpen = photoViewerOpen),
                showTabBar = !photoViewerOpen && !storageDetailOpen,
                settingsAlert = connection.needsRepair ||
                    backgroundBackupState == BackgroundBackupState.NeedsSystemAuthorization ||
                    backgroundBackupState == BackgroundBackupState.SystemStoppedWatcher,
                photos = {
                    val guideFacts = GuideFacts(
                        scopeOn = scopeOn,
                        firstUploaded = (holder.triplet.value?.lastSuccessAt ?: 0L) > 0L,
                        backgroundOn = userRequestedBackgroundBackup,
                        finished = offerDismissed,
                    )
                    val firstChoicePending = com.hawkeyexb.ppass.backup.scopeNeedsFirstChoice(
                        BackupScopeStore(context).readScope(),
                        com.hawkeyexb.ppass.backup.folder.FolderAccess.registry(context).allRecords().size,
                    )
                    val guide = guideForCurrentScope(photosGuideOf(guideFacts), firstChoicePending)
                    PhotosScreen(
                        timeline,
                        onViewerOpenChange = { photoViewerOpen = it },
                        connection = connection,
                        onReconnect = onRepairPairing,
                        guide = guide,
                        computerName = s.pairing.storageDeviceName,
                        guideActionGoesToSettings = !ruleOn &&
                            ruleEnableRoute(
                                mediaAccess,
                                canPromptForFullMediaAccess(context),
                                BackupScopeStore(context).readScope(),
                                com.hawkeyexb.ppass.backup.folder.FolderAccess.registry(context).allRecords().size,
                            ) == RuleEnableRoute.Settings,
                        onGuideAction = { g ->
                            when (g) {
                                PhotosGuide.EnableScope ->
                                    if (ruleOn) enterBucketPicker(s.pairing, firstTime = false) else onToggleRule(s.pairing, true)
                                PhotosGuide.EnableBackground -> onEnableFromOffer()
                                PhotosGuide.None -> Unit
                            }
                        },
                        onGuideDismiss = {
                            if (settingsWriter.write("onboardingGuide", "dismissed") { offerStore.dismiss() }) {
                                offerDismissed = true
                                PLog.i("PPassGuide", "photos-guide: dismissed")
                            }
                        },
                        scopeEmptyHint = if (scopeEmptyHintShown(guideFacts, holder.triplet.value?.n)) {
                            scopeSince?.let {
                                context.getString(R.string.photos_scope_empty_since, scopeSinceDate(it, System.currentTimeMillis()), s.pairing.storageDeviceName)
                            } ?: context.getString(R.string.photos_scope_empty_all, s.pairing.storageDeviceName)
                        } else null,
                    )
                },
                backup = {
                    val homeAvailability = com.hawkeyexb.ppass.backup.SourceAvailability(
                        autoRule = ruleOn,
                        photoAccess = mediaAccess,
                        hasUsableFolder = hasUsableFolder,
                        hasSelectedAlbum = (selectedBucketCount?.minus(selectedFolderCount) ?: 0) > 0,
                    )
                    HomeScreen(
                        storageName = s.pairing.storageDeviceName,
                        state = holder.state.value,
                        triplet = holder.triplet.value,
                        commandPending = holder.commandPending.value,
                        missingSourceNotice = holder.missingSourceNotice.value,
                        onAcknowledgeMissingSource = { holder.acknowledgeMissingSourceNotice() },
                        acknowledgedMissingSourceCount = holder.acknowledgedMissingSourceCount.value,
                        transferProgress = holder.transferProgress.value,
                        transferRow = holder.transferRow.value,
                        cancelRemainingCount = holder.cancelRemainingCount.value,
                        onRequestCancelRemaining = { holder.requestCancelRemaining() },
                        cancelConfirmCount = holder.cancelConfirmCount.value,
                        skippedCount = holder.skippedCount.value,
                        onRestoreSkipped = { holder.restoreSkipped() },
                        onConfirmCancelRemaining = { holder.confirmCancelRemaining() },
                        onDismissCancelRemaining = { holder.dismissCancelRemaining() },
                        waitReasonRes = holder.waitReasonNotice.value,
                        outdated = outdatedSide,
                        desktopLowSpace = holder.desktopLowSpace.value,
                        wifiOnly = wifiOnly,
                        onWifiOnlyChange = { enable ->
                            if (!enable) pendingWifiOff = true
                            else {
                                wifiOnly = settingsWriter.persist("wifiOnly", true, backupSettings::save) {
                                    backupSettings.load().wifiOnly
                                }
                                if (wifiOnly) rescheduleAutoBackup(context)
                            }
                        },
                        notifyOnFailure = notifyOnFailure,
                        onNotifyOnFailureChange = { enabled ->
                            val action = if (!enabled) {
                                com.hawkeyexb.ppass.backup.NotifyEnableAction.ENABLE
                            } else {
                                com.hawkeyexb.ppass.backup.notifyEnableAction(
                                    granted = hasNotificationPermission(context),
                                    askedBefore = notifyOnFailurePrefs.systemAsked(),
                                    systemWillShowRationale = Build.VERSION.SDK_INT >= 33 &&
                                        (context as? android.app.Activity)
                                            ?.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS) == true,
                                )
                            }
                            when (action) {
                                com.hawkeyexb.ppass.backup.NotifyEnableAction.ENABLE ->
                                    notifyOnFailure = settingsWriter.persist("notifyOnFailure", enabled, notifyOnFailurePrefs::setEnabled) {
                                        notifyOnFailurePrefs.enabled()
                                    } && hasNotificationPermission(context)
                                com.hawkeyexb.ppass.backup.NotifyEnableAction.REQUEST -> if (!notificationRequestInFlight) {
                                    settingsWriter.quiet("notifyOnFailure", "system asked") { notifyOnFailurePrefs.markSystemAsked() }
                                    notificationRequestInFlight = true
                                    notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                                }
                                com.hawkeyexb.ppass.backup.NotifyEnableAction.OPEN_SETTINGS -> openAppDetailsSettings(context)
                            }
                        },
                        pairedAt = s.pairing.pairedAt,
                        autoBackupEnabled = userRequestedBackgroundBackup,
                        backgroundBackupState = backgroundBackupState,
                        onResolveBackgroundBackup = resolveBackgroundBackup,
                        onToggleAutoBackup = onToggleAutoBackup,
                        onDisconnect = {
                            scope.launch {
                                disconnectAndNotifyInBackground(
                                    notify = notifyUnpairOnce(client, s.pairing),
                                    background = app.noticeScope,
                                    clearLocal = { withContext(Dispatchers.IO) { clearLocalPairingLogged(context, s.pairing) } },
                                )
                                screen = Screen.Welcome
                            }
                            Unit
                        },
                        connection = connection,
                        onRepair = onRepairPairing,
                        onStorageDetailOpenChange = { storageDetailOpen = it },
                        mediaFolders = mediaFolders,
                        onFolderAdd = {
                            folderToReauthorize = null
                            folderPicker.launch(null)
                        },
                        onFolderRemove = { folder ->
                            scope.launch(Dispatchers.IO) {
                                com.hawkeyexb.ppass.backup.folder.FolderAccess.removeFolder(context, folder.id)
                                com.hawkeyexb.ppass.backup.folder.FolderAccess.changed(context)
                                folderRevision++
                            }
                        },
                        onFolderReauthorize = { folder ->
                            folderToReauthorize = folder.id
                            folderPicker.launch(null)
                        },
                        onFoldersOpenChange = { storageDetailOpen = it },
                        hasUsableSource = homeAvailability.hasUsableSource,
                        mixedAlbumIncomplete = homeAvailability.mixedAlbumIncomplete,
                        hasSelectedAlbum = homeAvailability.hasSelectedAlbum,
                        onPickFiles = { filePickLauncher.launch(com.hawkeyexb.ppass.ui.SingleTransferFilePicker.intent()) },
                        selectedBucketCount = selectedBucketCount,
                        selectedFolderCount = selectedFolderCount,
                        scopeUnreadable = scopeUnreadable,
                        scopeTimeLabel = scopeValueLabel(context, scopeSince),
                        countsReadable = holder.countsReadable.value,
                        scopeSaved = holder.scopeSaved.value,
                        onOpenBucketPicker = { enterBucketPicker(s.pairing, firstTime = false) },
                        onPickPhotos = {
                            pickPhotosLauncher.launch(
                                androidx.activity.result.PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo),
                            )
                        },
                        pickedBatch = pickedBatch,
                        onBackupNow = {
                            val needed = requiredMediaPermissions().filter {
                                ContextCompat.checkSelfPermission(context, it) !=
                                    PackageManager.PERMISSION_GRANTED
                            }
                            if (needed.isEmpty()) holder.backupNow()
                            else launchAlbumAccessPrompt(mediaPermission, withMediaLocation(needed))
                        },
                        mediaAccess = mediaAccess,
                        onOpenAppSettings = {
                            PLog.i("PPassFlow", "auto-rule: blocked (photo access=$mediaAccess), opening app settings")
                            openAppDetailsSettings(context)
                        },
                        updateRowValue = updateRowValueOf(context, updateState),
                        onCheckUpdate = { updateController.onCheckRowClick() },
                        autoBackupRuleOn = ruleOn,
                        scopeHasStart = scopeSince != null,
                        onToggleAutoBackupRule = { on -> onToggleRule(s.pairing, on) },
                        autoBackupRuleHintRes = ruleHintRes ?: when {
                            !ruleOn -> null
                            mediaAccess == MediaAccess.PARTIAL -> R.string.auto_backup_rule_partial_hint
                            mediaAccess == MediaAccess.NONE -> R.string.auto_backup_rule_none_hint
                            else -> null
                        },
                        notice = {
                            val expiredFolders = mediaFolders.filter { it.needsPermission }
                            val sourceUnavailableWaiting =
                                (holder.state.value as? com.hawkeyexb.ppass.ui.BackupUiState.Waiting)?.reason ==
                                    com.hawkeyexb.ppass.backup.flow.WaitReason.SOURCE_UNAVAILABLE
                            NoticeHost(
                                backgroundBackupState = backgroundBackupState,
                                onResolveBackgroundBackup = resolveBackgroundBackup,
                                locationRedacted = mediaAccess != MediaAccess.NONE && !mediaLocation,
                                onAllowLocation = {
                                    if (Build.VERSION.SDK_INT >= 29) locationPermission.launch(Manifest.permission.ACCESS_MEDIA_LOCATION)
                                },
                                expiredFolderCount = expiredFolders.size,
                                expiredFolderName = expiredFolders.singleOrNull()?.name,
                                sourceUnavailableWaiting = sourceUnavailableWaiting,
                                onResolveFolderPermission = {
                                    if (expiredFolders.size == 1) {
                                        folderToReauthorize = expiredFolders.single().id
                                        folderPicker.launch(null)
                                    } else {
                                        enterBucketPicker(s.pairing, firstTime = false)
                                    }
                                },
                            )
                        },
                    )
                },
            )
            if (pendingWifiOff) {
                AlertDialog(
                    onDismissRequest = { pendingWifiOff = false },
                    title = { Text(stringResource(R.string.wifi_off_confirm_title)) },
                    text = { Text(stringResource(R.string.wifi_off_confirm_body)) },
                    confirmButton = {
                        TextButton(onClick = {
                            pendingWifiOff = false
                            wifiOnly = settingsWriter.persist("wifiOnly", false, backupSettings::save) {
                                backupSettings.load().wifiOnly
                            }
                            if (!wifiOnly) {
                                rescheduleAutoBackup(context)
                                requestFlowWake(context, TriggerReason.MANUAL)
                            }
                        }) { Text(stringResource(R.string.wifi_off_confirm_ok)) }
                    },
                    dismissButton = {
                        TextButton(onClick = { pendingWifiOff = false }) {
                            Text(stringResource(R.string.cancel))
                        }
                    },
                )
            }
        }

        is Screen.Buckets -> {
            val scopeStore = remember { BackupScopeStore(context) }
            val folderRegistry = remember { com.hawkeyexb.ppass.backup.folder.FolderAccess.registry(context) }
            var buckets by remember { mutableStateOf<List<MediaScanner.Bucket>?>(null) }
            var folderEntries by remember { mutableStateOf(emptyList<com.hawkeyexb.ppass.backup.folder.FolderEntry>()) }
            var folderRevision by remember { mutableStateOf(0) }
            var pendingFolderUris by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(arrayListOf<String>()) }
            var folderToReauthorize by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf<String?>(null) }
            var scopeSaving by remember { mutableStateOf(false) }
            var foldersError by remember { mutableStateOf<Int?>(null) }
            LaunchedEffect(foldersError) {
                foldersError?.let {
                    snackbarHostState.showSnackbar(context.getString(it))
                    foldersError = null
                }
            }

            LaunchedEffect(mediaAccess) {
                buckets = if (mediaAccess == MediaAccess.NONE) {
                    emptyList()
                } else {
                    withContext(Dispatchers.IO) { MediaScanner(context.contentResolver).listBuckets() }
                }
            }
            LaunchedEffect(folderRevision, resumeCount) {
                val entries = withContext(Dispatchers.IO) {
                    com.hawkeyexb.ppass.backup.folder.FolderAccess.listEntries(context)
                }
                folderEntries = entries
                if (entries.none { it.needsPermission }) {
                    com.hawkeyexb.ppass.backup.flow.healFlowSourceUnavailableIfReadable(context)
                }
            }
            val folderPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
                if (uri == null) {
                    folderToReauthorize = null
                    return@rememberLauncherForActivityResult
                }
                val reauth = folderToReauthorize
                folderToReauthorize = null
                if (reauth == null) {
                    if (!pendingFolderUris.contains(uri.toString())) pendingFolderUris = ArrayList(pendingFolderUris + uri.toString())
                } else {
                    scope.launch {
                        val ok = withContext(Dispatchers.IO) {
                            val reauthorized = com.hawkeyexb.ppass.backup.folder.FolderAccess.reauthorize(context, reauth, uri)
                            if (reauthorized) {
                                com.hawkeyexb.ppass.backup.folder.FolderAccess.changed(context)
                                com.hawkeyexb.ppass.backup.flow.healFlowSourceUnavailableIfReadable(context)
                            }
                            reauthorized
                        }
                        if (!ok) {
                            foldersError = R.string.folder_reauthorize_failed
                        } else {
                            folderRevision++
                        }
                    }
                }
            }

            val list = buckets
            if (list == null) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(stringResource(R.string.bucket_loading), color = PPColor.Ink40)
                }
            } else {
                val savedRead = remember { scopeStore.readScope() }
                val savedSince = remember { scopeStore.sinceSec() }
                val records = folderRegistry.allRecords()
                val knownSources = scopeStore.knownBucketIds()
                val folderProjection = projectBucketScreenFolders(
                    context = context,
                    scopeStore = scopeStore,
                    records = records,
                    folderEntries = folderEntries,
                    pendingFolderUris = pendingFolderUris,
                    knownSources = knownSources,
                    savedSince = savedSince,
                )

                BucketScreen(
                    buckets = list,
                    selected = initialSelection(
                        saved = (savedRead as? ScopeRead.Saved)?.ids
                            ?.filterNot { com.hawkeyexb.ppass.backup.folder.isFolderId(it) }?.toSet(),
                        firstTime = s.firstTime,
                        cameraBucketIds = list.filter { it.isCamera }.map { it.id }.toSet(),
                    ),
                    initialTime = initialScopeTime(savedRead is ScopeRead.Saved, savedSince, mediaAccess == MediaAccess.PARTIAL),
                    sinceLabel = scopeSinceOptionLabel(context, savedSince.takeIf { savedRead is ScopeRead.Saved }),
                    firstTime = s.firstTime,
                    knownBuckets = knownSources,
                    folderBuckets = folderProjection.folderCards,
                    selectedFolderKeys = folderProjection.selectedFolders,
                    saving = scopeSaving,
                    albumAccess = mediaAccess,
                    albumAccessCanPrompt = albumAccessCanPrompt,
                    onRequestAlbumAccess = {
                        launchAlbumAccessPrompt(bucketAlbumPermission, withMediaLocation(requiredMediaPermissions()))
                    },
                    onOpenAlbumSettings = { openAppDetailsSettings(context) },
                    onAddFolder = {
                        folderToReauthorize = null
                        folderPicker.launch(null)
                    },
                    onRemoveFolder = { key ->
                        if (pendingFolderUris.contains(key)) {
                            pendingFolderUris = ArrayList(pendingFolderUris.filter { it != key })
                        } else {
                            scope.launch(Dispatchers.IO) {
                                runCatching {
                                    com.hawkeyexb.ppass.backup.folder.FolderAccess.removeFolder(context, key)
                                }.onFailure { foldersError = R.string.command_failed }
                                com.hawkeyexb.ppass.backup.folder.FolderAccess.changed(context)
                                folderRevision++
                            }
                        }
                    },
                    onReauthorizeFolder = { key ->
                        folderToReauthorize = key
                        folderPicker.launch(null)
                    },
                    onDone = { selectedAlbumIds, folderKeys, time ->
                        if (scopeSaving) return@BucketScreen
                        scopeSaving = true
                        scope.launch {
                            val previousEffective = folderProjection.effectiveBuckets
                            val prevSince = if (savedRead is ScopeRead.Saved) savedSince else null
                            val since = sinceToSave(time, prevSince, System.currentTimeMillis())
                            val pendingToAdd = folderKeys.filter { pendingFolderUris.contains(it) }
                            val prepared = withContext(Dispatchers.IO) {
                                val addedIds = ArrayList<String>()
                                val idByUri = HashMap<String, String>()
                                for (raw in pendingToAdd) {
                                    val added = com.hawkeyexb.ppass.backup.folder.FolderAccess.addFolder(context, android.net.Uri.parse(raw))
                                    if (added == null) {
                                        addedIds.forEach { runCatching { com.hawkeyexb.ppass.backup.folder.FolderAccess.removeFolder(context, it) } }
                                        return@withContext null
                                    }
                                    addedIds += added
                                    idByUri[raw] = added
                                }
                                val current = folderRegistry.allRecords()
                                val selected = resolveFolderBucketIds(folderKeys, idByUri, current)
                                Triple(selected, current, addedIds)
                            }
                            if (prepared == null) {
                                foldersError = R.string.folder_add_failed
                                scopeSaving = false
                                return@launch
                            }
                            val sel = selectedAlbumIds.filterNot { com.hawkeyexb.ppass.backup.folder.isFolderId(it) }.toSet() + prepared.first
                            val allCurrent = (list.map { it.id } +
                                (savedRead as? ScopeRead.Saved)?.ids.orEmpty().filterNot { com.hawkeyexb.ppass.backup.folder.isFolderId(it) } +
                                prepared.second.map { it.bucketId }).toSet()
                            val saved = settingsWriter.write("backupScope", sel.size, R.string.scope_save_failed) {
                                scopeStore.saveScope(selected = sel, allCurrent = allCurrent, sinceSec = since,)
                            }
                            if (!saved) {
                                withContext(Dispatchers.IO) {
                                    prepared.third.forEach { runCatching { com.hawkeyexb.ppass.backup.folder.FolderAccess.removeFolder(context, it) } }
                                }
                                scopeSaving = false
                                return@launch
                            }
                            val added = if (previousEffective == null) sel else sel - previousEffective
                            pendingFolderUris = arrayListOf()
                            folderRevision++
                            scopeSaving = false
                            val settings = BackupSettings(context.filesDir).load()
                            val constraintsSatisfied = !settings.wifiOnly || isOnUnmetered(context)
                            if (s.firstTime) {
                                rulePrefs.set(true)
                                ruleOn = true
                                markDecided(s.pairing, "scope")
                                settingsWriter.write("autoBackup", false) { disableAutoBackup(context) }
                                requestFlowScopeBackfillAndWake(context, constraintsSatisfied)
                            } else if (added.isNotEmpty() || sinceWidened(prevSince, since)) {
                                requestFlowScopeBackfillAndWake(context, constraintsSatisfied)
                            }
                            triggerUserPresentBackup(context)
                            screen = Screen.Home(s.pairing)
                        }
                    },
                    onCancel = {
                        if (!scopeSaving) {
                            screen = if (s.firstTime) Screen.Decision(s.pairing) else Screen.Home(s.pairing)
                        }
                    },
                )
            }
        }
    }
    SnackbarHost(
        hostState = snackbarHostState,
        modifier = Modifier
            .align(Alignment.BottomCenter)
            .safeDrawingPadding()
            .padding(16.dp),
    ) { data ->
        Snackbar(
            containerColor = PPColor.Ink,
            contentColor = PPColor.Paper,
            shape = RoundedCornerShape(PPSize.RadiusControl),
        ) {
            Text(
                data.visuals.message,
                style = androidx.compose.material3.MaterialTheme.typography.bodyMedium,
            )
        }
    }
    }
}

// shouldShowRequestPermissionRationale 将「从未申请」与「永久拒绝」均返回 false，需结合本地发射记录区分
internal fun canPromptForFullMediaAccess(context: Context): Boolean {
    val activity = context as? android.app.Activity
    val primary = requiredMediaPermissions().first()
    val rationale: Boolean? = activity?.let {
        androidx.core.app.ActivityCompat.shouldShowRequestPermissionRationale(it, primary)
    }
    return systemCanPromptAlbumAccess(
        requestedOnce = com.hawkeyexb.ppass.backup.AlbumAccessPromptPrefs(context).requestedOnce(
            photoGranted = ContextCompat.checkSelfPermission(context, primary) ==
                PackageManager.PERMISSION_GRANTED,
            rationale = rationale,
        ),
        rationale = rationale == true,
    )
}

private fun requiredMediaPermissions(): List<String> =
    if (Build.VERSION.SDK_INT >= 33) {
        listOf(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
        )
    } else {
        listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

private fun withMediaLocation(needed: List<String>): Array<String> =
    (if (Build.VERSION.SDK_INT >= 29) needed + Manifest.permission.ACCESS_MEDIA_LOCATION else needed).toTypedArray()

private fun hasNotificationPermission(context: Context): Boolean =
    if (Build.VERSION.SDK_INT >= 33) {
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    } else {
        true
    }

private fun mediaAccess(context: Context): MediaAccess =
    com.hawkeyexb.ppass.backup.currentMediaAccess(context)

private fun openAppDetailsSettings(context: Context) {
    val intent = android.content.Intent(
        android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
        android.net.Uri.fromParts("package", context.packageName, null),
    ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
    context.startActivity(intent)
}

private fun deviceName(context: Context): String {
    val resolver = context.contentResolver
    return pickDeviceName(
        globalName = runCatching { Settings.Global.getString(resolver, Settings.Global.DEVICE_NAME) }.getOrNull(),
        bluetoothName = runCatching { Settings.Secure.getString(resolver, "bluetooth_name") }.getOrNull(),
        model = Build.MODEL,
    )
}

private fun notifyUnpairOnce(client: DaemonClient, pairing: Pairing): suspend () -> Unit {
    val tag = "desktop=${pairing.daemonNodeId.take(8)}"
    val pairingId = pairing.pairingId
    val peer = runCatching { parsePeerAddrToken(pairing.daemonAddrToken) }.getOrNull()
    return {
        if (peer == null) {
            PLog.w("PPassDisconnect", "unpair: $tag address unreadable, not sent")
        } else {
            val reply = sendUnpairNoticeOnce { client.unpair(peer, pairingId) }
            when {
                reply == null -> PLog.i("PPassDisconnect", "unpair: $tag unreachable, not retried")
                reply.ok -> PLog.i("PPassDisconnect", "unpair: $tag acknowledged")
                else -> PLog.i("PPassDisconnect", "unpair: $tag rejected code=${reply.error?.code}, not retried")
            }
        }
    }
}

internal fun clearLocalPairingLogged(context: Context, pairing: Pairing) {
    try {
        clearLocalPairing(context, pairing)
    } catch (e: Exception) {
        PLog.w("PPassDisconnect", "disconnect manifest failed; leaving anyway", e)
    }
}

private fun clearLocalPairing(
    context: Context,
    pairing: Pairing,
) {
    val work = WorkManager.getInstance(context)
    applyDisconnectManifest(
        context.filesDir,
        context.cacheDir,
        object : DisconnectRuntime {
            override fun stopFlowRuntime() = clearFlowRuntime(context, pairing.daemonNodeId)
            override fun cancelUniqueWork(name: String) {
                work.cancelUniqueWork(name)
            }
            override fun cancelMediaWatch() = com.hawkeyexb.ppass.backup.cancelMediaWatch(context)
            override fun clearPreviewCache() = evictPhotoPreviews()
        },
    )
    com.hawkeyexb.ppass.backup.picked.PickedUploads.discardAll(context)
    context.filesDir.parentFile?.let { dataDir ->
        unregisteredStatePaths(dataDir).takeIf { it.isNotEmpty() }?.let {
            PLog.w("PPassDisconnect", "unregistered app state (register in DisconnectState): $it")
        }
    }
}
