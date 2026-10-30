// 视频页的取回与播放：翻到视频页只显示封面和播放按钮（按钮标出文件大小），
// 用户点了才下载、下完才播放。下载前先看手机剩余空间；下载中收到的字节超过
// 电脑声明的大小立即中止（DaemonClient.downloadAsset 的 DeclaredSizeGuard）。
// 播放的始终是原片，不转码。
//
// 状态机放在这个与 Compose 无关的类里：翻页只会创建它、不会调 [play]，所以
// 「翻到 / 滑过视频页不下载」可以在 JVM 上直接断言（VideoPlaybackTest）。
package com.hawkeyexb.ppass.ui

import android.content.Context
import android.os.storage.StorageManager
import com.hawkeyexb.ppass.log.PLog
import com.hawkeyexb.ppass.transport.OriginalExceedsDeclaredSizeException
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

internal sealed interface VideoPhase {
    /** 只有封面和播放按钮，没有发起任何下载。 */
    data object Cover : VideoPhase
    data class Fetching(val percent: Int) : VideoPhase
    data class Ready(val file: File) : VideoPhase
    /** 手机剩余空间不够，没有开始下载。 */
    data object NoRoom : VideoPhase
    data object Failed : VideoPhase
}

/**
 * 下载一段视频要占的空间：取回时临时仓库里一份、导出到缓存文件又一份（iroh-blobs 的
 * export 是复制），所以按声明大小的两倍，再留 [VIDEO_SPACE_MARGIN_BYTES] 余量给系统。
 */
internal const val VIDEO_SPACE_MARGIN_BYTES = 64L * 1024 * 1024

internal fun videoSpaceNeeded(declared: Long): Long = declared * 2 + VIDEO_SPACE_MARGIN_BYTES

internal sealed interface VideoStartCheck {
    data object Go : VideoStartCheck
    /** 电脑没给出大小：无从限定下载量，不下载。 */
    data object UnknownSize : VideoStartCheck
    data class NoRoom(val needed: Long, val free: Long) : VideoStartCheck
}

internal fun videoStartCheck(declared: Long, freeBytes: Long): VideoStartCheck = when {
    declared <= 0 -> VideoStartCheck.UnknownSize
    freeBytes < videoSpaceNeeded(declared) -> VideoStartCheck.NoRoom(videoSpaceNeeded(declared), freeBytes)
    else -> VideoStartCheck.Go
}

internal class VideoPlayback(
    private val tag: String,
    private val declared: Long,
    private val cache: File,
    private val freeBytes: () -> Long,
    /** 把原片取到 dest；进度回调 (已收字节, 声明字节)。失败时不留 dest。 */
    private val download: suspend (dest: File, onProgress: (Long, Long) -> Unit) -> Unit,
    private val log: (String) -> Unit = { PLog.i("PPassVideo", it) },
) {
    private val _phase = MutableStateFlow<VideoPhase>(VideoPhase.Cover)
    val phase: StateFlow<VideoPhase> = _phase.asStateFlow()

    /** 用户点了播放。已在下载或已就绪时忽略重复点击。 */
    suspend fun play() {
        when (_phase.value) {
            is VideoPhase.Fetching, is VideoPhase.Ready -> return
            else -> Unit
        }
        log("video $tag play tapped, declared=$declared")
        if (isCompleteOriginal(cache, declared)) {
            log("video $tag cached, playing")
            _phase.value = VideoPhase.Ready(cache)
            return
        }
        when (val check = videoStartCheck(declared, freeBytes())) {
            VideoStartCheck.UnknownSize -> {
                log("video $tag not fetched: size unknown")
                _phase.value = VideoPhase.Failed
                return
            }
            is VideoStartCheck.NoRoom -> {
                log("video $tag not fetched: needs ${check.needed} bytes, ${check.free} free")
                _phase.value = VideoPhase.NoRoom
                return
            }
            VideoStartCheck.Go -> log("video $tag space ok, fetching")
        }
        _phase.value = VideoPhase.Fetching(0)
        val started = System.currentTimeMillis()
        try {
            download(cache) { got, total ->
                if (total > 0) _phase.value = VideoPhase.Fetching((got * 100 / total).toInt().coerceIn(0, 100))
            }
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            cache.delete()
            _phase.value = VideoPhase.Cover
            throw e
        } catch (e: OriginalExceedsDeclaredSizeException) {
            PLog.w("PPassVideo", "video $tag fetch stopped: more data than declared", e)
            cache.delete()
            _phase.value = VideoPhase.Failed
            return
        } catch (e: Throwable) {
            PLog.w("PPassVideo", "video $tag fetch failed", e)
            cache.delete()
            _phase.value = VideoPhase.Failed
            return
        }
        log("video $tag fetched in ${System.currentTimeMillis() - started}ms, playing")
        _phase.value = VideoPhase.Ready(cache)
    }
}

/** 缓存目录所在卷还能给 App 分配多少字节（系统可清理的缓存也算在内）。 */
internal fun allocatableCacheBytes(context: Context): Long {
    val storage = context.getSystemService(StorageManager::class.java)
    return runCatching { storage.getAllocatableBytes(storage.getUuidForPath(context.cacheDir)) }
        .getOrElse { context.cacheDir.usableSpace }
}
