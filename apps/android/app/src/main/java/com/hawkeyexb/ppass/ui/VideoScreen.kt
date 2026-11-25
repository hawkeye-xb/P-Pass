// T-056/MOB-47/#1963: 视频查看页——打开只展示封面、大小标签与保存/分享操作（不自动下载）；
// 点播放或保存/分享时按需优先直读本机原片（MediaStore / SAF），未命中则流式下载到缓存并展示
// 线性进度条 + 百分比。仅点播放才切入 Media3 ExoPlayer / PlayerView（带 play/pause、进度条、
// seek 与错误态，onDispose 里 release 防止泄漏）；未点播放前点保存/分享保持封面态不自动起播。
package com.hawkeyexb.ppass.ui

import android.net.Uri
import android.graphics.Bitmap
import android.text.format.Formatter
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import com.hawkeyexb.ppass.proto.ThumbSize
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.LocalFirstLoader
import com.hawkeyexb.ppass.proto.AssetMeta
import java.io.File
import kotlinx.coroutines.launch

/** RET-01/MOB-06: 查看页可用动作——保存到相册 / 分享。 */
private enum class VideoOp { Save, Share }

@Composable
internal fun VideoScreen(
    loader: TimelineLoader,
    localMedia: LocalFirstLoader<Bitmap>,
    asset: AssetMeta,
    isMine: Boolean,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    // 翻到这一页只建状态机、取封面，不下载；点播放走 [VideoPlayback.play]，点保存/分享走 [VideoPlayback.prepareOriginal]。
    // 优先直读本机已有视频（MediaStore 或已授权 SAF 目录），未命中再走缓存/远端下载。
    // MOB-115: 命中缓存要求长度 == asset.bytes（截断的旧缓存会被删掉重下）。
    val playback = remember(asset.hash, isMine) {
        VideoPlayback(
            tag = asset.hash.take(16),
            declared = asset.bytes,
            cache = File(context.cacheDir, "video-${asset.hash.take(16)}.mp4"),
            freeBytes = { allocatableCacheBytes(context) },
            download = { dest, onProgress -> loader.download(asset.hash, dest, asset.bytes, onProgress) },
            resolveLocalUri = { localMedia.localVideoUri(asset, isMine) },
        )
    }
    val state by playback.phase.collectAsState()
    // 封面 = 电脑生成的 1024 缩略图（与照片同一条 JPEG 预检），取不到退回网格里的 256。
    @Suppress("ProduceStateDoesNotAssignValue")
    val cover by produceState<Bitmap?>(initialValue = thumbCache.get("${asset.hash}/256"), asset.hash) {
        runCatching { loader.thumb(asset.hash, ThumbSize.S1024) }.getOrNull()?.let { value = it }
    }
    // RET-01/#1963: 未点播放前同样可直接点「保存到相册 / 分享」——按需拉取（本机命中则直读 URI，免下载），且拉取完不自动起播。
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }

    fun runAssetAction(op: VideoOp) {
        if (busy) return
        busy = true
        notice = null
        scope.launch {
            try {
                val source = playback.prepareOriginal()
                if (source == null) {
                    notice = context.getString(
                        if (playback.phase.value == VideoPhase.NoRoom) R.string.video_no_space
                        else R.string.share_download_failed,
                    )
                    return@launch
                }
                when (op) {
                    VideoOp.Save -> {
                        val saved = when (source) {
                            is VideoSource.LocalUri -> saveUriToGallery(context, Uri.parse(source.uri), asset)
                            is VideoSource.CachedFile -> saveToGallery(context, source.file, asset)
                        }
                        // MOB-24: 存过就直说，别让用户以为没生效又点一次。
                        notice = context.getString(
                            if (saved.alreadyExisted) R.string.already_in_gallery
                            else R.string.saved_to_gallery,
                        )
                    }
                    VideoOp.Share -> {
                        var tmp: File? = null
                        val intent = when (source) {
                            is VideoSource.LocalUri -> shareUriIntent(
                                context, Uri.parse(source.uri), asset,
                                context.getString(R.string.share_to),
                            )
                            is VideoSource.CachedFile -> {
                                val share = shareDir(context)
                                share.listFiles()?.forEach { it.delete() }
                                val copied = File(share, "video-${asset.hash.take(16)}.mp4")
                                source.file.copyTo(copied, overwrite = true)
                                tmp = copied
                                shareIntent(
                                    context, copied, asset,
                                    context.getString(R.string.share_to),
                                )
                            }
                        }
                        try {
                            context.startActivity(intent)
                        } catch (_: android.content.ActivityNotFoundException) {
                            tmp?.delete()
                            notice = context.getString(R.string.no_app_for_file)
                        }
                    }
                }
            } catch (_: Throwable) {
                notice = context.getString(R.string.share_download_failed)
            } finally {
                busy = false
            }
        }
    }

    // #1926：整屏底色、安全区 inset 与系统栏图标明暗已由外层 TwoTabs 唯一顶层 PPScreen
    // 按 photoViewerOpen 切到 SurfaceDark；这里不再嵌套第二层 PPScreen。
    Box(Modifier.fillMaxSize().background(PPColor.SurfaceDark)) {
        Column(Modifier.fillMaxSize().padding(16.dp)) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // #1800：关闭与分享都用 Material3 IconButton——触控区、涟漪、
                // role=Button 与 contentDescription 由组件给出，禁用态也自带语义。
                IconButton(onClick = onClose) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = stringResource(R.string.back),
                        tint = PPColor.Paper,
                    )
                }
                // MOB-06/#1963: 右上角分享——未点播放前亦可直接点击，按需直读本机或拉取后呼起系统分享面板。
                IconButton(
                    onClick = { runAssetAction(VideoOp.Share) },
                    enabled = videoActionsEnabled(busy),
                ) {
                    Icon(
                        imageVector = Icons.Filled.Share,
                        contentDescription = stringResource(R.string.share),
                        tint = PPColor.Paper,
                    )
                }
            }
            // 归因信息按需出现——网格不标来源，只有大图才显示。
            Text(
                attributionText(isMine, asset.takenAt),
                fontSize = 13.sp, color = PPColor.PaperDim,
                modifier = Modifier.padding(horizontal = 10.dp),
            )
            // MOB-22: 同 PhotosScreen——Column 里用 fillMaxSize 会把下面的
            // 动作按钮顶出屏幕。改 weight(1f)：占剩余空间但给按钮让位。
            Box(
                Modifier.fillMaxWidth().weight(1f),
                contentAlignment = Alignment.Center,
            ) {
                when (val s = state) {
                    is VideoPhase.Fetching -> VideoFetchingStatus(s.percent)
                    // MOB-47: 播放器层换 Media3 ExoPlayer/PlayerView——
                    // PlayerView 自带播放/暂停/进度条/seek/错误态，播放器在
                    // onDispose 里 release，退出查看器不泄漏（logcat 无
                    // MediaCodec/ExoPlayer 泄漏即验收项）。
                    is VideoPhase.Ready -> VideoPlayer(s.source)
                    else -> VideoCover(
                        cover = cover,
                        sizeLabel = Formatter.formatShortFileSize(context, asset.bytes.coerceAtLeast(0)),
                        notice = when (s) {
                            VideoPhase.NoRoom -> stringResource(R.string.video_no_space)
                            VideoPhase.Failed -> stringResource(R.string.video_failed)
                            else -> null
                        },
                        onPlay = { scope.launch { playback.play() } },
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
                    enabled = videoActionsEnabled(busy),
                    onClick = { runAssetAction(VideoOp.Save) },
                    modifier = Modifier.weight(1f),
                )
                ViewerAction(
                    label = stringResource(R.string.share),
                    enabled = videoActionsEnabled(busy),
                    onClick = { runAssetAction(VideoOp.Share) },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
internal fun VideoFetchingStatus(percent: Int) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        // Material3 1.3 LinearProgressIndicator 默认带 gapSize 与停靠圆点，清零呈连续直条
        LinearProgressIndicator(
            progress = { percent / 100f },
            modifier = Modifier.width(220.dp),
            color = PPColor.Paper,
            trackColor = PPColor.PaperDim.copy(alpha = 0.3f),
            gapSize = 0.dp,
            drawStopIndicator = {},
        )
        Spacer(Modifier.height(12.dp))
        Text(
            stringResource(R.string.video_loading, percent),
            color = PPColor.PaperDim,
            fontSize = 16.sp,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )
    }
}

/** 视频页的初始样子：封面 + 居中的播放按钮（按钮上是原片大小）。没下载前只有这些。 */
@Composable
internal fun VideoCover(cover: Bitmap?, sizeLabel: String, notice: String?, onPlay: () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        if (cover != null) {
            Image(
                bitmap = cover.asImageBitmap(), contentDescription = null,
                modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Fit,
            )
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            ViewerAction(
                label = stringResource(R.string.video_play_size, sizeLabel),
                enabled = true,
                onClick = onPlay,
                leadingIcon = Icons.Filled.PlayArrow,
                height = PPSize.TapMin,
            )
            notice?.let {
                Text(
                    it, fontSize = 15.sp, color = PPColor.Paper,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    modifier = Modifier
                        .padding(top = 12.dp, start = 24.dp, end = 24.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(PPColor.SurfaceDark.copy(alpha = 0.8f))
                        .padding(horizontal = 12.dp, vertical = 8.dp)
                        .semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
        }
    }
}

/** MOB-47/#1963: 单个视频来源的 Media3 播放器（支持本机 URI 直读与缓存文件）。player 的生命周期绑定在
 *  composition 上——[DisposableEffect] onDispose 里 `release()`，退出查看器
 *  / 切 asset 时播放器立即释放（不依赖 AndroidView 的 destroy）。 */
@Composable
private fun VideoPlayer(source: VideoSource) {
    val context = LocalContext.current
    val mediaUri = remember(source) {
        when (source) {
            is VideoSource.LocalUri -> Uri.parse(source.uri)
            is VideoSource.CachedFile -> Uri.fromFile(source.file)
        }
    }
    val player = remember(mediaUri) {
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(mediaUri))
            prepare()
            playWhenReady = true
        }
    }
    DisposableEffect(player) {
        onDispose { player.release() }
    }
    AndroidView(
        modifier = Modifier.fillMaxSize(),
        factory = { ctx ->
            PlayerView(ctx).apply {
                useController = true // 播放/暂停/进度条/seek/错误态
                this.player = player
            }
        },
        update = { it.player = player },
    )
}