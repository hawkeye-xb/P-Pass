// UX-03: 极简设置持久化测试——默认值、保存重开、损坏回默认。
// MOB-10: chargeOnly 已删除（见 TriggerPolicy.constraintsFor），只剩
// wifiOnly 一个开关；旧版本存过的 chargeOnly 字段由 ignoreUnknownKeys
// 安全忽略，本文件末尾有向后兼容的显式断言。
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupSettingsTest {

    private fun tempDir(tag: String): File =
        java.nio.file.Files.createTempDirectory("ppass-settings-$tag").toFile()

    @Test
    fun defaults_are_wifi_only() {
        // 产品默认：WiFi 才跑自动备份（电量不低是后台档的硬约束，不是开关）。
        val s = BackupSettings(tempDir("defaults")).load()
        assertTrue("默认仅 WiFi", s.wifiOnly)
    }

    @Test
    fun save_then_reopen_survives_like_app_kill() {
        val dir = tempDir("reopen")
        BackupSettings(dir).save(wifiOnly = false)
        assertEquals(false, BackupSettings(dir).load().wifiOnly)
        dir.deleteRecursively()
    }

    @Test
    fun corrupted_file_reads_as_defaults_not_crash() {
        val dir = tempDir("corrupt")
        File(dir, "backup-settings.json").apply {
            parentFile.mkdirs()
            writeText("{not json")
        }
        assertTrue("损坏回默认", BackupSettings(dir).load().wifiOnly)
        // 恢复写入也不崩。
        BackupSettings(dir).save(wifiOnly = false)
        assertEquals(false, BackupSettings(dir).load().wifiOnly)
        dir.deleteRecursively()
    }

    @Test
    fun legacy_charge_only_field_is_ignored_not_crash() {
        // MOB-10 升级路径：装过旧版的机器上，磁盘里存的是带 chargeOnly 的
        // json。必须能正常读出 wifiOnly，而不是解析失败回默认——后者会把
        // 用户手动关掉的「仅 WiFi」悄悄打开。
        val dir = tempDir("legacy")
        File(dir, "backup-settings.json").apply {
            parentFile.mkdirs()
            writeText("""{"chargeOnly":true,"wifiOnly":false}""")
        }
        assertEquals("旧字段忽略，wifiOnly 必须原样读出", false, BackupSettings(dir).load().wifiOnly)
        dir.deleteRecursively()
    }
}
