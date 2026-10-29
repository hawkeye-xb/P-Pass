package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.MediaAccess
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 10-29：照片权限不全时，照片页的引导换成设置页那张权限卡——读不到照片，「还没选相册 / 选择相册」说的不是现状。
 * 反证：[photosGuideOf] 先看 noAlbums 再看权限，部分授权 + 没选相册那条就红。
 */
class PhotosGuideTest {
    @Test
    fun incomplete_access_shows_the_access_card_not_the_album_guide() {
        for (access in listOf(MediaAccess.PARTIAL, MediaAccess.NONE)) {
            assertEquals(PhotosGuide.MediaAccess, photosGuideOf(access, noAlbums = true))
            assertEquals(PhotosGuide.MediaAccess, photosGuideOf(access, noAlbums = false))
        }
    }

    @Test
    fun full_access_keeps_the_album_guide() {
        assertEquals(PhotosGuide.NoAlbums, photosGuideOf(MediaAccess.FULL, noAlbums = true))
        assertEquals(PhotosGuide.None, photosGuideOf(MediaAccess.FULL, noAlbums = false))
    }

    @Test
    fun settings_and_photos_share_one_access_card() {
        val home = File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()
        val photos = File("src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt").readText()
        val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        assertTrue(home.contains("MediaAccessCardContent(mediaAccess, onOpenAppSettings)"))
        assertTrue(photos.contains("PhotosGuide.MediaAccess -> MediaAccessCard(mediaAccess, onOpenAppSettings, modifier)"))
        val photosCall = main.substringAfter("PhotosScreen(").substringBefore("backup = {")
        assertTrue("照片页拿到真实的权限档", photosCall.contains("mediaAccess = mediaAccess,"))
    }
}
