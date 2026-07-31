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
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.proto.AssetMeta
import java.io.File

sealed class VideoState {
    data class Fetching(val percent: Int) : VideoState()
    data class Ready(val file: File) : VideoState()
    data object Failed : VideoState()
}

@Composable
fun VideoScreen(
    loader: TimelineLoader,
    asset: AssetMeta,
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

    Column(Modifier.fillMaxSize().background(PPColor.SurfaceDark).padding(16.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(
                stringResource(R.string.back), fontSize = 17.sp, color = PPColor.Paper,
                modifier = Modifier.clickable(onClick = onClose).padding(10.dp),
            )
        }
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
    }
}
