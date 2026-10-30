// #1020（对位 iOS SettingsFeedbackTests）：设置写盘失败不崩溃、显示值回到盘上的真实值、给一过性提示、记日志；
// 相册范围「读不出来」与「从未保存」分开。
//
// 写失败是真实制造的：让偏好目录拒绝新建文件（WriteBlock：POSIX 去写权限 / Windows 加拒绝 ACL），store 的 tmp 文件写不进去（与真机「存储满 / 容器写失败」同一条抛出路径），
// 不是 mock。store 自己照旧抛出（后台写者靠它暴露问题），吞不吞只在 UI 边界 [SettingsWriter]。
//
// 反证：把 SettingsWriter.write 的 try/catch 去掉（直接 op()），write_failure_* 三条变红（异常抛到测试里）；
// 把 BackupScopeStore.parseScope 改回 mapNotNull，unparsable_scope_is_unreadable 变红。
package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.log.PLog
import com.hawkeyexb.ppass.testutil.WriteBlock
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class SettingsWriteFeedbackTest {
    private val logs = mutableListOf<String>()
    private val notices = mutableListOf<Int>()
    private val writer = SettingsWriter { notices += it }
    private lateinit var dir: File

    @Before
    fun setUp() {
        PLog.sink = PLog.Sink { _, _, m -> logs += m }
        dir = Files.createTempDirectory("settings-write").toFile()
    }

    @After
    fun tearDown() {
        WriteBlock.unblock(dir)
        dir.deleteRecursively()
        PLog.resetSink()
    }

    /** 让之后的写盘失败：tmp 文件建不出来。 */
    private fun breakWrites() {
        WriteBlock.block(dir)
    }

    @Test
    fun write_failure_wifi_only_keeps_the_disk_value_and_tells_the_user() {
        val settings = BackupSettings(dir)
        settings.save(false)
        breakWrites()

        val shown = writer.persist("wifiOnly", true, settings::save) { settings.load().wifiOnly }

        assertFalse("显示值必须回到盘上的值（原来的 false），不是用户刚点的 true", shown)
        assertEquals(listOf(R.string.setting_save_failed), notices)
        assertTrue(logs.any { it.startsWith("settings: write failed (wifiOnly)") })
    }

    @Test
    fun write_failure_notify_on_failure_keeps_the_disk_value_and_tells_the_user() {
        val prefs = NotifyOnFailurePrefs(dir)
        prefs.setEnabled(true)
        breakWrites()

        val shown = writer.persist("notifyOnFailure", false, prefs::setEnabled) { prefs.enabled() }

        assertTrue(shown)
        assertEquals(listOf(R.string.setting_save_failed), notices)
        assertTrue(logs.any { it.startsWith("settings: write failed (notifyOnFailure)") })
    }

    @Test
    fun write_failure_auto_backup_reports_false_and_leaves_both_fields_untouched() {
        val prefs = AutoBackupPrefs(dir)
        prefs.set(requested = false, enabled = false)
        breakWrites()

        val saved = writer.write("autoBackup", true) { markAutoBackupEnabled(dir) }

        assertFalse("写失败必须让调用方知道，后续的重挂任务等副作用不做", saved)
        assertFalse(prefs.requested())
        assertFalse(prefs.enabled())
        assertEquals(listOf(R.string.setting_save_failed), notices)
    }

    @Test
    fun success_is_logged_and_silent() {
        val settings = BackupSettings(dir)

        val shown = writer.persist("wifiOnly", false, settings::save) { settings.load().wifiOnly }

        assertFalse(shown)
        assertTrue(notices.isEmpty())
        assertTrue("成功也要留一行（真机取证）", logs.contains("settings: saved wifiOnly=false"))
    }

    @Test
    fun the_stores_still_throw_so_background_writers_are_not_silenced() {
        breakWrites()
        assertThrows(Exception::class.java) { BackupSettings(dir).save(true) }
        assertThrows(Exception::class.java) { AutoBackupPrefs(dir).set(requested = true, enabled = true) }
        assertThrows(Exception::class.java) { NotifyOnFailurePrefs(dir).setEnabled(false) }
    }

    @Test
    fun auto_backup_intent_and_producer_are_one_write() {
        val prefs = AutoBackupPrefs(dir)
        markAutoBackupSuspended(dir)
        assertTrue(prefs.requested())
        assertFalse(prefs.enabled())
        markAutoBackupEnabled(dir)
        assertTrue(prefs.requested())
        assertTrue(prefs.enabled())
    }

    @Test
    fun scope_failure_uses_its_own_text() {
        writer.write("backupScope", 3, R.string.scope_save_failed) { error("commit returned false") }
        assertEquals(listOf(R.string.scope_save_failed), notices)
    }

    @Test
    fun never_saved_scope_is_not_unreadable() {
        assertEquals(ScopeRead.NeverSaved, BackupScopeStore.parseScope(null))
        assertEquals(ScopeRead.Saved(emptySet()), BackupScopeStore.parseScope(""))
        assertEquals(ScopeRead.Saved(setOf(1L, 22L)), BackupScopeStore.parseScope("1,22"))
    }

    @Test
    fun unparsable_scope_is_unreadable() {
        assertTrue(
            "存了东西但解析不出来 = 读不到，不许静默丢掉坏的那段把范围缩小",
            BackupScopeStore.parseScope("1,abc,3") is ScopeRead.Unreadable,
        )
    }
}
