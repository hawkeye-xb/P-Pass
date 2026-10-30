package com.hawkeyexb.ppass.backup

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** #1262：通知默认关；老用户升级保持原状态；打开开关时按授权现状决定直接开 / 弹系统框 / 去系统设置。 */
class NotifyOnFailurePrefsTest {
    private val dir: File = Files.createTempDirectory("notify-prefs").toFile()

    @After
    fun cleanup() {
        dir.deleteRecursively()
    }

    @Test
    fun new_install_is_off() {
        val prefs = NotifyOnFailurePrefs(dir)
        assertFalse("没有文件 = 关", prefs.enabled())
        prefs.initIfAbsent(existingUser = false)
        assertFalse(prefs.enabled())
    }

    @Test
    fun upgraded_user_who_never_touched_the_switch_keeps_it_on() {
        // 上一版的默认值是开、且只有动过开关才有文件：升级上来没有文件的老用户原来就是开着的。
        val prefs = NotifyOnFailurePrefs(dir)
        prefs.initIfAbsent(existingUser = true)
        assertTrue(prefs.enabled())
    }

    @Test
    fun upgraded_user_state_on_disk_is_left_alone() {
        NotifyOnFailurePrefs(dir).setEnabled(false)
        NotifyOnFailurePrefs(dir).initIfAbsent(existingUser = true)
        assertFalse("拒绝过 / 关掉过的老用户升级后仍是关", NotifyOnFailurePrefs(dir).enabled())

        NotifyOnFailurePrefs(dir).setEnabled(true)
        NotifyOnFailurePrefs(dir).initIfAbsent(existingUser = false)
        assertTrue("开着的老用户升级后仍是开", NotifyOnFailurePrefs(dir).enabled())
    }

    @Test
    fun new_user_is_not_reclassified_as_existing_after_pairing() {
        // 第一次启动（未配对）就落盘；配对后重启再跑一次 init，不能因为「有配对」变成开。
        NotifyOnFailurePrefs(dir).initIfAbsent(existingUser = false)
        NotifyOnFailurePrefs(dir).initIfAbsent(existingUser = true)
        assertFalse(NotifyOnFailurePrefs(dir).enabled())
    }

    @Test
    fun old_file_without_system_asked_still_reads() {
        File(dir, NotifyOnFailurePrefs.FILE_NAME).writeText("""{"enabled":true}""")
        val prefs = NotifyOnFailurePrefs(dir)
        assertTrue(prefs.enabled())
        assertFalse(prefs.systemAsked())
        prefs.markSystemAsked()
        assertTrue("记「问过」不改开关", prefs.enabled())
        assertTrue(prefs.systemAsked())
    }

    @Test
    fun enabling_the_switch_decides_by_grant_state() {
        assertEquals(NotifyEnableAction.ENABLE, notifyEnableAction(granted = true, askedBefore = true, systemWillShowRationale = false))
        assertEquals(NotifyEnableAction.REQUEST, notifyEnableAction(granted = false, askedBefore = false, systemWillShowRationale = false))
        assertEquals(NotifyEnableAction.REQUEST, notifyEnableAction(granted = false, askedBefore = true, systemWillShowRationale = true))
        assertEquals(
            "问过、系统不会再弹 → 去系统设置",
            NotifyEnableAction.OPEN_SETTINGS,
            notifyEnableAction(granted = false, askedBefore = true, systemWillShowRationale = false),
        )
    }
}
