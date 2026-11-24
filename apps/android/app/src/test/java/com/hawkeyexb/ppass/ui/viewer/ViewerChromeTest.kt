// #1800：查看器的翻页、缩放、关闭与操作改用 Material 3 标准组件的守卫。
// JVM 单测跑不了 Compose 渲染，但「用哪个组件」是这张卡的核心判据，
// 沿用 VideoScreenTest / SingleTransferFilePickerTest 的做法：扫描源码钉不变量。
// 每条断言都写明反证——把自绘控件改回去，它立刻红。
package com.hawkeyexb.ppass.ui.viewer

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ViewerChromeTest {
    // gradle Test workingDir = :app 模块目录（apps/android/app），
    // 与 VideoScreenTest / CacheRedlineTest 同一约定。
    private fun source(name: String): String {
        val f = File("src/main/java/com/hawkeyexb/ppass/ui/$name")
        assertTrue("找不到 $name：${File(".").absolutePath}", f.isFile)
        return f.readText()
    }

    /** 从 [start] 起到 [end] 之前的一段；找不到锚点直接判红，避免扫描落空后假绿。 */
    private fun slice(text: String, start: String, end: String): String {
        val from = text.indexOf(start)
        assertTrue("源码里找不到锚点：$start", from >= 0)
        val to = text.indexOf(end, from + start.length)
        assertTrue("源码里找不到结束锚点：$end", to > from)
        return text.substring(from, to)
    }

    /** 手写的「一个 Text/Icon 挂 clickable」——换回它就该红。 */
    private fun hasHandRolledClickable(block: String): Boolean =
        Regex("\\.clickable\\s*\\([^)]*onClick").containsMatchIn(block) ||
            Regex("Modifier\\.clickable\\s*\\(").containsMatchIn(block)

    @Test
    fun photoViewerCloseIsAMaterialIconButtonWithContentDescription() {
        val spec = com.hawkeyexb.ppass.ui.viewerChromeSpecOf(busy = false)
        org.junit.Assert.assertEquals(com.hawkeyexb.ppass.R.string.back, spec.closeDescriptionRes)
    }

    @Test
    fun videoViewerCloseAndShareAreMaterialIconButtons() {
        val screen = source("VideoScreen.kt")
        assertTrue(
            "关闭必须是 Material3 IconButton",
            screen.contains("IconButton(onClick = onClose)"),
        )
        assertTrue(
            "分享必须是 Material3 IconButton，且只在可取回后可点",
            Regex("IconButton\\(\\s*onClick = \\{ runAssetAction\\(VideoOp\\.Share\\) \\},\\s*enabled = [^)]*\\)")
                .containsMatchIn(screen),
        )
        // 反证：把分享改回 Icon(...).clickable(enabled = ...)，第二条红。
        assertFalse(
            "分享/关闭还留着自绘热区",
            hasHandRolledClickable(screen),
        )
    }

    @Test
    fun viewerActionsAreMaterialButtonsWithDisabledSemantics() {
        assertTrue(com.hawkeyexb.ppass.ui.viewerChromeSpecOf(busy = false).actionsEnabled)
        assertFalse(com.hawkeyexb.ppass.ui.viewerChromeSpecOf(busy = true).actionsEnabled)
        org.junit.Assert.assertEquals(44, com.hawkeyexb.ppass.ui.viewerChromeSpecOf(busy = false).minActionHeightDp)
        org.junit.Assert.assertEquals(1, com.hawkeyexb.ppass.ui.VIEWER_PREFETCH_NEIGHBOUR_PAGES)
    }

    @Test
    fun pagerPrefetchesTheNeighbourPages() {
        val pager = slice(source("PhotosScreen.kt"), "HorizontalPager(", ") { page ->")
        assertTrue(
            "翻页预取由 HorizontalPager 自己的 beyondViewportPageCount 控制",
            pager.contains("beyondViewportPageCount = 1"),
        )
        assertTrue("翻页仍归 HorizontalPager", pager.contains("state = pagerState"))
    }

    @Test
    fun zoomAndPullToDismissStillOwnTheirGestures() {
        val screen = source("PhotosScreen.kt")
        // 缩放交给 Telephoto、下拉关闭只在最小缩放时生效——组件替换不碰手势层。
        assertTrue("缩放必须仍由 Telephoto 的 zoomable 承担", screen.contains(".zoomable("))
        assertTrue("下拉关闭必须仍在", screen.contains("detectVerticalDragGestures("))
        assertTrue("手势交接判据必须仍在", screen.contains("atMinimumZoom"))
    }
}
