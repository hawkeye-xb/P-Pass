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

    @Test
    fun scope_time_prefers_capture_and_falls_back_only_to_modified_time() {
        assertEquals(2_000L, scopeTimeSecOf(dateTakenMs = 2_000_999L, modifiedAtSec = 3_000L))
        assertEquals("没有拍摄时间才回退 mtime", 3_000L, scopeTimeSecOf(0L, 3_000L))
        assertEquals("两级都未知就是未知，不能再回退 DATE_ADDED", 0L, scopeTimeSecOf(0L, 0L))
    }

    @Test
    fun legacy_folders_stay_selected_until_a_unified_scope_is_saved() {
        val folder = 0x4000000000000001L
        assertEquals(setOf(folder), effectiveBackupScope(null, null, setOf(folder), null)?.buckets)
        val legacyAlbums = BackupScope(setOf(7L), 100L)
        assertEquals(setOf(7L, folder), effectiveBackupScope(legacyAlbums, setOf(7L), setOf(folder), 100L)?.buckets)
        assertEquals("新版保存里取消勾选目录后不能再并回去", setOf(7L), effectiveBackupScope(legacyAlbums, setOf(7L, folder), setOf(folder), 100L)?.buckets)
        assertEquals("移除授权后，已保存的旧 bucket 也退出范围", setOf(7L), effectiveBackupScope(legacyAlbums, setOf(7L, folder), emptySet(), 100L)?.buckets)
        assertNull("从未保存且没有目录 = 没有可用来源", effectiveBackupScope(null, null, emptySet(), null))
    }

    /**
     * 产品口径：只有从未保存过范围（且没有既有目录）才第一次引导/强制进范围页。
     * 保存过任何值（包括空集）都是明确选择——不再跳页、不再反复引导；读取失败按已定过范围处理。
     */
    @Test
    fun first_choice_only_before_any_scope_is_saved() {
        assertTrue("从未保存且没有目录：唯一一次引导", scopeNeedsFirstChoice(ScopeRead.NeverSaved, existingFolderCount = 0))
        assertFalse("已有目录 = 已经定过来源", scopeNeedsFirstChoice(ScopeRead.NeverSaved, existingFolderCount = 1))
        assertFalse("保存过空集是明确选择，不再引导", scopeNeedsFirstChoice(ScopeRead.Saved(emptySet()), existingFolderCount = 0))
        assertFalse("保存过相册范围", scopeNeedsFirstChoice(ScopeRead.Saved(setOf(7L)), existingFolderCount = 0))
        assertFalse("只剩被删目录也是保存过", scopeNeedsFirstChoice(ScopeRead.Saved(setOf(0x4000000000000003L)), existingFolderCount = 0))
        assertFalse("读不到不是从未保存", scopeNeedsFirstChoice(ScopeRead.Unreadable(IllegalStateException("x")), existingFolderCount = 0))
    }

    /** 产品口径：目录也是来源——只有目录时不能判成「没有来源」，首页也不能说「未选相册」。 */
    @Test
    fun folder_only_scope_is_a_real_source() {
        val folder = 0x4000000000000003L
        assertFalse("只有已登记目录：有来源", noAlbumsOf(setOf(folder), emptySet(), setOf(folder)))
        assertTrue("目录已移除登记：没有来源", noAlbumsOf(setOf(folder), emptySet(), emptySet()))
        assertFalse(
            "范围空集但目录还登记着：引擎会把它并进有效范围，不能判成没有来源",
            noAlbumsOf(emptySet(), emptySet(), setOf(folder)),
        )
    }

    /**
     * #1794 阻断：设置页「添加文件夹」只写 registry、不调 saveScope，引擎的 [effectiveBackupScope] 照样把它并进
     * 有效范围并真的备份——首页的来源判据必须与引擎同一口径，不能只看已保存范围里有没有目录 id。
     */
    @Test
    fun registered_folder_without_a_saved_scope_counts_as_a_source() {
        val folder = 0x4000000000000003L
        assertFalse(
            "从未保存范围、只从设置页加了一个目录：首页要说有来源，不是「未选定自动备份范围」",
            noAlbumsOf(null, emptySet(), setOf(folder), knownBucketIds = null),
        )
        assertFalse(
            "旧相册范围里的相册被删、只加目录：目录仍在引擎的有效范围里",
            noAlbumsOf(setOf(9L), emptySet(), setOf(folder), knownBucketIds = setOf(9L)),
        )
        assertTrue(
            "移除目录后恢复为没有来源",
            noAlbumsOf(setOf(9L), emptySet(), emptySet(), knownBucketIds = setOf(9L)),
        )
        assertTrue(
            "从未保存范围、目录也移除了：没有来源",
            noAlbumsOf(null, emptySet(), emptySet(), knownBucketIds = null),
        )
        assertFalse(
            "相册还在时照常算来源",
            noAlbumsOf(setOf(7L), setOf(7L), emptySet(), knownBucketIds = setOf(7L)),
        )
    }

    /** 统一范围保存时目录被明确取消勾选（known 里有目录 id）：引擎不会备份它，首页也不能说有来源。 */
    @Test
    fun unified_scope_without_folders_has_no_folder_source() {
        val folder = 0x4000000000000003L
        assertTrue(
            "保存过统一范围且明确不选目录，之后目录仍在 registry 里也不算来源",
            noAlbumsOf(emptySet(), emptySet(), setOf(folder), knownBucketIds = setOf(folder)),
        )
    }

    /**
     * #1794：首页来源判据的接线——`known_bucket_ids` 与目录登记表每次刷新都要重读，
     * 设置页加/删目录后（onResume、引擎 revision 都是 recount=false）首页不会停在旧来源。
     */
    @Test
    fun home_refreshes_known_ids_and_folder_registry_on_every_refresh() {
        val holder = File("src/main/java/com/hawkeyexb/ppass/backup/BackupUiStateHolder.kt").readText()
        assertTrue("known_bucket_ids 每次刷新都重读", holder.contains("scopeStore.knownBucketIds()"))
        assertTrue(
            "来源判据把已知来源传给 noAlbumsOf，与引擎同口径",
            holder.contains("noAlbumsOf(bucketIds, existingBuckets, folderBuckets, knownSources)"),
        )
        val everyRefresh = holder
            .substringAfter("private fun currentFacts(")
            .substringBefore("if (recount || inScopeTotal == null)")
        assertTrue(
            "目录登记表在 recount 分支之外重读：onResume / revision 的 recount=false 也要更新",
            everyRefresh.contains("FolderAccess.registry(context).allRecords()"),
        )
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

    // 10-30：只给了部分照片 = 用户亲手挑了要传的那几张，默认「全部」，否则挑的老照片一张都不传。
    @Test
    fun partial_access_opens_on_all_unless_a_choice_was_saved() {
        assertEquals(ScopeTime.ALL, initialScopeTime(saved = false, sinceSec = null, partialAccess = true))
        assertEquals("全部权限仍默认从今天起", ScopeTime.SINCE_TODAY, initialScopeTime(saved = false, sinceSec = null, partialAccess = false))
        assertEquals("存过就回显，不被权限档改掉", ScopeTime.SINCE_TODAY, initialScopeTime(saved = true, sinceSec = 5L, partialAccess = true))
        assertEquals(ScopeTime.ALL, initialScopeTime(saved = true, sinceSec = null, partialAccess = true))
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
