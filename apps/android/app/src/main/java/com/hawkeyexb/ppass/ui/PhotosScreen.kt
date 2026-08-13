// T-055 Photos tab — the design file's timeline: month sections are a
// later pass; this edition is the honest core: a 3-column grid of the
// family library (timeline.page), thumbnails over thumb.get, tap for
// the 1024 preview. States speak the meaning colours only.
package com.hawkeyexb.ppass.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import android.util.LruCache
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.res.painterResource
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
import kotlinx.coroutines.launch

/**
 * MOB-04 红线②：缩略图缓存 = 内存 LruCache，**绝不落盘**（手机是减负端，
 * 不是第二存储端）。上限按 32MB 估算（≈838 张 256px 解码位图，覆盖常见
 * 家庭库首屏 + 翻页缓冲）；不做设备内存分级——低内存设备由系统缓存压力
 * 自动回收 Bitmap，分级只会引入复杂度。任何改动不得引入磁盘 thumb 缓存
 * （守卫测试 CacheRedlineTest 扫描全工程源码）。
 *
 * UX-10: 全 App 唯一内存缩略图缓存（CacheRedlineTest 断言 LruCache 声明
 * 只能有这一处）——BucketScreen 的相册封面缩略图共用这个实例，key 加
 * `"bucket:"` 前缀（远端 hash 值不含冒号，不会撞车），不为局部化缓存
 * 各开各的内存预算。
 */
internal val thumbCache = LruCache<String, Bitmap>(32 * 1024 * 1024 / 40_000)

/** SYNC-04: 前台订阅断线重连的退避序列——有限次数，不是无限重试
 *  （UX-11 同款哲学）。用完最后一档还是连不上就停下来交给用户。 */
internal val SUBSCRIBE_RETRY_DELAYS_MS = longArrayOf(1_000, 2_000, 4_000, 8_000, 15_000, 30_000)

/** SYNC-04: 连上并撑过这段时间才断——算一次"曾经连上"，退避计数清零
 *  重来，不带着上次失败攒的重试档位（否则长时间正常使用后的偶发断线
 *  会直接跳到大退避档）。 */
internal const val SUBSCRIBE_WAS_LIVE_MS = 5_000L

/** SYNC-04: 订阅之外的整页刷新兜底频率——对齐桌面端已有的 60s 兜底，
 *  远低于原来 15s 轮询，只防真实丢事件场景，不是主通道。 */
internal const val FULL_REFRESH_FALLBACK_MS = 60_000L

/**
 * MOB-04 红线①失效联动的逐出决策（纯函数，JVM 可测）：给定缓存 key
 * 列表与「当前仍在时间线返回集里」的 hash 集合，返回应当逐出的 key。
 * key 格式 = "$hash/$size.px"——hash 相同不同尺寸都保留（都在返回集里）。
 */
internal fun staleThumbKeys(keys: Collection<String>, currentHashes: Set<String>): List<String> =
    keys.filter { it.substringBefore('/') !in currentHashes }

/** SYNC-04: 一次订阅断开之后该怎么做——纯函数，JVM 可测（把状态机从
 *  Compose `LaunchedEffect` 里剥出来，不用起 Compose 测试环境）。
 *  [delayMs] 非空时调用方应该 delay 这么久再重连；`exhausted=true` 时
 *  [delayMs] 为 null，调用方停止静默重试，把状态交给用户（UX-11 哲学：
 *  有界等待→亮错误→交给用户）。*/
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
    // 这次连上并撑过了一小段时间才断——算一次"曾经连上"，退避从头算起，
    // 不带着上次失败攒的重试档位（否则长时间正常使用后的偶发断线会
    // 直接跳到大退避档，体验上像"越用越慢"）。
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
    /** Idempotent bind with the device identity — the loader may run
     *  before the app's own bind LaunchedEffect (race seen live). */
    private val ensureBound: suspend () -> Unit,
) {
    // MOB-04 红线①失效联动：已加载的时间线 hash 集合（分页累计）。
    // onTimelineRefreshed 整页重载时重置集合并逐出不在返回集里的缓存
    // 条目（SYNC-01 对账后 daemon 已删的照片，内存里不能继续闪旧图）；
    // onTimelineAppended 翻页追加只增不逐。
    private val knownHashes = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    /** 时间线整页重载（第一页）——重置已知集合并逐出失效缩略图。 */
    fun onTimelineRefreshed(hashes: Set<String>) {
        knownHashes.clear()
        knownHashes.addAll(hashes)
        for (key in staleThumbKeys(thumbCache.snapshot().keys, knownHashes)) {
            thumbCache.remove(key)
        }
    }

    /** 翻页追加——只增不逐（后页照片仍在库中）。 */
    fun onTimelineAppended(hashes: Set<String>) {
        knownHashes.addAll(hashes)
    }

    /**
     * SYNC-04: 前台常驻订阅——包一层 ensureBound，语义同 [page]/[thumb]。
     * 挂起直到这条订阅结束（对端主动关闭/连接坏了/协程被取消）；抛异常
     * 和正常返回对调用方是同一件事："这次订阅结束了"，按断线退避重连
     * 处理。[onConnected] 在读到第一个帧（订阅确认）时调用一次——调用方
     * 拿它区分"正在重连"和"已经连上"两种状态。[onInvalidated] 收到一次
     * 信号就整页覆盖刷新（不是追加）——这是本卡的核心：SYNC-01 对账
     * 删掉的照片必须真的从时间线消失。
     */
    suspend fun subscribe(onConnected: suspend () -> Unit = {}, onInvalidated: suspend () -> Unit) {
        ensureBound()
        client.subscribeTimeline(daemon, onConnected, onInvalidated)
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

    // SYNC-04：整页重载的共用逻辑——首次加载、订阅收到信号、兜底轮询、
    // 手动重试都走这一条路径。MOB-04 红线①失效联动：整页重载后逐出
    // 不在返回集里的缩略图缓存（SYNC-01 对账后 daemon 已删的照片不再
    // 闪旧图）。
    suspend fun refreshFullPage() {
        val page = loader.page(null)
        items = page.items
        next = page.next
        loader.onTimelineRefreshed(page.items.map { it.hash }.toSet())
    }

    LaunchedEffect(Unit) {
        try {
            refreshFullPage()
        } catch (t: Throwable) {
            error = t.message
        } finally {
            loading = false
        }
    }

    // SYNC-04：前台常驻订阅，取代原来的 15s"仅追加"轮询——收到信号走
    // 整页覆盖语义（refreshFullPage，onTimelineRefreshed 现成的缓存
    // 失效逐出），删除的照片才能真的从时间线消失，不是像原来那样永久
    // 停留到进程重启。断线（含对端主动 finish，比如被吊销）按有限退避
    // 重连；超过重试上限停止静默重试，UI 亮"连不上"状态 + 手动重试
    // 入口（UX-11 同款：有界等待→亮错误→交给用户）。切走这个 tab 时
    // LaunchedEffect 自动取消，订阅连接跟着断（同一条心跳生命周期，
    // 不是另开一套判断在线的逻辑，见 PRES-01）。
    var subscribeAttempt by remember { mutableStateOf(0) }
    var subscribeExhausted by remember { mutableStateOf(false) }
    // 真机验收发现的缺口：原设计重连期间界面完全沉默，只有耗尽之后才
    // 亮提示——用户在飞行模式下什么都看不到，以为是卡死。现在细分成
    // 三态：还没连上第一次(两者皆假) / 已连上安静收听(connected) /
    // 断线重试中(hadFailure，跟 subscribeAttempt 解耦——否则第一次
    // 断线后的第一档退避窗口里，key 还没来得及变，提示会漏出现)。
    var subscribeConnected by remember { mutableStateOf(false) }
    var subscribeHadFailure by remember { mutableStateOf(false) }

    LaunchedEffect(subscribeAttempt) {
        if (subscribeExhausted) return@LaunchedEffect
        subscribeConnected = false
        // REV-01 #5: 计时起点必须是连接真正建立的那一刻，不是 effect
        // 开始（含重连尝试耗时）——否则"建了很久才连上、一连上就断"的
        // 边缘情况会被误判成 wasLive=true（退避档位被错误清零重来）。
        // 没连上过（connectedAt 仍是 null）时 wasLive 恒为 false。
        var connectedAt: Long? = null
        try {
            loader.subscribe(
                onConnected = {
                    subscribeConnected = true
                    subscribeHadFailure = false
                    connectedAt = System.currentTimeMillis()
                },
            ) {
                try {
                    refreshFullPage()
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e // REV-01 #4: 协程惯例——取消不能被当成普通失败吞掉。
                } catch (_: Throwable) {
                    // 这一次刷新失败——不动 items，等下一次信号/兜底轮询再试。
                }
            }
            // 正常返回（对端主动 finish 了发送方向，比如设备被吊销）
            // 和抛异常是同一件事：这次订阅结束了，都走下面的退避重连。
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e // REV-01 #4: 同上——effect 被取消（切走 tab/App 进后台）
            // 时必须真的停下来，不能被下面的退避重连逻辑当成"断线"接着跑。
        } catch (_: Throwable) {
            // 连接异常——同样走退避重连。
        }
        subscribeConnected = false
        subscribeHadFailure = true
        val wasLive = connectedAt?.let { System.currentTimeMillis() - it >= SUBSCRIBE_WAS_LIVE_MS } ?: false
        val decision = nextSubscribeRetry(subscribeAttempt, wasLive)
        if (decision.delayMs != null) {
            kotlinx.coroutines.delay(decision.delayMs)
        }
        subscribeAttempt = decision.nextAttempt
        subscribeExhausted = decision.exhausted
    }

    // REV-01 #2：兜底轮询必须是"仅追加"语义，不能调 refreshFullPage()。
    // 订阅信号走整页覆盖是必须的（删除可见性核心），但兜底轮询只是防
    // 订阅真实丢事件的保险丝——不该有自己的整页覆盖副作用。之前误用了
    // refreshFullPage()：用户翻到第 N 页，每 60s 被拉回第 1 页，翻页
    // 加载过的缩略图缓存被逐出。旧版 15s 轮询本来就是"只把没见过的
    // hash 插到最前面，不动已加载内容/翻页游标，不触发
    // onTimelineRefreshed"——这里原样保留那条语义，只是频率从 15s
    // 降到 60s（订阅是主通道，这层只是远低频率的保险）。
    LaunchedEffect(Unit) {
        while (true) {
            kotlinx.coroutines.delay(FULL_REFRESH_FALLBACK_MS)
            try {
                val page = loader.page(null)
                val known = items.map { it.hash }.toSet()
                val fresh = page.items.filter { it.hash !in known }
                if (fresh.isNotEmpty()) {
                    items = fresh + items
                    loader.onTimelineAppended(fresh.map { it.hash }.toSet())
                }
            } catch (_: Throwable) {
                // 静默——下一轮再试，不用错误态打断正在看的照片。
            }
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

        // SYNC-04：断线重连期间的轻提示——真机验收发现的缺口：重连中
        // 界面原来完全沉默（飞行模式几秒钟用户会以为是卡死），现在给
        // 一个不打断浏览的小字提示。跟下面"耗尽"的提示互斥（耗尽之后
        // 不会再是"重连中"）。
        if (subscribeHadFailure && !subscribeConnected && !subscribeExhausted) {
            Text(
                stringResource(R.string.photos_live_reconnecting),
                fontSize = 13.sp, color = PPColor.Ink40,
                modifier = Modifier.fillMaxWidth().padding(20.dp, 0.dp, 20.dp, 12.dp),
            )
        }

        // SYNC-04：订阅退避重试耗尽——不挡住已加载的照片，只在上面提示
        // "连不上"+手动重试（UX-11 同款：有界等待→亮错误→交给用户）。
        if (subscribeExhausted) {
            Row(
                Modifier.fillMaxWidth().padding(20.dp, 0.dp, 20.dp, 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    stringResource(R.string.photos_live_disconnected),
                    fontSize = 13.sp, color = PPColor.Ink40,
                )
                Text(
                    stringResource(R.string.photos_live_retry),
                    fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = PPColor.Ink,
                    modifier = Modifier.clickable {
                        subscribeExhausted = false
                        subscribeAttempt = 0
                    }.padding(6.dp),
                )
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
                                // MOB-04: 翻页追加只增不逐（后页照片仍在库中）。
                                loader.onTimelineAppended(page.items.map { it.hash }.toSet())
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

/** RET-01/MOB-06: 查看页可用动作——保存到相册 / 用其他应用打开 / 分享。 */
private enum class ViewerOp { Save, OpenWith, Share }

@Composable
private fun PhotoViewer(loader: TimelineLoader, asset: AssetMeta, onClose: () -> Unit) {
    // MOB-04 红线③（大图）：当前查看 = 1024 缩略图走内存缓存（见下）；
    // 未来加原图查看时——拉原图只走**临时文件即看即清或纯内存流式**，
    // 绝不建长期原图缓存。手机是减负端不是第二存储端。备忘：
    // docs/product/2026-08-12-cache-redlines.md。
    // RET-01: 取回=使用动作。原图按需下载到 cacheDir/share/（即用即清），
    // 不落任何长期缓存。
    val bmp by produceState<Bitmap?>(initialValue = null, asset.hash) {
        value = runCatching { loader.thumb(asset.hash, ThumbSize.S1024) }.getOrNull()
            ?: thumbCache.get("${asset.hash}/256")
    }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }
    val share = remember { shareDir(context) }

    // RET-01: 「用其他应用打开」/ MOB-06:「分享」面板关闭后清理临时文件
    // （MOB-04 红线）。有些系统查看器不回传 result——不依赖回调，每次使用
    // 前先清旧残留 + 进程重启由 cacheDir 语义兜底。分享与打开共用同一个
    // launcher：回调语义都是「面板关闭后清空 share 目录」。
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
                val file = downloadToShare(loader, asset.hash, share)
                when (op) {
                    ViewerOp.Save -> {
                        saveToGallery(context, file, asset)
                        file.delete() // 保存走 MediaStore，临时文件即用即清
                        notice = context.getString(R.string.saved_to_gallery)
                    }
                    ViewerOp.OpenWith -> {
                        openLauncher.launch(openWithAppIntent(context, file, asset))
                    }
                    ViewerOp.Share -> {
                        // MOB-06: ACTION_SEND 系统分享面板（微信/邮件/云盘…）
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

    PPScreen(background = PPColor.SurfaceDark) {
        Column(Modifier.fillMaxSize().padding(16.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(
                stringResource(R.string.back), fontSize = 17.sp, color = PPColor.Paper,
                modifier = Modifier.clickable(onClick = onClose).padding(10.dp),
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "${asset.width}×${asset.height}", fontSize = 14.sp,
                    color = PPColor.PaperDim, modifier = Modifier.padding(10.dp),
                )
                // MOB-06: 右上角分享——ACTION_SEND 系统分享面板（微信/邮件/云盘…）。
                Icon(
                    painter = painterResource(R.drawable.ic_share),
                    contentDescription = stringResource(R.string.share),
                    tint = PPColor.Paper,
                    modifier = Modifier
                        .clickable(enabled = !busy, onClick = { runAssetAction(ViewerOp.Share) })
                        .padding(10.dp),
                )
            }
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
        // RET-01: 取回=使用动作——保存到相册 / 用其他应用打开。
        notice?.let {
            Text(
                it, fontSize = 13.sp, color = PPColor.PaperDim,
                modifier = Modifier.padding(4.dp, 8.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
        }
        Row(
            Modifier.fillMaxWidth().padding(top = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            ViewerAction(
                label = stringResource(R.string.save_to_gallery),
                enabled = !busy,
                onClick = { runAssetAction(ViewerOp.Save) },
                modifier = Modifier.weight(1f),
            )
            ViewerAction(
                label = stringResource(R.string.open_with_app),
                enabled = !busy,
                onClick = { runAssetAction(ViewerOp.OpenWith) },
                modifier = Modifier.weight(1f),
            )
        }
        }
    }
}

/** RET-01: 查看页动作按钮（纸底墨字胶囊，与 FilterChip 同族）。 */
@Composable
internal fun ViewerAction(
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier
            .height(44.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(if (enabled) PPColor.Paper else PPColor.PaperDim.copy(alpha = 0.35f))
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
            color = if (enabled) PPColor.Ink else PPColor.PaperDim,
        )
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
