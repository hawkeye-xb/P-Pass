package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.MediaScanner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2067 / #1961 / #1811：备份范围页（BucketScreen）业务状态与逻辑的 JVM 行为单测。
 * 真实渲染与 1.5× 大字号几何断言见 androidTest `BucketScreenComposeTest` 与 `NativeControlsScreensTest`。
 */
class UI08BucketScreenTest {

    @Test
    fun folder_section_only_appears_when_folders_exist() {
        assertFalse(
            "未添加文件夹时完全不出现文件夹区块",
            bucketScreenShowsFoldersSection(emptyList()),
        )
        val folder = FolderBucketUi(
            key = "content://f1",
            bucket = MediaScanner.Bucket(10L, "Blackmagic", 5),
            registered = true,
        )
        assertTrue(
            "添加过文件夹后按需显示文件夹分组",
            bucketScreenShowsFoldersSection(listOf(folder)),
        )
    }

    @Test
    fun expired_folder_row_flags_needs_permission_and_direct_reauthorize() {
        assertFalse(bucketFolderShowsDirectReauthorize(needsPermission = false))
        assertTrue(bucketFolderShowsDirectReauthorize(needsPermission = true))
        assertEquals(R.string.folder_status_ok, bucketFolderStatusRes(needsPermission = false))
        assertEquals(R.string.folder_status_needs_permission, bucketFolderStatusRes(needsPermission = true))
    }

    @Test
    fun only_full_photo_access_offers_album_choices_and_notice_key_matches() {
        assertFalse("部分照片权限对相册自动备份与无权限相同，不给选相册", bucketScreenOffersAlbumChoices(MediaAccess.PARTIAL))
        assertFalse("没有相册权限时不给选相册", bucketScreenOffersAlbumChoices(MediaAccess.NONE))
        assertTrue("完整照片权限才给选相册", bucketScreenOffersAlbumChoices(MediaAccess.FULL))
        assertEquals("scope_album_no_access_title", bucketScreenAccessNoticeKey(MediaAccess.PARTIAL))
        assertEquals("scope_album_no_access_title", bucketScreenAccessNoticeKey(MediaAccess.NONE))
        assertEquals(null, bucketScreenAccessNoticeKey(MediaAccess.FULL))
    }

    @Test
    fun visible_album_buckets_keep_only_checked_ones_until_full_access() {
        val a = MediaScanner.Bucket(1L, "A", 3)
        val b = MediaScanner.Bucket(2L, "B", 4)
        assertEquals("完整授权显示全部", listOf(a, b), visibleAlbumBuckets(listOf(a, b), emptySet(), MediaAccess.FULL))
        assertEquals("部分权限下已勾选的保留、没勾的不展示", listOf(a), visibleAlbumBuckets(listOf(a, b), setOf(1L), MediaAccess.PARTIAL))
        assertEquals("无权限下同样只保留已勾选的（可取消）", listOf(a), visibleAlbumBuckets(listOf(a, b), setOf(1L), MediaAccess.NONE))
        assertEquals("部分权限下一个都没勾就不展示任何相册", emptyList<MediaScanner.Bucket>(), visibleAlbumBuckets(listOf(a, b), emptySet(), MediaAccess.PARTIAL))
    }

    @Test
    fun whole_phone_empty_copy_needs_full_photo_access() {
        assertTrue(bucketScreenEmptyNoticeVisible(bucketsEmpty = true, foldersEmpty = true, access = MediaAccess.FULL))
        assertFalse(
            "部分照片权限时读不到全部照片，不得声称整机没有照片",
            bucketScreenEmptyNoticeVisible(bucketsEmpty = true, foldersEmpty = true, access = MediaAccess.PARTIAL),
        )
        assertFalse(
            "没有相册权限时不得声称整机没有照片",
            bucketScreenEmptyNoticeVisible(bucketsEmpty = true, foldersEmpty = true, access = MediaAccess.NONE),
        )
        assertFalse(
            "还有文件夹来源时不算整机为空",
            bucketScreenEmptyNoticeVisible(bucketsEmpty = true, foldersEmpty = false, access = MediaAccess.FULL),
        )
    }

    /**
     * #2067：底部已选摘要的计数必须与 `onDone` 提交的选择一致：
     * - FULL 下仅计现存已选相册（剔除已被系统删除的残留 id）；
     * - PARTIAL / NONE 下保留在 `checked` 里的不可见已保存相册仍会在 `onDone` 提交，必须计入摘要，
     *   只有真正全空时才报「未选来源」。
     */
    @Test
    fun summary_counts_match_submitted_selection_across_access_tiers() {
        val a = MediaScanner.Bucket(1L, "Camera", 10)
        val b = MediaScanner.Bucket(2L, "Screenshots", 4)
        val f1 = FolderBucketUi("k1", MediaScanner.Bucket(101L, "Raw", 3), registered = true)
        val f2 = FolderBucketUi("k2", MediaScanner.Bucket(102L, "Docs", 2), registered = true)

        assertEquals(2, bucketSummaryAlbumCount(listOf(a, b), setOf(1L, 2L, 99L), MediaAccess.FULL))
        assertEquals(2, bucketSummaryAlbumCount(listOf(a), setOf(1L, 2L), MediaAccess.PARTIAL))
        assertEquals(1, bucketSummaryAlbumCount(emptyList(), setOf(1L), MediaAccess.NONE))
        assertEquals(0, bucketSummaryAlbumCount(emptyList(), emptySet(), MediaAccess.NONE))
        assertEquals(1, selectedFolderCount(listOf(f1, f2), setOf("k1", "stale")))

        val editEmpty = bucketActionSummarySpec(firstTime = false, albumCount = 0, folderCount = 0)
        assertEquals(R.string.bucket_save, editEmpty.baseRes)
        assertEquals(R.string.bucket_action_empty, editEmpty.templateRes)

        val firstWithItems = bucketActionSummarySpec(firstTime = true, albumCount = 2, folderCount = 1)
        assertEquals(R.string.bucket_start, firstWithItems.baseRes)
        assertEquals(R.string.bucket_action_with_summary, firstWithItems.templateRes)
        assertEquals(2, firstWithItems.albumCount)
        assertEquals(1, firstWithItems.folderCount)
    }
}
