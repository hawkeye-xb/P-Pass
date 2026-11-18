package com.hawkeyexb.ppass

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1840（产品口径 2026-11-17）：单次文件入口只允许图片和视频，不允许文件夹。
 * 选择器的媒体类型由 `PickVisualMediaRequest` 的参数决定，两个入口各一处：
 * 决定页的 `launchDecisionPick` 与照片页的 `onPickPhotos`。
 *
 * 反证：把任一入口改回 `PickVisualMedia.ImageOnly`，对应的用例红。
 */
class SinglePickAcceptsVideoTest {
    private val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()

    /** 决定页「挑几张传」入口：选到视频也算做了决定。 */
    @Test
    fun decision_page_pick_accepts_images_and_videos() {
        val entry = main.substringAfter("val launchDecisionPick").substringBefore("}.onFailure")
        assertTrue("决定页入口要接受视频", entry.contains("PickVisualMedia.ImageAndVideo"))
        assertFalse("决定页入口不许只选图片", entry.contains("PickVisualMedia.ImageOnly"))
    }

    /** 照片页「挑几张传」入口。 */
    @Test
    fun photos_page_pick_accepts_images_and_videos() {
        val entry = main.substringAfter("onPickPhotos = {").substringBefore("pickedBatch = pickedBatch")
        assertTrue("照片页入口要接受视频", entry.contains("PickVisualMedia.ImageAndVideo"))
        assertFalse("照片页入口不许只选图片", entry.contains("PickVisualMedia.ImageOnly"))
    }

    /** 全文件兜底：单次入口之外也不该再把选择器限死成图片。 */
    @Test
    fun no_entry_limits_the_picker_to_images_only() {
        assertFalse("MainActivity 里还有只选图片的入口", main.contains("PickVisualMedia.ImageOnly"))
    }
}
