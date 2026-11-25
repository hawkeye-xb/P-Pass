package com.hawkeyexb.ppass.ui

import android.content.Context
import android.graphics.Bitmap
import android.util.Base64
import android.util.LruCache
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.AndroidOriginalReader
import com.hawkeyexb.ppass.backup.LocalFirstLoader
import com.hawkeyexb.ppass.backup.LocalFirstOriginals
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.readLocalSourceIndex
import com.hawkeyexb.ppass.log.PLog
import com.hawkeyexb.ppass.proto.AssetMeta
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.proto.ThumbData
import com.hawkeyexb.ppass.proto.ThumbGet
import com.hawkeyexb.ppass.proto.ThumbSize
import com.hawkeyexb.ppass.proto.TimelinePage
import com.hawkeyexb.ppass.proto.TimelineQuery
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.PeerAddrParts
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import me.saket.telephoto.zoomable.rememberZoomableState
import me.saket.telephoto.zoomable.zoomable

// 红线②：内存缩略图缓存，绝不落盘
internal val thumbCache = LruCache<String, Bitmap>(32 * 1024 * 1024 / 40_000)

internal fun evictPhotoPreviews() = thumbCache.evictAll()

internal val SUBSCRIBE_RETRY_DELAYS_MS = longArrayOf(1_000, 2_000, 4_000, 8_000, 15_000, 30_000)
internal const val SUBSCRIBE_WAS_LIVE_MS = 5_000L
internal const val FULL_REFRESH_FALLBACK_MS = 60_000L

// 红线①失效联动：逐出已不在时间线集合中的缩略图
internal fun staleThumbKeys(keys: Collection<String>, currentHashes: Set<String>): List<String> =
    keys.filter { it.substringBefore('/') !in currentHashes }

internal data class SubscribeRetryDecision(
    val nextAttempt: Int,
    val exhausted: Boolean,
    val delayMs: Long?,
)

internal fun nextSubscribeRetry(
    currentAttempt: Int,
    wasLive: Boolean,
    delays: LongArray = SUBSCRIBE_RETRY_DELAYS_MS,
): SubscribeRetryDecision {
    val attempt = if (wasLive) 0 else currentAttempt
    return if (attempt < delays.size) {
        SubscribeRetryDecision(nextAttempt = attempt + 1, exhausted = false, delayMs = delays[attempt])
    } else {
        SubscribeRetryDecision(nextAttempt = attempt, exhausted = true, delayMs = null)
    }
}

class TimelineLoader(
    private val client: DaemonClient,
    private val daemon: PeerAddrParts,
    private val ensureBound: suspend () -> Unit,
) {
    private val knownHashes = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    fun onTimelineRefreshed(hashes: Set<String>) {
        knownHashes.clear()
        knownHashes.addAll(hashes)
        for (key in staleThumbKeys(thumbCache.snapshot().keys, knownHashes)) {
            thumbCache.remove(key)
        }
    }

    fun onTimelineAppended(hashes: Set<String>) {
        knownHashes.addAll(hashes)
    }

    suspend fun subscribe(onConnected: suspend () -> Unit = {}, onInvalidated: suspend () -> Unit) {
        ensureBound()
        client.subscribeTimeline(daemon, onConnected = onConnected, onInvalidated = onInvalidated)
    }

    suspend fun page(cursor: String?): TimelinePage {
        ensureBound()
        val resp = client.call(
            daemon, Methods.TIMELINE_PAGE,
            ProtoJson.encodeToJsonElement(
                TimelineQuery.serializer(),
                TimelineQuery(cursor = cursor, limit = 60),
            ),
        )
        check(resp.ok) { "timeline rejected: ${resp.error?.reason}" }
        return ProtoJson.decodeFromJsonElement(TimelinePage.serializer(), resp.result!!)
    }

    suspend fun download(
        hash: String,
        dest: java.io.File,
        expectedBytes: Long = 0,
        onProgress: (Long, Long) -> Unit,
    ): Long {
        ensureBound()
        return client.downloadAsset(daemon, hash, dest, expectedBytes, onProgress)
    }

    suspend fun thumb(hash: String, size: ThumbSize): Bitmap? {
        val key = "$hash/${size.px}"
        thumbCache.get(key)?.let { return it }
        ensureBound()
        val resp = client.call(
            daemon, Methods.THUMB_GET,
            ProtoJson.encodeToJsonElement(ThumbGet.serializer(), ThumbGet(hash, size)),
        )
        if (!resp.ok) return null
        val data = ProtoJson.decodeFromJsonElement(ThumbData.serializer(), resp.result!!)
        val bytes = Base64.decode(data.jpegBase64, Base64.DEFAULT)
        val bmp = decodeDesktopThumb(bytes, hash, size.px) ?: return null
        thumbCache.put(key, bmp)
        return bmp
    }

    fun localNodeIdHex(): String? = client.nodeIdHex()
}

internal fun filterAssetsBySource(
    assets: List<AssetMeta>,
    filter: TimelineFilter,
    localNodeId: String?,
): List<AssetMeta> = when (filter) {
    TimelineFilter.All -> assets
    TimelineFilter.LocalOnly -> localNodeId?.let { local ->
        assets.filter { it.sourceDeviceOrNull() == local }
    } ?: emptyList()
    TimelineFilter.Family -> localNodeId?.let { local ->
        assets.filter { it.sourceDeviceOrNull()?.let { source -> source != local } == true }
    } ?: emptyList()
}

private fun AssetMeta.sourceDeviceOrNull(): String? = srcDevice?.takeIf { it.isNotBlank() }

internal data class PhotosTimelineChrome(
    val showReconnecting: Boolean,
    val showExhaustedRetry: Boolean,
    val showTimelineError: Boolean,
)

internal fun photosTimelineChrome(
    connection: ConnectionState,
    error: String?,
): PhotosTimelineChrome =
    if (connection.needsRepair) {
        PhotosTimelineChrome(showReconnecting = false, showExhaustedRetry = false, showTimelineError = false)
    } else {
        PhotosTimelineChrome(
            showReconnecting = connection.status == ConnectionState.Status.Reconnecting,
            showExhaustedRetry = connection.status == ConnectionState.Status.Offline,
            showTimelineError = error != null,
        )
    }

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun PhotosScreen(
    holder: TimelineSubscriptionHolder,
    onViewerOpenChange: (Boolean) -> Unit = {},
    connection: ConnectionState = ConnectionState(ConnectionState.Status.Unknown),
    onReconnect: () -> Unit = {},
    guide: PhotosGuide = PhotosGuide.None,
    computerName: String = "",
    onGuideAction: (PhotosGuide) -> Unit = {},
    guideActionGoesToSettings: Boolean = false,
    onGuideDismiss: () -> Unit = {},
    scopeEmptyHint: String? = null,
) {
    val loader = holder.loader
    val localMedia = rememberLocalSourceLoader(loader, LocalContext.current)
    val items = holder.items
    val next = holder.next
    val loading = holder.loading
    val error = holder.error
    LaunchedEffect(error) { error?.let { PLog.w("PPassTimeline", "photos tab load failed: $it") } }
    val chrome = photosTimelineChrome(connection, error)

    var viewer by remember { mutableStateOf<MediaViewerSession?>(null) }
    var filter by remember { mutableStateOf(TimelineFilter.All) }
    val localNodeId = loader?.localNodeIdHex()
    val shown = filterAssetsBySource(items, filter, localNodeId)
    val updateViewer: (MediaViewerSession?) -> Unit = { next ->
        val resolved = if (loader != null) next else null
        viewer = resolved
        onViewerOpenChange(resolved != null)
    }
    SideEffect {
        if (viewer != null && loader == null) updateViewer(null)
    }
    androidx.compose.runtime.DisposableEffect(Unit) {
        onDispose { onViewerOpenChange(false) }
    }
    val currentViewer = viewer
    if (currentViewer != null && loader != null) {
        BackHandler(
            enabled = viewerBackAction(viewerOpen = viewer != null) == ViewerBackAction.CloseViewer,
        ) {
            updateViewer(null)
        }
        MediaViewer(loader, localMedia, currentViewer, localNodeId) { updateViewer(null) }
        return
    }

    Column(Modifier.fillMaxSize().background(PPColor.Paper)) {
        androidx.compose.material3.ProvideTextStyle(
            androidx.compose.material3.LocalTextStyle.current.copy(fontFamily = PPFont.Sans),
        ) {
        Spacer(Modifier.height(8.dp))

        if (connection.needsRepair) {
            Surface(
                color = PPColor.ActBg,
                shape = RoundedCornerShape(PPSize.RadiusCard),
                border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Act.copy(alpha = 0.3f)),
                modifier = Modifier.fillMaxWidth().padding(PPSize.PageGutter, 0.dp, PPSize.PageGutter, 12.dp),
            ) {
                Column(Modifier.padding(18.dp)) {
                    Text(
                        stringResource(R.string.photos_lost_title),
                        fontSize = 16.sp, fontWeight = FontWeight.Bold, color = PPColor.Act,
                        modifier = Modifier.semantics {
                            heading()
                            liveRegion = LiveRegionMode.Polite
                        },
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        if (connection.daysUnreachable != null) {
                            pluralStringResource(R.plurals.photos_lost_body_days, connection.daysUnreachable, connection.daysUnreachable)
                        } else {
                            stringResource(R.string.photos_lost_body_unknown)
                        },
                        fontSize = 14.sp, lineHeight = 21.sp, color = PPColor.Ink60,
                    )
                    Spacer(Modifier.height(12.dp))
                    androidx.compose.material3.Button(
                        onClick = onReconnect,
                        modifier = Modifier.fillMaxWidth().height(PPSize.TapMin),
                        shape = RoundedCornerShape(PPSize.RadiusControl),
                        colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                            containerColor = PPColor.Ink, contentColor = PPColor.Paper,
                        ),
                    ) {
                        Text(
                            stringResource(R.string.photos_lost_action),
                            fontSize = 17.sp, fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
        }

        if (guide != PhotosGuide.None) {
            LaunchedEffect(guide) { PLog.i("PPassGuide", "photos-guide: shown ${guide.logName}") }
            PhotosGuideCard(
                guide, computerName,
                goesToSettings = guideActionGoesToSettings,
                onAction = { onGuideAction(guide) },
                onDismiss = onGuideDismiss,
                modifier = Modifier.fillMaxWidth().padding(PPSize.PageGutter, 0.dp, PPSize.PageGutter, 12.dp),
            )
        }

        FlowRow(
            Modifier.fillMaxWidth().padding(PPSize.PageGutter, 0.dp, PPSize.PageGutter, 12.dp).zIndex(1f),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            PhotoFilterChip(stringResource(R.string.chip_all), filter == TimelineFilter.All) {
                filter = TimelineFilter.All
            }
            PhotoFilterChip(stringResource(R.string.chip_local), filter == TimelineFilter.LocalOnly) {
                filter = TimelineFilter.LocalOnly
            }
            PhotoFilterChip(stringResource(R.string.chip_family), filter == TimelineFilter.Family) {
                filter = TimelineFilter.Family
            }
        }

        if (chrome.showReconnecting) {
            Text(
                stringResource(R.string.photos_live_reconnecting),
                fontSize = 13.sp, color = PPColor.Ink40,
                modifier = Modifier.fillMaxWidth().padding(PPSize.PageGutter, 0.dp, PPSize.PageGutter, 12.dp)
                    .semantics { liveRegion = LiveRegionMode.Polite },
            )
        }

        if (chrome.showExhaustedRetry) {
            Row(
                Modifier.fillMaxWidth().padding(PPSize.PageGutter, 0.dp, PPSize.PageGutter, 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    stringResource(R.string.photos_live_disconnected),
                    fontSize = 13.sp, color = PPColor.Ink40,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
                Text(
                    stringResource(R.string.photos_live_retry),
                    fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = PPColor.Ink,
                    modifier = Modifier.clickable { holder.retry() }.padding(6.dp),
                )
            }
        }

        if (scopeEmptyHint != null) {
            LaunchedEffect(Unit) { PLog.i("PPassGuide", "photos-guide: scope empty hint") }
            Text(
                scopeEmptyHint,
                fontSize = 13.sp, color = PPColor.Ink40,
                modifier = Modifier.fillMaxWidth().padding(PPSize.PageGutter, 0.dp, PPSize.PageGutter, 12.dp),
            )
        }

        when {
            loader == null -> Center(stringResource(R.string.photos_loading))
            loading -> Center(stringResource(R.string.photos_loading))
            error != null && chrome.showTimelineError -> Center(stringResource(R.string.photos_unreachable), live = true)
            error != null && items.isEmpty() -> Unit
            items.isEmpty() -> Center(stringResource(R.string.home_empty_albums))
            shown.isEmpty() -> Center(stringResource(R.string.photos_filter_empty))
            else -> LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                modifier = Modifier.fillMaxSize().padding(horizontal = PPSize.PageGutter),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                for ((month, group) in groupByMonth(shown)) {
                    item(key = "hdr-$month", span = { GridItemSpan(3) }) {
                        Text(
                            month,
                            fontSize = 18.sp, fontFamily = PPFont.Serif,
                            color = PPColor.Ink,
                            modifier = Modifier.padding(0.dp, 16.dp, 0.dp, 6.dp),
                        )
                    }
                    items(group, key = { it.hash }) { asset ->
                        ThumbCell(
                            localMedia, asset,
                            isMine = localNodeId?.let { asset.sourceDeviceOrNull() == it } == true,
                        ) {
                            updateViewer(MediaViewerSession.open(shown, asset.hash))
                        }
                    }
                }
                if (next != null) {
                    item(key = "pager") {
                        LaunchedEffect(next) {
                            next?.let { holder.appendNextPage(it) }
                        }
                    }
                }
            }
        }
        }
    }
}

@Composable
private fun rememberLocalSourceLoader(
    loader: TimelineLoader?,
    context: Context,
): LocalFirstLoader<Bitmap> {
    val app = context.applicationContext
    val originals = remember(app) {
        LocalFirstOriginals(
            reader = AndroidOriginalReader(app),
            loadIndex = { withContext(Dispatchers.IO) { readLocalSourceIndex() } },
        )
    }
    return remember(loader, originals) {
        LocalFirstLoader(
            local = originals,
            remoteThumb = { hash, size -> loader?.thumb(hash, size) },
            remoteDownload = { hash, dest -> loader?.download(hash, dest) { _, _ -> } },
        )
    }
}

private fun groupByMonth(items: List<AssetMeta>): List<Pair<String, List<AssetMeta>>> {
    val fmt = java.text.SimpleDateFormat("yyyy.MM", java.util.Locale.getDefault())
    return items.groupBy { fmt.format(java.util.Date(it.takenAt * 1000)) }
        .entries.map { it.key to it.value }
}

@Composable
private fun ThumbCell(
    localMedia: LocalFirstLoader<Bitmap>,
    asset: AssetMeta,
    isMine: Boolean,
    onOpen: () -> Unit,
) {
    @Suppress("ProduceStateDoesNotAssignValue")
    val bmp by produceState<Bitmap?>(initialValue = thumbCache.get("${asset.hash}/256"), asset.hash) {
        if (value == null) {
            value = runCatching { localMedia.thumb(asset, ThumbSize.S256, isMine) }.getOrNull()
        }
    }
    Box(
        Modifier.aspectRatio(1f).clip(RoundedCornerShape(10.dp))
            .background(PPColor.Linen).clickable(onClick = onOpen),
        contentAlignment = Alignment.Center,
    ) {
        val b = bmp
        if (b != null) {
            Image(
                bitmap = b.asImageBitmap(), contentDescription = asset.hash.take(8),
                modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop,
            )
        }
        if (asset.mediaType.startsWith("video")) {
            VideoBadge(Modifier.align(Alignment.BottomEnd).padding(6.dp))
        }
    }
}

@Composable
private fun VideoBadge(modifier: Modifier = Modifier) {
    androidx.compose.foundation.Canvas(modifier.size(22.dp)) {
        val r = size.minDimension / 2f
        drawCircle(color = androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.45f), radius = r)
        val triSize = r * 0.9f
        val cx = center.x + r * 0.08f
        val path = androidx.compose.ui.graphics.Path().apply {
            moveTo(cx - triSize * 0.45f, center.y - triSize * 0.55f)
            lineTo(cx - triSize * 0.45f, center.y + triSize * 0.55f)
            lineTo(cx + triSize * 0.55f, center.y)
            close()
        }
        drawPath(path, color = androidx.compose.ui.graphics.Color.White)
    }
}

private enum class ViewerOp { Save, Share }

@Composable
internal fun attributionText(isMine: Boolean, takenAtSeconds: Long): String {
    val date = java.text.SimpleDateFormat("MM-dd", java.util.Locale.getDefault())
        .format(java.util.Date(takenAtSeconds * 1000))
    return if (isMine) {
        stringResource(R.string.attribution_mine, date)
    } else {
        stringResource(R.string.attribution_family, date)
    }
}

// 协议层 AssetMeta.width/height 用 0 表示数据库 NULL，<= 0 即未知尺寸
internal fun dimensionsText(width: Int, height: Int): String? =
    if (width > 0 && height > 0) "$width×$height" else null

@Composable
private fun MediaViewer(
    loader: TimelineLoader,
    localMedia: LocalFirstLoader<Bitmap>,
    session: MediaViewerSession,
    localNodeId: String?,
    onClose: () -> Unit,
) {
    val pagerState = rememberPagerState(
        initialPage = session.initialPage,
        pageCount = { session.assets.size },
    )
    HorizontalPager(
        state = pagerState,
        modifier = Modifier.fillMaxSize(),
        beyondViewportPageCount = 1,
    ) { page ->
        val asset = session.assets[page]
        val isMine = localNodeId?.let { asset.sourceDeviceOrNull() == it } == true
        if (asset.mediaType.startsWith("video")) {
            VideoScreen(loader, asset, isMine = isMine, onClose = onClose)
        } else {
            PhotoViewer(localMedia, asset, isMine = isMine, onClose = onClose)
        }
    }
}

@Composable
private fun PhotoViewer(
    localMedia: LocalFirstLoader<Bitmap>,
    asset: AssetMeta,
    isMine: Boolean,
    onClose: () -> Unit,
) {
    // 红线③：大图查看与导出仅用内存缓存或临时文件即看即清
    var previewMissing by remember(asset.hash) { mutableStateOf(false) }
    @Suppress("ProduceStateDoesNotAssignValue")
    val bmp by produceState<Bitmap?>(initialValue = null, asset.hash) {
        value = runCatching { localMedia.thumb(asset, ThumbSize.S1024, isMine) }.getOrNull()
            ?: thumbCache.get("${asset.hash}/256")
        previewMissing = value == null
    }
    val zoomableState = rememberZoomableState()
    var pullDownPx by remember(asset.hash) { mutableStateOf(0f) }
    val pullThresholdPx = with(LocalDensity.current) { 96.dp.toPx() }
    val atMinimumZoom = (zoomableState.zoomFraction ?: 0f) <= 0f
    LaunchedEffect(atMinimumZoom) {
        if (!atMinimumZoom) pullDownPx = 0f
    }
    val pullToDismissModifier = Modifier.pointerInput(asset.hash, atMinimumZoom) {
        if (atMinimumZoom) {
            detectVerticalDragGestures(
                onDragStart = { pullDownPx = 0f },
                onVerticalDrag = { change, dragAmount ->
                    pullDownPx = (pullDownPx + dragAmount).coerceAtLeast(0f)
                    change.consume()
                },
                onDragCancel = { pullDownPx = 0f },
                onDragEnd = {
                    if (canDismissFromPull(
                        zoomFraction = zoomableState.zoomFraction ?: 0f,
                        dragPx = pullDownPx,
                        thresholdPx = pullThresholdPx,
                    )) {
                        onClose()
                    }
                    pullDownPx = 0f
                },
            )
        }
    }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }
    val share = remember { shareDir(context) }

    val openLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) {
        share.listFiles()?.forEach { it.delete() }
    }

    fun runAssetAction(op: ViewerOp) {
        if (busy) return
        busy = true
        notice = null
        scope.launch {
            try {
                share.listFiles()?.forEach { it.delete() }
                val file = localMedia.fetchOriginal(asset, isMine, File(share, "asset-${asset.hash.take(16)}"))
                when (op) {
                    ViewerOp.Save -> {
                        val saved = saveToGallery(context, file, asset)
                        file.delete()
                        notice = context.getString(
                            if (saved.alreadyExisted) R.string.already_in_gallery
                            else R.string.saved_to_gallery
                        )
                    }
                    ViewerOp.Share -> {
                        openLauncher.launch(
                            shareIntent(
                                context, file, asset,
                                context.getString(R.string.share_to),
                            ),
                        )
                    }
                }
            } catch (_: android.content.ActivityNotFoundException) {
                notice = context.getString(R.string.no_app_for_file)
            } catch (_: Throwable) {
                notice = context.getString(R.string.share_download_failed)
            } finally {
                busy = false
            }
        }
    }

    Box(Modifier.fillMaxSize().background(PPColor.SurfaceDark)) {
        androidx.compose.material3.ProvideTextStyle(
            androidx.compose.material3.LocalTextStyle.current.copy(fontFamily = PPFont.Sans),
        ) {
        Column(Modifier.fillMaxSize().padding(16.dp)) {
        val chromeSpec = viewerChromeSpecOf(busy = busy)
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onClose) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = stringResource(chromeSpec.closeDescriptionRes),
                    tint = PPColor.Paper,
                )
            }
            dimensionsText(asset.width, asset.height)?.let {
                Text(
                    it, fontSize = 14.sp,
                    color = PPColor.PaperDim, modifier = Modifier.padding(10.dp),
                )
            }
        }
        Text(
            attributionText(isMine, asset.takenAt),
            fontSize = 13.sp, color = PPColor.PaperDim,
            modifier = Modifier.padding(horizontal = 10.dp),
        )
        Spacer(Modifier.height(8.dp))
        Box(
            Modifier.fillMaxWidth().weight(1f).clip(RoundedCornerShape(20.dp)),
            contentAlignment = Alignment.Center,
        ) {
            val b = bmp
            if (b != null) {
                Image(
                    bitmap = b.asImageBitmap(), contentDescription = null,
                    modifier = Modifier
                        .fillMaxSize()
                        .graphicsLayer { translationY = pullDownPx }
                        .then(pullToDismissModifier)
                        .zoomable(zoomableState),
                    contentScale = ContentScale.Fit,
                )
            } else {
                Text(
                    stringResource(if (previewMissing) R.string.preview_unavailable else R.string.photos_loading),
                    color = PPColor.PaperDim, fontSize = 16.sp,
                )
            }
        }
        notice?.let { ViewerNoticeText(it) }
        Row(
            Modifier.fillMaxWidth().padding(top = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            ViewerAction(
                label = stringResource(R.string.save_to_gallery),
                enabled = chromeSpec.actionsEnabled,
                onClick = { runAssetAction(ViewerOp.Save) },
                modifier = Modifier.weight(1f),
            )
            ViewerAction(
                label = stringResource(R.string.share),
                enabled = chromeSpec.actionsEnabled,
                onClick = { runAssetAction(ViewerOp.Share) },
                modifier = Modifier.weight(1f),
            )
        }
        }
        }
    }
}

@Composable
internal fun ViewerAction(
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    leadingIcon: androidx.compose.ui.graphics.vector.ImageVector? = null,
    height: androidx.compose.ui.unit.Dp = 44.dp,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.heightIn(min = height),
        shape = RoundedCornerShape(999.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = PPColor.Paper,
            contentColor = PPColor.Ink,
            disabledContainerColor = PPColor.PaperDim.copy(alpha = 0.35f),
            disabledContentColor = PPColor.PaperDim,
        ),
        contentPadding = PaddingValues(horizontal = 20.dp),
    ) {
        if (leadingIcon != null) {
            Icon(leadingIcon, contentDescription = null)
            Spacer(Modifier.size(6.dp))
        }
        Text(
            label,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            color = LocalContentColor.current,
        )
    }
}

@Composable
internal fun PhotoFilterChip(label: String, selected: Boolean, onClick: () -> Unit) {
    androidx.compose.material3.FilterChip(
        selected = selected,
        onClick = onClick,
        label = {
            Text(
                label, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                color = if (selected) PPColor.Paper else PPColor.Ink60,
            )
        },
        shape = RoundedCornerShape(999.dp),
        colors = androidx.compose.material3.FilterChipDefaults.filterChipColors(
            containerColor = PPColor.Linen,
            selectedContainerColor = PPColor.Ink,
            labelColor = PPColor.Ink60,
            selectedLabelColor = PPColor.Paper,
        ),
        border = null,
        modifier = Modifier.heightIn(min = 36.dp),
    )
}

internal enum class PhotosGuide(val logName: String) {
    EnableScope("scope"),
    EnableBackground("background"),
    None("none"),
}

internal data class GuideFacts(
    val scopeOn: Boolean,
    val firstUploaded: Boolean,
    val backgroundOn: Boolean,
    val finished: Boolean,
)

internal fun photosGuideOf(f: GuideFacts): PhotosGuide = when {
    f.finished -> PhotosGuide.None
    !f.scopeOn -> PhotosGuide.EnableScope
    f.firstUploaded && !f.backgroundOn -> PhotosGuide.EnableBackground
    else -> PhotosGuide.None
}

internal fun scopeEmptyHintShown(f: GuideFacts, inScope: Long?): Boolean = f.scopeOn && inScope == 0L

@Composable
private fun PhotosGuideCard(
    guide: PhotosGuide,
    computerName: String,
    goesToSettings: Boolean,
    onAction: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier,
) {
    val label = if (guide == PhotosGuide.EnableScope && goesToSettings) R.string.auto_backup_blocked_action else R.string.photos_guide_enable
    val text = when (guide) {
        PhotosGuide.EnableScope -> stringResource(R.string.photos_guide_scope)
        PhotosGuide.EnableBackground -> stringResource(R.string.photos_guide_background)
        PhotosGuide.None -> return
    }
    Box(modifier) {
        ClosableNoticeCard(
            body = text,
            actionLabel = stringResource(label),
            onAction = onAction,
            closeLabel = stringResource(R.string.photos_guide_close),
            onClose = onDismiss,
        )
    }
}

@Composable
internal fun ViewerNoticeText(text: String) {
    Text(
        text,
        fontSize = 13.sp,
        color = PPColor.PaperDim,
        modifier = Modifier.padding(4.dp, 8.dp).semantics { liveRegion = LiveRegionMode.Polite },
        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
    )
}

@Composable
private fun Center(text: String, live: Boolean = false) {
    Box(Modifier.fillMaxSize().padding(34.dp), contentAlignment = Alignment.Center) {
        Text(
            text, fontSize = PPSize.BodyMin, lineHeight = 26.sp,
            color = PPColor.Ink40,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            modifier = if (live) Modifier.semantics { liveRegion = LiveRegionMode.Polite } else Modifier,
        )
    }
}
