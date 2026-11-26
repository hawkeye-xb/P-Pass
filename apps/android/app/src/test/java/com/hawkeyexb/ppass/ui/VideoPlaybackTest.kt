// 视频页：翻到只显示封面，点了播放才下载；空间不够不开始下载；超过声明大小中止后显示失败。
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.log.PLog
import com.hawkeyexb.ppass.transport.OriginalExceedsDeclaredSizeException
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class VideoPlaybackTest {

    private val dir: File = Files.createTempDirectory("video").toFile()
    private val logs = mutableListOf<String>()
    private var downloads = 0

    @Before fun quietLog() { PLog.sink = PLog.Sink { _, _, m -> logs += m } }
    @After fun cleanup() { PLog.resetSink(); dir.deleteRecursively() }

    private fun playback(
        declared: Long = 10_000,
        free: Long = Long.MAX_VALUE,
        resolveLocalUri: suspend () -> String? = { null },
        download: suspend (File, (Long, Long) -> Unit) -> Unit = { dest, p ->
            dest.writeBytes(ByteArray(declared.toInt())); p(declared, declared)
        },
    ) = VideoPlayback(
        tag = "t", declared = declared, cache = File(dir, "v.mp4"), freeBytes = { free },
        download = { d, p -> downloads++; download(d, p) },
        resolveLocalUri = resolveLocalUri,
        log = { logs += it },
    )

    @Test
    fun openingVideoPageDoesNotDownload() {
        // 翻页 = 为这一页建状态机（VideoScreen 的 remember）；只要没点播放就不下载。
        val pages = List(5) { playback() }
        pages.forEach { assertEquals(VideoPhase.Cover, it.phase.value) }
        assertEquals(0, downloads)
    }

    @Test
    fun tappingPlayDownloadsOnceThenPlays() = runBlocking {
        val p = playback()
        p.play()
        assertTrue(p.phase.value is VideoPhase.Ready)
        p.play() // 已就绪：再点不重下
        assertEquals(1, downloads)
        assertTrue(logs.any { it.contains("space ok") })
        assertTrue(logs.any { it.contains("fetched in") })
    }

    @Test
    fun insufficientSpaceDoesNotStartDownload() = runBlocking {
        val declared = 500L * 1024 * 1024
        val p = playback(declared = declared, free = videoSpaceNeeded(declared) - 1)
        p.play()
        assertEquals(VideoPhase.NoRoom, p.phase.value)
        assertEquals(0, downloads)
        // 反证：空间刚好够就开始下载。
        val ok = playback(declared = 1_000, free = videoSpaceNeeded(1_000))
        ok.play()
        assertEquals(1, downloads)
    }

    @Test
    fun spaceCheckCountsScratchCopyAndExport() {
        assertEquals(2L * 1_000 + VIDEO_SPACE_MARGIN_BYTES, videoSpaceNeeded(1_000))
        assertEquals(VideoStartCheck.Go, videoStartCheck(1_000, videoSpaceNeeded(1_000)))
        assertTrue(videoStartCheck(1_000, videoSpaceNeeded(1_000) - 1) is VideoStartCheck.NoRoom)
    }

    @Test
    fun unknownDeclaredSizeDoesNotStartDownload() = runBlocking {
        val p = playback(declared = 0)
        p.play()
        assertEquals(VideoPhase.Failed, p.phase.value)
        assertEquals(0, downloads)
    }

    @Test
    fun downloadOverDeclaredSizeShowsFailureAndKeepsNoFile() = runBlocking {
        val p = playback(declared = 1_000, download = { dest, _ ->
            dest.writeBytes(ByteArray(10))
            throw OriginalExceedsDeclaredSizeException(1_000, 1_001)
        })
        p.play()
        assertEquals(VideoPhase.Failed, p.phase.value)
        assertFalse(File(dir, "v.mp4").exists())
        assertTrue(logs.any { it.contains("more data than declared") })
    }

    @Test
    fun cachedVideoPlaysWithoutDownloadOrSpaceCheck() = runBlocking {
        File(dir, "v.mp4").writeBytes(ByteArray(1_000))
        val p = playback(declared = 1_000, free = 0)
        assertEquals(VideoPhase.Cover, p.phase.value) // 已缓存也先显示封面
        p.play()
        assertTrue(p.phase.value is VideoPhase.Ready)
        assertEquals(0, downloads)
    }

    @Test
    fun localVideoPlaysDirectlyWithoutDownloadOrSpaceCheck() = runBlocking {
        val localUri = "content://media/external/video/media/42"
        val p = playback(declared = 500L * 1024 * 1024, free = 0, resolveLocalUri = { localUri })
        assertEquals(VideoPhase.Cover, p.phase.value)

        // 未点播放前点保存/分享（prepareOriginal）：返回本机 URI 但不进 Ready 自动起播。
        val actionSource = p.prepareOriginal()
        assertEquals(VideoSource.LocalUri(localUri), actionSource)
        assertEquals(VideoPhase.Cover, p.phase.value)

        // 点播放才进 Ready。
        p.play()
        assertEquals(VideoPhase.Ready(VideoSource.LocalUri(localUri)), p.phase.value)
        assertEquals(0, downloads)
        assertTrue(logs.any { it.contains("local hit") })

        // 反证：本机未命中（resolveLocalUri 返回 null）时退回远端下载路径。
        val remote = playback(declared = 1_000, free = videoSpaceNeeded(1_000), resolveLocalUri = { null })
        val remoteSource = remote.prepareOriginal()
        assertTrue(remoteSource is VideoSource.CachedFile)
        assertEquals(VideoPhase.Cover, remote.phase.value)
        assertEquals(1, downloads)
    }

    @Test
    fun safFolderVideoPrepareAndPlayReturnDirectUriWithoutDownload() = runBlocking {
        val safUri = "content://com.android.externalstorage.documents/tree/primary%3ABlackmagic/document/primary%3ABlackmagic%2Ftake1.mov"
        val p = playback(declared = 200L * 1024 * 1024, free = 0, resolveLocalUri = { safUri })
        assertEquals(VideoSource.LocalUri(safUri), p.prepareOriginal())
        assertEquals(VideoPhase.Cover, p.phase.value)
        p.play()
        assertEquals(VideoPhase.Ready(VideoSource.LocalUri(safUri)), p.phase.value)
        assertEquals(0, downloads)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun prepareOriginalFetchesWithFetchingProgressWithoutAutoPlaying() = runTest {
        val phases = mutableListOf<VideoPhase>()
        val p = playback(
            declared = 1_000,
            download = { dest, onProgress ->
                onProgress(250, 1_000)
                onProgress(750, 1_000)
                dest.writeBytes(ByteArray(1_000))
                onProgress(1_000, 1_000)
            },
        )
        val collector = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            p.phase.collect { phases += it }
        }
        assertEquals(VideoPhase.Cover, p.phase.value)
        assertTrue("未点播放前动作按钮应可直接点击", videoActionsEnabled(busy = false))
        assertFalse("执行中动作按钮置灰防重入", videoActionsEnabled(busy = true))

        val first = p.prepareOriginal()
        assertTrue(first is VideoSource.CachedFile)
        assertEquals(1, downloads)
        assertEquals(
            "下载中必须真实经 Fetching(0 -> 25 -> 75 -> 100) 推送进度，供线性进度条与百分比渲染",
            listOf(0, 25, 75, 100),
            phases.filterIsInstance<VideoPhase.Fetching>().map { it.percent },
        )
        assertEquals(
            "未点播放直接点保存/分享拉取完不得把 phase 置 Ready（避免背后自动起播）",
            VideoPhase.Cover,
            p.phase.value,
        )
        assertFalse("保存/分享流程全程不得出现 Ready", phases.any { it is VideoPhase.Ready })

        // 随后再点播放：直接命中完整缓存进 Ready，不重下；Ready 后再点保存/分享不退出 Ready。
        p.play()
        assertTrue(p.phase.value is VideoPhase.Ready)
        assertEquals(first, p.prepareOriginal())
        assertTrue(p.phase.value is VideoPhase.Ready)
        assertEquals(1, downloads)
        collector.cancel()
    }

    @Test
    fun concurrentPrepareOriginalDeduplicatesDownload() = runTest {
        val gate = CompletableDeferred<Unit>()
        val started = CompletableDeferred<Unit>()
        val p = playback(
            declared = 1_000,
            download = { dest, onProgress ->
                started.complete(Unit)
                gate.await()
                dest.writeBytes(ByteArray(1_000))
                onProgress(1_000, 1_000)
            },
        )
        val first = async { p.prepareOriginal() }
        started.await()
        assertEquals(VideoPhase.Fetching(0), p.phase.value)
        val second = async { p.prepareOriginal() }
        gate.complete(Unit)

        assertEquals(first.await(), second.await())
        assertEquals(1, downloads)
        assertEquals(VideoPhase.Cover, p.phase.value)
    }
}
