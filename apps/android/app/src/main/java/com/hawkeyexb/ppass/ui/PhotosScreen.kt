// T-055 Photos tab — the design file's timeline: month sections are a
// later pass; this edition is the honest core: a 3-column grid of the
// family library (timeline.page), thumbnails over thumb.get, tap for
// the 1024 preview. States speak the meaning colours only.
package com.hawkeyexb.ppass.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.hawkeyexb.ppass.R
import androidx.compose.ui.unit.sp
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

/** Small in-memory thumb cache — 32 MB of decoded bitmaps. */
private val thumbCache = LruCache<String, Bitmap>(32 * 1024 * 1024 / 40_000)

class TimelineLoader(
    private val client: DaemonClient,
    private val daemon: PeerAddrParts,
    /** Idempotent bind with the device identity — the loader may run
     *  before the app's own bind LaunchedEffect (race seen live). */
    private val ensureBound: suspend () -> Unit,
) {
    suspend fun page(cursor: String?): TimelinePage {
        ensureBound()
        val resp = client.call(
            daemon, Methods.TIMELINE_PAGE,
            ProtoJson.encodeToJsonElement(
                TimelineQuery.serializer(),
                TimelineQuery(cursor = cursor, limit = 60),
            ),
        )
        check(resp.ok) { "timeline: ${resp.error?.msgKey}" }
        return ProtoJson.decodeFromJsonElement(TimelinePage.serializer(), resp.result!!)
    }

    suspend fun download(
        hash: String,
        dest: java.io.File,
        onProgress: (Long, Long) -> Unit,
    ): Long {
        ensureBound()
        return client.downloadAsset(daemon, hash, dest, onProgress)
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
        val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        thumbCache.put(key, bmp)
        return bmp
    }
}

/** T-080: 本机确认缓存的 hash 并集（backup-state/<remote>/confirmed.json，
 *  只读不写）——照片页轻过滤器用它区分「仅本机 / 家人的」。proto 无
 *  owner 字段（本卡不准动 proto），这是数据允许的最诚实近似。 */
internal fun confirmedHashesUnder(stateRoot: java.io.File): Set<String> =
    stateRoot.listFiles()?.filter { it.isDirectory }
        ?.flatMap { com.hawkeyexb.ppass.backup.ConfirmedStore(it).load().confirmed }
        ?.toSet() ?: emptySet()

@Composable
fun PhotosScreen(loader: TimelineLoader) {
    var items by remember { mutableStateOf<List<AssetMeta>>(emptyList()) }
    var next by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var opened by remember { mutableStateOf<AssetMeta?>(null) }
    // T-080: 轻过滤器（设计稿：全部 / 仅本机 / 家人的）。
    var filter by remember { mutableStateOf(TimelineFilter.All) }
    val context = androidx.compose.ui.platform.LocalContext.current
    val mine by produceState(initialValue = emptySet<String>()) {
        value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            runCatching {
                confirmedHashesUnder(java.io.File(context.filesDir, "backup-state"))
            }.getOrDefault(emptySet())
        }
    }

    LaunchedEffect(Unit) {
        try {
            val page = loader.page(null)
            items = page.items
            next = page.next
        } catch (t: Throwable) {
            error = t.message
        } finally {
            loading = false
        }
    }

    val current = opened
    if (current != null) {
        // Wire format is the normalized "video"/"photo" (golden snapshot),
        // not a MIME type — keep the prefix check so a raw "video/mp4" from
        // an older daemon routes correctly too.
        if (current.mediaType.startsWith("video")) {
            VideoScreen(loader, current) { opened = null }
        } else {
            PhotoViewer(loader, current) { opened = null }
        }
        return
    }

    Column(Modifier.fillMaxSize().background(PPColor.Paper)) {
        Row(
            Modifier.fillMaxWidth().padding(24.dp, 18.dp, 24.dp, 10.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.Bottom,
        ) {
            Text(
                stringResource(R.string.photos_title), fontSize = 30.sp,
                fontFamily = FontFamily.Serif, color = PPColor.Ink,
            )
            Text(
                stringResource(R.string.photos_count_dedup, items.size),
                fontSize = 14.sp, color = PPColor.Ink40,
            )
        }

        // T-080: 轻过滤器 chips（设计稿样式:胶囊,选中=墨底纸字）。
        Row(
            Modifier.fillMaxWidth().padding(20.dp, 0.dp, 20.dp, 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FilterChip(stringResource(R.string.chip_all), filter == TimelineFilter.All) {
                filter = TimelineFilter.All
            }
            FilterChip(stringResource(R.string.chip_local), filter == TimelineFilter.LocalOnly) {
                filter = TimelineFilter.LocalOnly
            }
            FilterChip(stringResource(R.string.chip_family), filter == TimelineFilter.Family) {
                filter = TimelineFilter.Family
            }
        }

        val shown = filterTimeline(items, filter, mine) { it.hash }
        when {
            loading -> Center(stringResource(R.string.photos_loading))
            error != null -> Center(
                stringResource(R.string.photos_unreachable) + "\n(${error?.take(100)})"
            )
            items.isEmpty() -> Center(stringResource(R.string.photos_empty))
            shown.isEmpty() -> Center(stringResource(R.string.photos_filter_empty))
            else -> LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                modifier = Modifier.fillMaxSize().padding(horizontal = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                // Month sections: the design's timeline shape.
                for ((month, group) in groupByMonth(shown)) {
                    item(key = "hdr-$month", span = { GridItemSpan(3) }) {
                        Text(
                            month,
                            fontSize = 18.sp, fontFamily = FontFamily.Serif,
                            color = PPColor.Ink,
                            modifier = Modifier.padding(8.dp, 16.dp, 8.dp, 6.dp),
                        )
                    }
                    items(group, key = { it.hash }) { asset ->
                        ThumbCell(loader, asset) { opened = asset }
                    }
                }
                if (next != null) {
                    item(key = "pager") {
                        LaunchedEffect(next) {
                            try {
                                val page = loader.page(next)
                                items = items + page.items
                                next = page.next
                            } catch (_: Throwable) {
                                next = null
                            }
                        }
                    }
                }
            }
        }
    }
}

/** taken_at (ms) → "2026年7月"-style month label using the device locale. */
private fun groupByMonth(items: List<AssetMeta>): List<Pair<String, List<AssetMeta>>> {
    val fmt = java.text.SimpleDateFormat("yyyy.MM", java.util.Locale.getDefault())
    return items.groupBy { fmt.format(java.util.Date(it.takenAt * 1000)) }
        .entries.map { it.key to it.value }
}

@Composable
private fun ThumbCell(loader: TimelineLoader, asset: AssetMeta, onOpen: () -> Unit) {
    val bmp by produceState<Bitmap?>(initialValue = thumbCache.get("${asset.hash}/256"), asset.hash) {
        if (value == null) value = runCatching { loader.thumb(asset.hash, ThumbSize.S256) }.getOrNull()
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
    }
}

@Composable
private fun PhotoViewer(loader: TimelineLoader, asset: AssetMeta, onClose: () -> Unit) {
    val bmp by produceState<Bitmap?>(initialValue = null, asset.hash) {
        value = runCatching { loader.thumb(asset.hash, ThumbSize.S1024) }.getOrNull()
            ?: thumbCache.get("${asset.hash}/256")
    }
    Column(Modifier.fillMaxSize().background(PPColor.SurfaceDark).padding(16.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(
                stringResource(R.string.back), fontSize = 17.sp, color = PPColor.Paper,
                modifier = Modifier.clickable(onClick = onClose).padding(10.dp),
            )
            Text(
                "${asset.width}×${asset.height}", fontSize = 14.sp,
                color = PPColor.PaperDim, modifier = Modifier.padding(10.dp),
            )
        }
        Spacer(Modifier.height(8.dp))
        Box(Modifier.fillMaxSize().clip(RoundedCornerShape(20.dp)), contentAlignment = Alignment.Center) {
            val b = bmp
            if (b != null) {
                Image(
                    bitmap = b.asImageBitmap(), contentDescription = null,
                    modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Fit,
                )
            } else {
                Text(stringResource(R.string.photos_loading), color = PPColor.PaperDim, fontSize = 16.sp)
            }
        }
    }
}

/** 设计稿的过滤胶囊：高 36,圆角 999,选中=墨底纸字,未选=亚麻底墨字。 */
@Composable
private fun FilterChip(label: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.height(36.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(if (selected) PPColor.Ink else PPColor.Linen)
            .clickable(onClick = onClick)
            .padding(horizontal = 15.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
            color = if (selected) PPColor.Paper else PPColor.Ink60,
        )
    }
}

@Composable
private fun Center(text: String) {
    Box(Modifier.fillMaxSize().padding(34.dp), contentAlignment = Alignment.Center) {
        Text(
            text, fontSize = PPSize.BodyMin, lineHeight = 26.sp,
            color = PPColor.Ink40,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
    }
}
