// T-056: video playback — fetch the original via asset.blob_ticket + the shared fetch_blob
// into the cache dir, then play it in-app. The page opens on the cover and a play button
// labelled with the file size; nothing is fetched until that button is tapped (VideoPlayback). MOB-47 upgraded the MVP:
// the system `VideoView` is replaced by the official Media3 ExoPlayer /
// PlayerView, which ships real playback controls (play/pause, progress
// bar, seek) and error state, and is released on dispose so nothing leaks.
// Still download-then-play: a streaming progressive DataSource that reads
// the transfer plane with range requests is a deliberate out-of-scope
// enhancement (the card pins `loader.download` semantics unchanged).
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
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Icon
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.proto.AssetMeta
import java.io.File
import kotlinx.coroutines.launch

/** RET-01/MOB-06: 查看页可用动作——保存到相册 / 用其他应用打开 / 分享。 */
private enum class VideoOp { Save, OpenWith, Share }

@Composable
fun VideoScreen(
    loader: TimelineLoader,
    asset: AssetMeta,
    isMine: Boolean,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    // 翻到这一页只建状态机、取封面，不下载；点了播放才走 [VideoPlayback.play]。
    // MOB-115: 命中缓存要求长度 == asset.bytes（截断的旧缓存会被删掉重下）。
    val playback = remember(asset.hash) {
        VideoPlayback(
            tag = asset.hash.take(16),
            declared = asset.bytes,
            cache = File(context.cacheDir, "video-${asset.hash.take(16)}.mp4"),
            freeBytes = { allocatableCacheBytes(context) },
            download = { dest, onProgress -> loader.download(asset.hash, dest, asset.bytes, onProgress) },
        )
    }
    val state by playback.phase.collectAsState()
    // 封面 = 电脑生成的 1024 缩略图（与照片同一条 JPEG 预检），取不到退回网格里的 256。
    @Suppress("ProduceStateDoesNotAssignValue")
    val cover by produceState<Bitmap?>(initialValue = thumbCache.get("${asset.hash}/256"), asset.hash) {
        runCatching { loader.thumb(asset.hash, ThumbSize.S1024) }.getOrNull()?.let { value = it }
    }
    // RET-01: 取回=使用动作——视频 Ready 后同样可保存到相册 / 用其他
    // 应用打开（播放缓存文件即用即清，cacheDir 语义由系统兜底）。
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }

    fun runAssetAction(op: VideoOp) {
        if (busy) return
        val ready = state as? VideoPhase.Ready ?: return
        busy = true
        notice = null
        scope.launch {
            try {
                when (op) {
                    VideoOp.Save -> {
                        val saved = saveToGallery(context, ready.file, asset)
                        // MOB-24: 存过就直说，别让用户以为没生效又点一次。
                        notice = context.getString(
                            if (saved.alreadyExisted) R.string.already_in_gallery
                            else R.string.saved_to_gallery
                        )
                    }
                    VideoOp.OpenWith, VideoOp.Share -> {
                        val share = shareDir(context)
                        share.listFiles()?.forEach { it.delete() }
                        val tmp = File(share, "video-${asset.hash.take(16)}.mp4")
                        ready.file.copyTo(tmp, overwrite = true)
                        val intent = if (op == VideoOp.OpenWith) {
                            openWithAppIntent(context, tmp, asset)
                        } else {
                            // MOB-06: ACTION_SEND 系统分享面板（微信/邮件/云盘…）
                            shareIntent(
                                context, tmp, asset,
                                context.getString(R.string.share_to),
                            )
                        }
                        try {
                            context.startActivity(intent)
                        } catch (_: android.content.ActivityNotFoundException) {
                            tmp.delete()
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

    PPScreen(background = PPColor.SurfaceDark) {
        Column(Modifier.fillMaxSize().padding(16.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(
                    stringResource(R.string.back), fontSize = 17.sp, color = PPColor.Paper,
                    modifier = Modifier.clickable(onClick = onClose).padding(10.dp),
                )
                // MOB-06: 右上角分享——ACTION_SEND 系统分享面板（微信/邮件/云盘…）。
                // 仅 Ready 后可分享（未取到前无文件可发）。
                Icon(
                    imageVector = Icons.Filled.Share,
                    contentDescription = stringResource(R.string.share),
                    tint = PPColor.Paper,
                    modifier = Modifier
                        .clickable(
                            enabled = !busy && state is VideoPhase.Ready,
                            onClick = { runAssetAction(VideoOp.Share) },
                        )
                        .padding(10.dp),
                )
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
                    is VideoPhase.Fetching -> Text(
                        stringResource(R.string.video_loading, s.percent),
                        color = PPColor.PaperDim, fontSize = 16.sp,
                    )
                    // MOB-47: 播放器层换 Media3 ExoPlayer/PlayerView——
                    // PlayerView 自带播放/暂停/进度条/seek/错误态，播放器在
                    // onDispose 里 release，退出查看器不泄漏（logcat 无
                    // MediaCodec/ExoPlayer 泄漏即验收项）。
                    is VideoPhase.Ready -> VideoPlayer(s.file)
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
            // RET-01: 视频 Ready 才显示动作（未取到前无原图可存/可开）。
            if (state is VideoPhase.Ready) {
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
                        onClick = { runAssetAction(VideoOp.Save) },
                        modifier = Modifier.weight(1f),
                    )
                    ViewerAction(
                        label = stringResource(R.string.open_with_app),
                        enabled = !busy,
                        onClick = { runAssetAction(VideoOp.OpenWith) },
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

/** 视频页的初始样子：封面 + 居中的播放按钮（按钮上是原片大小）。没下载前只有这些。 */
@Composable
private fun VideoCover(cover: Bitmap?, sizeLabel: String, notice: String?, onPlay: () -> Unit) {
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
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }
        }
    }
}

/** MOB-47: 单个视频文件的 Media3 播放器。player 的生命周期绑定在
 *  composition 上——[DisposableEffect] onDispose 里 `release()`，退出查看器
 *  / 切 asset 时播放器立即释放（不依赖 AndroidView 的 destroy）。 */
@Composable
private fun VideoPlayer(file: File) {
    val context = LocalContext.current
    // 按文件实例记住 player：同一 asset 的 Ready 文件对象稳定，切走即随
    // composition 销毁。download-then-play：文件已完整落在 cacheDir，播放
    // 不阻塞主线程（ExoPlayer 内部线程）。
    val player = remember(file) {
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
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