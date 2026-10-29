package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.backup.order.SqliteOrderStore
import java.io.File
import java.nio.file.Files
import java.time.LocalDateTime
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** #1263：范围 = 相册 + 开始时间；首次默认勾相机相册；首页「开启后台备份」卡片。判据全是纯函数。 */
class BackupScopeTimeTest {
    private val shanghai = ZoneId.of("Asia/Shanghai")
    private fun ms(y: Int, mo: Int, d: Int, h: Int, mi: Int, zone: ZoneId = shanghai) =
        LocalDateTime.of(y, mo, d, h, mi).atZone(zone).toInstant().toEpochMilli()
    private fun sec(y: Int, mo: Int, d: Int, h: Int, mi: Int, zone: ZoneId = shanghai) = ms(y, mo, d, h, mi, zone) / 1000

    // ── inScope 加了时间条件 ──────────────────────────────────

    @Test
    fun scope_contains_needs_album_and_time() {
        val since = 1_000L
        val scope = BackupScope(setOf(7L), since)
        assertTrue(scope.contains(7L, since))
        assertTrue(scope.contains(7L, since + 1))
        assertFalse("今天之前进相册的不在范围里", scope.contains(7L, since - 1))
        assertFalse("相册不在范围里，时间对也不算", scope.contains(8L, since + 1))
        val all = BackupScope(setOf(7L), null)
        assertTrue("全部 = 不看时间", all.contains(7L, 0L))
        assertFalse(all.contains(8L, 0L))
    }

    // ── 「今天」从当天零点算 ──────────────────────────────────

    @Test
    fun today_starts_at_local_midnight_not_at_save_time() {
        assertEquals(sec(2026, 10, 29, 0, 0), startOfLocalDaySec(ms(2026, 10, 29, 15, 42), shanghai))
        assertEquals(sec(2026, 10, 29, 0, 0), startOfLocalDaySec(ms(2026, 10, 29, 0, 0), shanghai))
        assertEquals("23:59 仍是当天", sec(2026, 10, 29, 0, 0), startOfLocalDaySec(ms(2026, 10, 29, 23, 59), shanghai))
        // 按手机本地时区算：同一个时刻在 UTC 还是 28 号。
        val utc = ZoneId.of("UTC")
        assertEquals(sec(2026, 10, 28, 0, 0, utc), startOfLocalDaySec(ms(2026, 10, 29, 3, 0), utc))
    }

    @Test
    fun since_to_save_keeps_an_existing_day_and_never_slides() {
        val now = ms(2026, 10, 29, 15, 0)
        val todayStart = sec(2026, 10, 29, 0, 0)
        assertNull(sinceToSave(ScopeTime.ALL, previousSinceSec = todayStart, nowMs = now, zone = shanghai))
        assertEquals("首次 / 原来是全部 → 今天 0 点", todayStart, sinceToSave(ScopeTime.SINCE_TODAY, null, now, shanghai))
        val earlier = sec(2026, 10, 25, 0, 0)
        assertEquals("原来从 25 号起，再保存仍从 25 号起（中间几天的照片不能掉出去）", earlier, sinceToSave(ScopeTime.SINCE_TODAY, earlier, now, shanghai))
    }

    // ── 从今天起 ↔ 全部 的扩大与缩小 ────────────────────────────

    @Test
    fun widening_and_narrowing() {
        val d = 1_000L
        assertTrue("从今天起 → 全部 = 扩大，走补扫", sinceWidened(d, null))
        assertTrue("开始时间提前也是扩大", sinceWidened(d, d - 1))
        assertFalse("全部 → 从今天起 = 缩小，不补扫", sinceWidened(null, d))
        assertFalse(sinceWidened(d, d))
        assertFalse(sinceWidened(null, null))
    }

    @Test
    fun picker_opens_on_the_saved_time_choice() {
        assertEquals("首次默认从今天起", ScopeTime.SINCE_TODAY, initialScopeTime(saved = false, sinceSec = null))
        assertEquals("老用户的范围没有时间 = 全部", ScopeTime.ALL, initialScopeTime(saved = true, sinceSec = null))
        assertEquals(ScopeTime.SINCE_TODAY, initialScopeTime(saved = true, sinceSec = 5L))
    }

    // ── 首次默认勾上相机相册 ────────────────────────────────────

    @Test
    fun first_time_selects_the_camera_album_by_default() {
        assertEquals(setOf(11L), initialSelection(saved = null, firstTime = true, cameraBucketIds = setOf(11L)))
        assertEquals("识别不到相机相册就不勾，退回原行为", emptySet<Long>(), initialSelection(null, firstTime = true, cameraBucketIds = emptySet()))
        assertEquals("存过范围就用存下的", setOf(3L), initialSelection(setOf(3L), firstTime = true, cameraBucketIds = setOf(11L)))
        assertEquals("存过空集也照样用（用户自己取消的）", emptySet<Long>(), initialSelection(emptySet(), firstTime = true, cameraBucketIds = setOf(11L)))
        assertEquals("设置里进来、从没存过：原行为一个都不勾", emptySet<Long>(), initialSelection(null, firstTime = false, cameraBucketIds = setOf(11L)))
    }

    @Test
    fun camera_album_is_recognised_by_dcim_camera() {
        assertTrue(isCameraPath("DCIM/Camera/", null))
        assertTrue(isCameraPath("DCIM/Camera", null))
        assertTrue("不区分大小写", isCameraPath("dcim/camera/", null))
        assertFalse(isCameraPath("DCIM/Screenshots/", null))
        assertFalse("相机目录下的子目录不算", isCameraPath("DCIM/Camera/Raw/", null))
        assertFalse(isCameraPath("Pictures/WeiXin/", null))
        // API 28 及以下没有 RELATIVE_PATH，看 _data。
        assertTrue(isCameraPath(null, "/storage/emulated/0/DCIM/Camera/IMG_1.jpg"))
        assertFalse(isCameraPath(null, "/storage/emulated/0/Pictures/IMG_1.jpg"))
        assertFalse(isCameraPath(null, null))
    }

    // ── 订单库：v5→v6 只加列，计数按时间过滤 ───────────────────────

    @Test
    fun order_db_v6_only_adds_columns_and_counts_filter_by_time() {
        assertTrue(SqliteOrderStore.V5_TO_V6.all { it.startsWith("ALTER TABLE") && it.contains("ADD COLUMN date_added_sec") })
        assertEquals(" AND o.bucket_id IN (1,2) AND o.date_added_sec >= 100", SqliteOrderStore.scopeFilter(setOf(1L, 2L), 100L, "o."))
        assertEquals(" AND bucket_id IN (1)", SqliteOrderStore.scopeFilter(setOf(1L), null, ""))
        assertEquals("", SqliteOrderStore.scopeFilter(null, null, "o."))
    }

    // ── 首页「开启后台备份」卡片 ─────────────────────────────────

    @Test
    fun background_backup_offer_shows_until_enabled_or_dismissed() {
        assertTrue(showBackgroundBackupOffer(BackgroundBackupState.OffByUser, dismissed = false))
        assertFalse("手动关掉了", showBackgroundBackupOffer(BackgroundBackupState.OffByUser, dismissed = true))
        assertFalse("开着", showBackgroundBackupOffer(BackgroundBackupState.Armed, dismissed = false))
        // 点了「开启」但系统授权被拒：意图仍是开，由「允许系统后台运行」那张提示接手（同一个位置）。
        assertFalse(showBackgroundBackupOffer(BackgroundBackupState.NeedsSystemAuthorization, dismissed = false))
    }

    @Test
    fun offer_dismissal_persists() {
        val dir: File = Files.createTempDirectory("offer").toFile()
        try {
            assertFalse(BackgroundBackupOfferStore(dir).dismissed())
            BackgroundBackupOfferStore(dir).dismiss()
            assertTrue(BackgroundBackupOfferStore(dir).dismissed())
            File(dir, BackgroundBackupOfferStore.FILE_NAME).writeText("{broken")
            assertFalse("损坏当没关过", BackgroundBackupOfferStore(dir).dismissed())
        } finally {
            dir.deleteRecursively()
        }
    }
}
