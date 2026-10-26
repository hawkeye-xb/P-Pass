// #1152：身份包裹密钥的安全级别写进诊断日志（只记录，不改启动行为）。
// 反证：describeKeySecurityLevel 的映射改错 ⇒ 第一条红；IdentityStore 不记这一行，或在级别不是 TEE 时拒绝启动 ⇒ 第二、三条红。
package com.hawkeyexb.ppass.transport

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KeySecurityLevelTest {
    @Test
    fun `the level maps from KeyInfo on API 31 and up, and from the boolean below`() {
        assertEquals("strongbox", describeKeySecurityLevel(34, 2, true))
        assertEquals("tee", describeKeySecurityLevel(31, 1, true))
        assertEquals("software", describeKeySecurityLevel(33, 0, false))
        assertEquals("unknown_secure", describeKeySecurityLevel(33, -1, true))
        assertEquals("unknown", describeKeySecurityLevel(33, -2, false))
        assertEquals("secure_hardware", describeKeySecurityLevel(30, null, true))
        assertEquals("software", describeKeySecurityLevel(26, null, false))
    }

    private class LevelWrapper(private val level: String) : IdentityKeyWrapper by FakeIdentityKeyWrapper() {
        override fun securityLevel() = level
    }

    @Test
    fun `resolving the identity logs the security level once and never refuses on it`() {
        for (level in listOf("tee", "strongbox", "software", "unknown")) {
            val dir = Files.createTempDirectory("ident").toFile()
            val lines = mutableListOf<String>()
            val store = IdentityStore(dir, LevelWrapper(level), log = { lines += it })
            assertEquals(32, store.secretKey().size) // 即使是 software 也照常启动
            assertEquals(1, lines.count { it == "identity: wrapping key security level=$level" })
            store.secretKey() // 缓存命中，不再记
            assertEquals(1, lines.count { it.startsWith("identity: wrapping key security level=") })
        }
    }

    @Test
    fun `a wrapper that cannot say stays unknown and the line is still logged`() {
        val lines = mutableListOf<String>()
        val store = IdentityStore(Files.createTempDirectory("ident").toFile(), FakeIdentityKeyWrapper(), log = { lines += it })
        store.secretKey()
        assertTrue(lines.toString(), lines.contains("identity: wrapping key security level=unknown"))
    }
}
