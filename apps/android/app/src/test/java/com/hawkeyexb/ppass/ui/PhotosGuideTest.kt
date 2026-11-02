package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1272 §6：权限提示收缩成一种（自动备份开着时权限被收回 / 改成部分 → 开关下方一行小字 + 通知）。
 * 照片页不再有权限卡；引导只剩「还没选相册」。
 * 反证：photosGuideOf 又看权限档（或照片页又出权限卡）→ 下面任一条红。
 */
class PhotosGuideTest {
    @Test
    fun the_photos_guide_is_only_about_albums() {
        assertEquals(PhotosGuide.NoAlbums, photosGuideOf(noAlbums = true))
        assertEquals(PhotosGuide.None, photosGuideOf(noAlbums = false))
    }

    @Test
    fun the_access_cards_are_gone_and_the_hint_sits_under_the_switch() {
        val home = File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()
        val photos = File("src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt").readText()
        val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        assertFalse(home.contains("MediaAccessCardContent"))
        assertFalse(photos.contains("MediaAccessCard"))
        val photosCall = main.substringAfter("PhotosScreen(").substringBefore("backup = {")
        assertFalse("照片页不再接权限档", photosCall.contains("mediaAccess ="))
        val homeCall = main.substringAfter("HomeScreen(")
        assertTrue(homeCall.contains("mediaAccess == MediaAccess.PARTIAL -> R.string.auto_backup_rule_partial_hint"))
        assertTrue(homeCall.contains("mediaAccess == MediaAccess.NONE -> R.string.auto_backup_rule_none_hint"))
    }
}
