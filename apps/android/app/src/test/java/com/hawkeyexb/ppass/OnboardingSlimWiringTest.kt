package com.hawkeyexb.ppass

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1263 的接线（本仓没有 Robolectric，按源码形状钉住）：没有完成页；首次选范围点「开始备份」就走完 onboarding；
 * 后台备份关着时打开 App 照样前台补传（否则「拍一张试试」不成立）。
 */
class OnboardingSlimWiringTest {
    private val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
    private val firstTime = main.substringAfter("is Screen.Buckets -> {").substringAfter("if (s.firstTime) {").substringBefore("} else if")

    @Test
    fun first_scope_save_finishes_onboarding_and_goes_home() {
        assertTrue(firstTime.contains("OnboardedDesktopsStore(context.filesDir).markOnboarded(s.pairing.daemonNodeId)"))
        assertTrue("后台备份默认关", firstTime.contains("disableAutoBackup(context)"))
        assertTrue(firstTime.contains("requestFlowScopeBackfillAndWake(context, constraintsSatisfied)"))
        val after = main.substringAfter("is Screen.Buckets -> {").substringAfter("if (s.firstTime) {").substringBefore("onCancel =")
        assertTrue(after.contains("triggerUserPresentBackup(context)"))
        assertTrue(after.contains("screen = Screen.Home(s.pairing)"))
        assertFalse(main.contains("BackupStartedScreen"))
    }

    @Test
    fun scope_save_carries_the_time_and_widening_backfills() {
        val buckets = main.substringAfter("is Screen.Buckets -> {").substringBefore("onCancel =")
        assertTrue(buckets.contains("sinceSec = since,"))
        assertTrue(buckets.contains("sinceToSave(time, prevSince, System.currentTimeMillis())"))
        assertTrue(buckets.contains("added.isNotEmpty() || sinceWidened(prevSince, since)"))
    }

    @Test
    fun foreground_catchup_runs_even_with_background_backup_off() {
        val fn = main.substringAfter("val foregroundCatchup = {").substringBefore("LaunchedEffect(backupInterrupted)")
        val gated = fn.substringAfter("if (AutoBackupPrefs(context.filesDir).enabled()) {").substringBefore("}")
        assertTrue("后台监听仍挂在后台开关上", gated.contains("scheduleAutoBackup(context)"))
        assertFalse("前台补传不许挂在后台开关上", gated.contains("triggerUserPresentBackup"))
        assertTrue(fn.contains("triggerUserPresentBackup(context)"))
    }

    @Test
    fun engine_and_counts_use_the_full_scope() {
        val runtime = File("src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidFlowRuntime.kt").readText()
        assertTrue(runtime.contains("ContentResolverMediaSnapshotSource(app, { scopeStore.scope() })"))
        assertTrue(runtime.contains("inScope = { bucket, added -> scopeStore.scope()?.contains(bucket, added) == true }"))
        val holder = File("src/main/java/com/hawkeyexb/ppass/backup/BackupUiStateHolder.kt").readText()
        assertTrue("首页分母跟着新范围算", holder.contains("countAll(it, sinceSec)"))
        assertTrue(holder.contains("g.facts(bucketIds, total, sinceSec)"))
    }

    @Test
    fun photos_tab_guides_to_the_scope_picker_when_no_album_is_chosen() {
        val photos = File("src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt").readText()
        assertTrue("空着时居中给引导", photos.contains("items.isEmpty() && noAlbums ->"))
        assertTrue("不空时在顶部也给", photos.contains("if (noAlbums && items.isNotEmpty())"))
        assertFalse("photos_empty 被替换", photos.contains("R.string.photos_empty"))
        assertTrue(main.contains("noAlbums = !scopeUnreadable && (selectedBucketCount ?: 0) == 0,"))
        assertTrue("按钮直达选范围页", main.contains("onChooseAlbums = { enterBucketPicker(s.pairing, firstTime = false) },"))
        for (dir in listOf("values", "values-zh")) {
            val xml = File("src/main/res/$dir/strings.xml").readText()
            for (k in listOf("photos_no_albums", "photos_choose_albums", "home_empty_camera", "home_empty_albums")) {
                assertTrue("$dir 缺 $k", xml.contains("name=\"$k\""))
            }
            assertFalse(xml.contains("name=\"photos_empty\""))
        }
    }
}
