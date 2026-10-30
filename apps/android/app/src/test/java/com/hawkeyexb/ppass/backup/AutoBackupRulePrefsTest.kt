// #1272：「自动备份」规则开关——默认关，只认显式设置，不从旧状态推导（不做升级迁移）。
package com.hawkeyexb.ppass.backup

import java.nio.file.Files
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoBackupRulePrefsTest {
    private fun dir() = Files.createTempDirectory("rule").toFile()

    // 反证：enabled() 在没有文件时返回 true（或去推导）→ 新装默认开，红。
    @Test
    fun `it is off by default`() {
        assertFalse(AutoBackupRulePrefs(dir()).enabled())
    }

    @Test
    fun `an explicit choice is persisted`() {
        val d = dir()
        AutoBackupRulePrefs(d).set(true)
        assertTrue(AutoBackupRulePrefs(d).enabled())
        AutoBackupRulePrefs(d).set(false)
        assertFalse(AutoBackupRulePrefs(d).enabled())
    }
}
