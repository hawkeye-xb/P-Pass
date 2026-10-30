// #1272：「自动备份」规则开关——没存过值时按当前真实状态初始化一次（权限 + 范围），之后以存下的值为准。
package com.hawkeyexb.ppass.backup

import java.nio.file.Files
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoBackupRulePrefsTest {
    private fun dir() = Files.createTempDirectory("rule").toFile()

    // 反证：initial 恒 true / 恒 false → 下面两条里总有一条红。
    @Test
    fun `the first read follows the real state - on only with permission and a scope`() {
        assertTrue(AutoBackupRulePrefs(dir(), initial = { true }).enabled())
        assertFalse(AutoBackupRulePrefs(dir(), initial = { false }).enabled())
    }

    @Test
    fun `without an initial source it is off`() {
        assertFalse(AutoBackupRulePrefs(dir()).enabled())
    }

    // 已存的值不被覆盖：初值只在没有文件时算一次并落盘。反证：每次都重新算 → 用户关掉后又被推成开，红。
    @Test
    fun `a stored value is never overwritten by the initial state`() {
        val d = dir()
        assertTrue(AutoBackupRulePrefs(d, initial = { true }).enabled())
        AutoBackupRulePrefs(d, initial = { true }).set(false)
        assertFalse(AutoBackupRulePrefs(d, initial = { true }).enabled())
        AutoBackupRulePrefs(d).set(true)
        assertTrue(AutoBackupRulePrefs(d, initial = { false }).enabled())
    }
}
