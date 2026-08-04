// UX-03: 极简设置持久化测试——默认值、保存重开、损坏回默认。
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupSettingsTest {

    private fun tempDir(tag: String): File =
        java.nio.file.Files.createTempDirectory("ppass-settings-$tag").toFile()

    @Test
    fun defaults_are_charge_and_wifi_only() {
        // 产品默认：插电 + WiFi 才跑自动备份。
        val s = BackupSettings(tempDir("defaults")).load()
        assertTrue("默认仅充电", s.chargeOnly)
        assertTrue("默认仅 WiFi", s.wifiOnly)
    }

    @Test
    fun save_then_reopen_survives_like_app_kill() {
        val dir = tempDir("reopen")
        BackupSettings(dir).save(chargeOnly = false, wifiOnly = true)
        val reopened = BackupSettings(dir).load()
        assertEquals(false, reopened.chargeOnly)
        assertEquals(true, reopened.wifiOnly)
        dir.deleteRecursively()
    }

    @Test
    fun corrupted_file_reads_as_defaults_not_crash() {
        val dir = tempDir("corrupt")
        File(dir, "backup-settings.json").apply {
            parentFile.mkdirs()
            writeText("{not json")
        }
        val s = BackupSettings(dir).load()
        assertTrue("损坏回默认", s.chargeOnly)
        assertTrue(s.wifiOnly)
        // 恢复写入也不崩。
        BackupSettings(dir).save(chargeOnly = false, wifiOnly = false)
        assertEquals(false, BackupSettings(dir).load().chargeOnly)
        dir.deleteRecursively()
    }
}
