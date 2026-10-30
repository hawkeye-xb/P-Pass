// 视频页：翻到只显示封面，点了播放才下载；空间不够不开始下载；超过声明大小中止后显示失败。
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.log.PLog
import com.hawkeyexb.ppass.transport.OriginalExceedsDeclaredSizeException
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
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
        download: suspend (File, (Long, Long) -> Unit) -> Unit = { dest, p ->
            dest.writeBytes(ByteArray(declared.toInt())); p(declared, declared)
        },
    ) = VideoPlayback(
        tag = "t", declared = declared, cache = File(dir, "v.mp4"), freeBytes = { free },
        download = { d, p -> downloads++; download(d, p) }, log = { logs += it },
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
    fun videoScreenOnlyDownloadsFromPlayButton() {
        // 反证：在 composition 里（produceState / LaunchedEffect）直接调下载，本测试红。
        val src = File("src/main/java/com/hawkeyexb/ppass/ui/VideoScreen.kt").readText()
        assertEquals("loader.download 只出现在 VideoPlayback 的 download 参数里", 1,
            Regex("""loader\.download\(""").findAll(src).count())
        assertTrue(src.contains("download = { dest, onProgress -> loader.download("))
        assertEquals("play() 只由播放按钮触发", 1, Regex("""playback\.play\(\)""").findAll(src).count())
        assertTrue(src.contains("onPlay = { scope.launch { playback.play() } }"))
        assertFalse("播放器不再在就绪时自动开播之外的地方建", src.contains("LaunchedEffect"))
    }
}
