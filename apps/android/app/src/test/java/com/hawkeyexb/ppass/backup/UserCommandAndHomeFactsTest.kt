// #1020（命令）与 #1038（首页计数读库失败、未选相册），对位 iOS SettingsFeedbackTests / NotificationAndCountsTests。
//
// 行为在纯函数这一层真跑（本仓 Android 没有 Robolectric，holder 要 Context）；holder 与 MainActivity 的接线
// 用源文本门禁钉住（只钉「接线还在」，不钉行为）。
//
// 反证：
// - attemptUserCommand 去掉 catch → command_that_throws_* 变红（异常抛到测试里）；
// - factsOrUnreadable 去掉 catch → unreadable_counts_* 变红；
// - idleUiStateOf / flowAllDone / flowTripletOf 去掉 countsReadable 短路 → unreadable_counts_never_conclude 变红；
// - idleUiStateOf 去掉 noAlbums 分支 → no_albums_* 变红；heroRenderOf 去掉两条新分支 → hero_* 变红。
package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.backup.flow.EngineView
import com.hawkeyexb.ppass.backup.flow.FlowProjection
import com.hawkeyexb.ppass.backup.flow.GlobalState
import com.hawkeyexb.ppass.backup.flow.backupUiStateOf
import com.hawkeyexb.ppass.backup.flow.flowTripletOf
import com.hawkeyexb.ppass.log.PLog
import com.hawkeyexb.ppass.ui.BackupUiState
import com.hawkeyexb.ppass.ui.HeroRender
import com.hawkeyexb.ppass.ui.heroRenderOf
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class UserCommandAndHomeFactsTest {
    private val logs = mutableListOf<String>()

    @Before
    fun setUp() {
        PLog.sink = PLog.Sink { _, _, m -> logs += m }
    }

    @After
    fun tearDown() = PLog.resetSink()

    // ---------------------------------------------------------------- #1020 命令

    @Test
    fun command_that_throws_is_reported_not_swallowed_or_crashed() = runBlocking {
        val r = attemptUserCommand("restore-skipped") { error("ledger write failed") }
        assertTrue(r.isFailure)
        assertTrue(logs.any { it.startsWith("command failed (restore-skipped)") })
    }

    @Test
    fun state_not_allowed_is_not_an_error() = runBlocking {
        // 引擎在不允许的状态下返回 null / false（cancelRemaining / pause / resume），那不是出错：不提示，只刷新。
        val r = attemptUserCommand<Int?>("cancel-remaining") { null }
        assertTrue(r.isSuccess)
        assertTrue(logs.contains("command cancel-remaining ok"))
    }

    @Test
    fun cancellation_is_not_turned_into_a_command_failure() {
        assertThrows(CancellationException::class.java) {
            runBlocking { attemptUserCommand("retry") { throw CancellationException("scope gone") } }
        }
    }

    @Test
    fun holder_and_activity_route_commands_through_the_feedback_path() {
        val holder = source("backup/BackupUiStateHolder.kt")
        assertFalse("不许再用 runCatching{}.getOrNull() 吞掉命令出错", holder.contains("runCatching { g.remainingSnapshot() }.getOrNull()"))
        assertTrue(holder.contains("attemptUserCommand(what) { block() }"))
        assertTrue(holder.contains(".onFailure { _notices.tryEmit(R.string.command_failed) }"))
        assertTrue(holder.contains("attemptUserCommand(\"remaining-snapshot\") { g.remainingSnapshot() }"))
        assertTrue("「再试一次」要等引擎做完，不能另起线程 fire-and-forget", holder.contains("FlowCommand.Retry -> gateway?.retryFailed()"))
        val main = source("MainActivity.kt")
        assertTrue(main.contains("holder.notices.collect { snackbarHostState.showSnackbar(context.getString(it)) }"))
    }

    @Test
    fun activity_routes_every_settings_write_through_the_writer() {
        val main = source("MainActivity.kt")
        listOf(
            "settingsWriter.persist(\"wifiOnly\", true, backupSettings::save)",
            "settingsWriter.persist(\"wifiOnly\", false, backupSettings::save)",
            "settingsWriter.persist(\"notifyOnFailure\", enabled, notifyOnFailurePrefs::setEnabled)",
            "settingsWriter.persist(\"notifyOnFailure\", granted, notifyOnFailurePrefs::setEnabled)",
            "settingsWriter.write(\"autoBackup\", false) { disableAutoBackup(context) }",
            "settingsWriter.write(\"autoBackup\", true) { enableAutoBackup(context) }",
            "settingsWriter.write(\"backupScope\", sel.size, R.string.scope_save_failed)",
        ).forEach { assertTrue("MainActivity 缺少 `$it`", main.contains(it)) }
        assertFalse("写盘不许绕过 SettingsWriter", Regex("""\n\s+backupSettings\.save\(""").containsMatchIn(main))
        assertFalse("写盘不许绕过 SettingsWriter", Regex("""\n\s+notifyOnFailurePrefs\.setEnabled\(""").containsMatchIn(main))
        assertTrue(main.contains("scopeUnreadable = scopeUnreadable"))
    }

    // ---------------------------------------------------------------- #1038 计数读库失败

    private val idleNothingPending = EngineView(GlobalState.IDLE, pending = 0)

    @Test
    fun unreadable_counts_are_marked_not_thrown_and_keep_n_and_the_view() {
        val p = factsOrUnreadable(inScopeTotal = 7, view = idleNothingPending, onUnreadable = {}) { error("db locked") }
        assertFalse(p.countsReadable)
        assertEquals(7L, p.inScopeTotal)
        assertEquals(idleNothingPending, p.view)
        assertFalse("引擎视图变化只 copy(view)，这一位要带着走", p.copy(view = null).countsReadable)
    }

    @Test
    fun unreadable_counts_failure_is_handed_to_the_logger() {
        var seen: Exception? = null
        factsOrUnreadable(inScopeTotal = null, view = null, onUnreadable = { seen = it }) { error("db locked") }
        assertTrue(seen is IllegalStateException)
    }

    @Test
    fun unreadable_counts_never_conclude() {
        // 反证组合（同 iOS）：引擎视图待办 = 0、范围已知、计数读不到——不许出「都存好了」，也不许据占位 0 出别的结论。
        val p = FlowProjection.unreadable(inScopeTotal = 5, view = idleNothingPending)
        assertEquals(BackupUiState.Idle, backupUiStateOf(p))
        assertNull(flowTripletOf(p, setOf(1L)))
        assertEquals(HeroRender.CountsUnreadable, heroRenderOf(MediaAccess.FULL, null, countsReadable = false))
    }

    @Test
    fun readable_counts_still_conclude() {
        val p = FlowProjection(view = idleNothingPending, confirmed = 5, inScopeTotal = 5, failed = 0)
        assertTrue(backupUiStateOf(p) is BackupUiState.AllSafe)
    }

    @Test
    fun runtime_not_ready_is_not_reported_as_unreadable() {
        val holder = source("backup/BackupUiStateHolder.kt")
        assertTrue("运行时没就绪（gateway == null）仍是不发布，不是「读不到」", holder.contains("val g = gateway ?: return null"))
        assertTrue(holder.contains("_countsReadable.value = p.countsReadable"))
        assertTrue(source("MainActivity.kt").contains("countsReadable = holder.countsReadable.value"))
        assertTrue(source("MainActivity.kt").contains("LaunchedEffect(holder, resumeCount) { holder.onResume() }"))
    }

    // ---------------------------------------------------------------- #1038 未选相册

    @Test
    fun no_albums_when_never_saved_unreadable_empty_or_all_gone() {
        assertTrue(noAlbumsOf(null, setOf(1L)))
        assertTrue(noAlbumsOf(emptySet(), setOf(1L)))
        assertTrue("选中的相册都不存在了（#836 口径）", noAlbumsOf(setOf(9L), setOf(1L)))
        assertFalse(noAlbumsOf(setOf(1L), setOf(1L)))
        assertFalse("读不到现有相册时沿用已选个数", noAlbumsOf(setOf(9L), null))
    }

    @Test
    fun no_albums_outranks_trouble_and_all_safe_when_idle() {
        val failed = FlowProjection(view = idleNothingPending, confirmed = 0, inScopeTotal = 0, failed = 2)
        assertEquals(BackupUiState.NoAlbums, backupUiStateOf(failed, noAlbums = true))
        assertTrue(backupUiStateOf(failed, noAlbums = false) is BackupUiState.Trouble)
        val running = FlowProjection(view = EngineView(GlobalState.PAUSED, pending = 3), confirmed = 0, inScopeTotal = 0, failed = 0)
        assertEquals("非空闲态不受影响", BackupUiState.Paused, backupUiStateOf(running, noAlbums = true))
    }

    @Test
    fun hero_says_no_albums_when_scope_never_saved_and_unreadable_when_it_was() {
        assertEquals(HeroRender.NoAlbums, heroRenderOf(MediaAccess.FULL, null, scopeSaved = false))
        assertEquals(HeroRender.Unreadable, heroRenderOf(MediaAccess.FULL, null, scopeSaved = true))
        assertEquals("权限优先", HeroRender.AccessBlocked, heroRenderOf(MediaAccess.PARTIAL, null, countsReadable = false, scopeSaved = false))
        assertEquals("账本读不到先于「未选相册」", HeroRender.CountsUnreadable, heroRenderOf(MediaAccess.FULL, null, countsReadable = false, scopeSaved = false))
        val home = source("ui/HomeScreen.kt")
        assertTrue(home.contains("HeroRender.CountsUnreadable -> R.string.hero_counts_unreadable"))
        assertTrue(home.contains("HeroRender.NoAlbums -> R.string.backup_scope_none"))
        assertTrue(home.contains("stringResource(R.string.backup_scope_unreadable)"))
    }

    private fun source(path: String) = File("src/main/java/com/hawkeyexb/ppass/$path").readText()
}
