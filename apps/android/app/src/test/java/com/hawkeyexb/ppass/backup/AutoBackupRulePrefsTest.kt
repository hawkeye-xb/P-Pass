// #1272：「自动备份」规则开关——老用户（已有备份范围）升级后视为已开，新用户为关；显式设置优先于推导。
package com.hawkeyexb.ppass.backup

import java.nio.file.Files
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoBackupRulePrefsTest {
    private fun dir() = Files.createTempDirectory("rule").toFile()

    // 反证：enabled() 不看 hasScope（恒 false）→ 老用户升级后被关掉自动备份，红。
    @Test
    fun `an upgrading user with a scope is treated as on and a new user as off`() {
        assertTrue(AutoBackupRulePrefs(dir(), hasScope = { true }).enabled())
        assertFalse(AutoBackupRulePrefs(dir(), hasScope = { false }).enabled())
    }

    // 推导只在没有文件时做一次并落盘；之后用户显式关掉，范围还在也不能被再推成开。
    @Test
    fun `an explicit choice wins over the scope-derived default`() {
        val d = dir()
        val prefs = AutoBackupRulePrefs(d, hasScope = { true })
        assertTrue(prefs.enabled())
        prefs.set(false)
        assertFalse(AutoBackupRulePrefs(d, hasScope = { true }).enabled())
        prefs.set(true)
        assertTrue(AutoBackupRulePrefs(d, hasScope = { false }).enabled())
    }
}
