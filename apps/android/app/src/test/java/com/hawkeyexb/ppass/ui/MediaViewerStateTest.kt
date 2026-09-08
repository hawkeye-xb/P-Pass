package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.proto.AssetMeta
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaViewerStateTest {
    private val assets = listOf(
        AssetMeta(hash = "photo-a", mediaType = "photo"),
        AssetMeta(hash = "video-b", mediaType = "video"),
        AssetMeta(hash = "photo-c", mediaType = "photo"),
    )

    @Test
    fun opensAtTheTappedAssetAndKeepsTheVisibleSequence() {
        val session = MediaViewerSession.open(assets, "video-b")

        assertNotNull(session)
        assertEquals(1, session!!.initialPage)
        assertEquals("video-b", session.assets[session.initialPage].hash)
        assertEquals(listOf("photo-a", "video-b", "photo-c"), session.assets.map { it.hash })
    }

    @Test
    fun missingTappedAssetDoesNotOpenAStaleViewer() {
        assertEquals(null, MediaViewerSession.open(assets, "no-longer-in-timeline"))
    }

    @Test
    fun systemBackClosesAnOpenViewerButDelegatesAtTheRoot() {
        assertEquals(ViewerBackAction.CloseViewer, viewerBackAction(viewerOpen = true))
        assertEquals(ViewerBackAction.DelegateToSystem, viewerBackAction(viewerOpen = false))
    }

    @Test
    fun pullToDismissOnlyActivatesAtMinimumZoom() {
        assertTrue("未缩放且超过阈值应关闭", canDismissFromPull(zoomFraction = 0f, dragPx = 96f, thresholdPx = 96f))
        assertFalse("缩放后下拉只能平移图片，不得关闭查看器", canDismissFromPull(zoomFraction = 0.01f, dragPx = 200f, thresholdPx = 96f))
        assertFalse("下拉未到阈值不得误关闭", canDismissFromPull(zoomFraction = 0f, dragPx = 95f, thresholdPx = 96f))
    }

    @Test
    fun photosScreenWiresSystemBackBeforeThePager() {
        val source = File("src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt").readText()

        assertTrue("查看器必须接管 Android 系统返回", source.contains("BackHandler"))
        assertTrue("查看器必须使用官方 HorizontalPager 翻页", source.contains("HorizontalPager"))
        assertTrue("点击网格项必须以当前过滤后的页序打开", source.contains("MediaViewerSession.open(shown, asset.hash)"))
        assertTrue("图片页必须使用成熟缩放手势层", source.contains(".zoomable("))
        assertTrue("下拉关闭必须由专门的纵向手势处理", source.contains("detectVerticalDragGestures"))
        assertTrue("缩放后下拉不得误关闭", source.contains("canDismissFromPull("))

        val build = File("build.gradle.kts").readText()
        assertTrue("图片手势库必须显式声明版本", build.contains("me.saket.telephoto:zoomable:0.19.0"))
    }
}
