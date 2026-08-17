// T-056: video playback — fetch the original over the download plane
// into the cache dir, then hand it to the system player view. MVP is
// download-then-play; streaming DataSource is an M3 refinement.
package com.hawkeyexb.ppass.ui

import android.net.Uri
import android.widget.VideoView
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.proto.AssetMeta
import java.io.File
import kotlinx.coroutines.launch

sealed class VideoState {
    data class Fetching(val percent: Int) : VideoState()
    data class Ready(val file: File) : VideoState()
    data object Failed : VideoState()
}

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
    val state by produceState<VideoState>(VideoState.Fetching(0), asset.hash) {
        val cache = File(context.cacheDir, "video-${asset.hash.take(16)}.mp4")
        if (cache.isFile && cache.length() > 0) {
            value = VideoState.Ready(cache)
            return@produceState
        }
        value = try {
            loader.download(asset.hash, cache) { got, total ->
                if (total > 0) {
                    value = VideoState.Fetching((got * 100 / total).toInt())
                }
            }
            VideoState.Ready(cache)
        } catch (_: Throwable) {
            cache.delete()
            VideoState.Failed
        }
    }
    // RET-01: 取回=使用动作——视频 Ready 后同样可保存到相册 / 用其他
    // 应用打开（播放缓存文件即用即清，cacheDir 语义由系统兜底）。
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }

    fun runAssetAction(op: VideoOp) {
        if (busy) return
        val ready = state as? VideoState.Ready ?: return
        busy = true
        notice = null
        scope.launch {
            try {
                when (op) {
                    VideoOp.Save -> {
                        saveToGallery(context, ready.file, asset)
                        notice = context.getString(R.string.saved_to_gallery)
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
                    painter = painterResource(R.drawable.ic_share),
                    contentDescription = stringResource(R.string.share),
                    tint = PPColor.Paper,
                    modifier = Modifier
                        .clickable(
                            enabled = !busy && state is VideoState.Ready,
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
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                when (val s = state) {
                    is VideoState.Fetching -> Text(
                        stringResource(R.string.video_loading, s.percent),
                        color = PPColor.PaperDim, fontSize = 16.sp,
                    )
                    is VideoState.Failed -> Text(
                        stringResource(R.string.video_failed),
                        color = PPColor.PaperDim, fontSize = 16.sp,
                    )
                    is VideoState.Ready -> AndroidView(
                        modifier = Modifier.fillMaxSize(),
                        factory = { ctx ->
                            VideoView(ctx).apply {
                                setVideoURI(Uri.fromFile(s.file))
                                setOnPreparedListener { it.isLooping = true; start() }
                            }
                        },
                    )
                }
            }
            // RET-01: 视频 Ready 才显示动作（未取到前无原图可存/可开）。
            if (state is VideoState.Ready) {
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
