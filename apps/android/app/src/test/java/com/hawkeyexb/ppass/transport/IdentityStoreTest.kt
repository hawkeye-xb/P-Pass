// #1106: IdentityStore state machine with Keystore abstracted (FakeIdentityKeyWrapper is real
// AES-GCM). The safety property under test: only a definitive loss ever replaces the identity;
// a transient Keystore failure touches nothing and never falls back to plaintext.
package com.hawkeyexb.ppass.transport

import java.io.File
import java.security.KeyStoreException
import java.security.ProviderException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class IdentityStoreTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var dir: File
    private val wrapper = FakeIdentityKeyWrapper()
    private val sleeps = mutableListOf<Long>()

    /** Each call to beforeNewIdentity, with what was on disk at that moment. */
    private val newIdentityCalls = mutableListOf<String>()

    private val sealed get() = File(dir, IdentityStore.SEALED_FILE)
    private val legacy get() = File(dir, IdentityStore.LEGACY_FILE)
    private val pairing get() = File(dir, "pairing.json")

    @Before
    fun setUp() {
        dir = tmp.newFolder("files")
    }

    /** A fresh store = a fresh process (no in-memory cache), same files and same Keystore. */
    private fun store(beforeNewIdentity: () -> Unit = ::recordNewIdentity) =
        IdentityStore(dir, wrapper, beforeNewIdentity = beforeNewIdentity, sleep = { sleeps += it })

    private fun recordNewIdentity() {
        newIdentityCalls += "sealed=${sealed.exists()} legacy=${legacy.exists()}"
        pairing.delete() // what the production callback (disconnect manifest) does to pairing.json
    }

    private fun seedPairing() = pairing.writeText("{}")

    private fun assertUnavailable(block: () -> Unit) {
        try {
            block()
            fail("expected IdentityUnavailableException")
        } catch (e: IdentityUnavailableException) {
            assertNotNull(e.cause)
        }
    }

    // ── 正常路径 ───────────────────────────────────────────────

    @Test
    fun first_run_mints_a_sealed_identity_and_never_writes_plaintext() {
        val key = store().secretKey()
        assertEquals(32, key.size)
        assertTrue(sealed.isFile)
        assertFalse(legacy.exists())
        assertFalse("密钥原文不许出现在盘上", sealed.readBytes().containsRun(key))
        assertEquals(listOf("sealed=false legacy=false"), newIdentityCalls)
    }

    @Test
    fun a_later_process_reads_the_same_identity_and_clears_nothing() {
        val first = store().secretKey()
        seedPairing()
        newIdentityCalls.clear()
        val again = store().secretKey()
        assertArrayEquals(first, again)
        assertTrue("同一身份不许动配对", pairing.exists())
        assertEquals(emptyList<String>(), newIdentityCalls)
        assertEquals(1, wrapper.recreated)
    }

    @Test
    fun once_resolved_the_process_does_not_go_back_to_keystore() {
        val s = store()
        val key = s.secretKey()
        wrapper.failOpen = { KeyStoreException("keystore down") }
        assertArrayEquals(key, s.secretKey())
        assertTrue(s.isReady)
    }

    @Test
    fun callers_get_a_copy_not_the_cached_array() {
        val s = store()
        val key = s.secretKey()
        s.secretKey().fill(0)
        assertArrayEquals(key, s.secretKey())
    }

    // ── 老版本明文：不迁移，换新身份 ────────────────────────────

    @Test
    fun upgrade_from_plaintext_deletes_it_clears_pairing_first_and_mints_a_new_identity() {
        val old = ByteArray(32) { 7 }
        legacy.writeBytes(old)
        File(dir, "identity.key.tmp").writeBytes(old)
        seedPairing()
        val key = store().secretKey()
        assertFalse("不迁移：新身份不是旧明文", key.contentEquals(old))
        assertFalse(legacy.exists())
        assertFalse(File(dir, "identity.key.tmp").exists())
        assertFalse("配对属于旧 NodeId，必须清", pairing.exists())
        assertEquals("清配对发生在新密文落盘之前", listOf("sealed=false legacy=true"), newIdentityCalls)
    }

    @Test
    fun a_plaintext_left_next_to_a_good_sealed_identity_is_deleted_without_touching_anything_else() {
        val key = store().secretKey()
        legacy.writeBytes(ByteArray(32) { 1 })
        seedPairing()
        newIdentityCalls.clear()
        assertArrayEquals(key, store().secretKey())
        assertFalse(legacy.exists())
        assertTrue(pairing.exists())
        assertEquals(emptyList<String>(), newIdentityCalls)
    }

    // ── 明确的丢失信号：新设备 ─────────────────────────────────

    private fun assertBecomesNewDevice(old: ByteArray) {
        seedPairing()
        newIdentityCalls.clear()
        val key = store().secretKey()
        assertFalse(key.contentEquals(old))
        assertFalse(pairing.exists())
        assertEquals(1, newIdentityCalls.size)
        // 新身份本身可用：下一个进程读回同一把。
        assertArrayEquals(key, store().secretKey())
    }

    @Test
    fun keystore_key_gone_with_the_sealed_file_still_there_is_a_new_device() {
        val old = store().secretKey()
        wrapper.key = null // e.g. Keystore wiped; or the file arrived from another phone
        assertBecomesNewDevice(old)
    }

    @Test
    fun gcm_tag_mismatch_is_a_new_device() {
        val old = store().secretKey()
        val bytes = sealed.readBytes()
        bytes[bytes.size - 1] = (bytes.last().toInt() xor 1).toByte()
        sealed.writeBytes(bytes)
        assertBecomesNewDevice(old)
    }

    @Test
    fun key_permanently_invalidated_is_a_new_device() {
        val old = store().secretKey()
        // 只有这一次 open 报失效；换新密钥之后的读回照常。
        wrapper.failOpen = OneShot { IdentityKeyGoneException("permanently invalidated") }::fire
        assertBecomesNewDevice(old)
    }

    @Test
    fun wrong_length_secret_is_a_new_device() {
        store().secretKey()
        wrapper.recreate()
        sealed.writeBytes(IdentityStore.encode(wrapper.seal(ByteArray(16))))
        assertBecomesNewDevice(ByteArray(16))
    }

    @Test
    fun truncated_sealed_file_is_a_new_device() {
        val old = store().secretKey()
        sealed.writeBytes(sealed.readBytes().copyOf(2))
        assertBecomesNewDevice(old)
    }

    @Test
    fun sealed_file_missing_but_pairing_present_is_a_new_device() {
        store().secretKey()
        sealed.delete()
        seedPairing()
        newIdentityCalls.clear()
        store().secretKey()
        assertFalse(pairing.exists())
        assertEquals(1, newIdentityCalls.size)
    }

    // ── 临时故障：什么都不碰，不回退明文 ───────────────────────

    private fun assertTransientTouchesNothing(inject: () -> Unit) {
        val key = store().secretKey()
        seedPairing()
        val sealedBefore = sealed.readBytes()
        val recreatedBefore = wrapper.recreated
        newIdentityCalls.clear()
        sleeps.clear()
        inject()
        assertUnavailable { store().secretKey() }
        assertArrayEquals("密文原样", sealedBefore, sealed.readBytes())
        assertTrue("配对原样", pairing.exists())
        assertFalse("不回退明文", legacy.exists())
        assertEquals("不换密钥", recreatedBefore, wrapper.recreated)
        assertEquals(emptyList<String>(), newIdentityCalls)
        assertEquals("有界退避重试", listOf(300L, 1000L), sleeps)
        // 故障消失后，同一身份回来。
        wrapper.failOpen = null
        wrapper.failExists = null
        assertArrayEquals(key, store().secretKey())
    }

    @Test
    fun keystore_failure_on_open_touches_nothing() =
        assertTransientTouchesNothing { wrapper.failOpen = { KeyStoreException("keystore2 busy") } }

    @Test
    fun provider_exception_on_open_touches_nothing() =
        assertTransientTouchesNothing { wrapper.failOpen = { ProviderException("keymint failure") } }

    @Test
    fun keystore_failure_on_exists_touches_nothing() =
        assertTransientTouchesNothing { wrapper.failExists = { KeyStoreException("not initialized") } }

    @Test
    fun unknown_format_version_is_not_treated_as_loss() {
        val key = store().secretKey()
        val bytes = sealed.readBytes().also { it[0] = 9 }
        sealed.writeBytes(bytes)
        seedPairing()
        newIdentityCalls.clear()
        assertUnavailable { store().secretKey() }
        assertArrayEquals(bytes, sealed.readBytes())
        assertTrue(pairing.exists())
        assertEquals(emptyList<String>(), newIdentityCalls)
        sealed.writeBytes(bytes.also { it[0] = 1 })
        assertArrayEquals(key, store().secretKey())
    }

    @Test
    fun a_transient_failure_that_clears_within_the_retries_returns_the_same_identity() {
        val key = store().secretKey()
        wrapper.failOpen = OneShot { KeyStoreException("busy once") }::fire
        assertArrayEquals(key, store().secretKey())
        assertEquals(listOf(300L), sleeps)
    }

    // ── 生成新身份时出错 ────────────────────────────────────────

    @Test
    fun a_failure_while_minting_leaves_no_sealed_file_and_the_next_start_mints() {
        wrapper.failSeal = { ProviderException("seal failed") }
        assertUnavailable { store().secretKey() }
        assertFalse(sealed.exists())
        assertFalse(legacy.exists())
        wrapper.failSeal = null
        assertEquals(32, store().secretKey().size)
    }

    @Test
    fun a_seal_that_does_not_read_back_is_not_kept() {
        wrapper.corruptOpen = true
        assertUnavailable { store().secretKey() }
        assertFalse("读不回来的密文不许留着", sealed.exists())
        wrapper.corruptOpen = false
        val key = store().secretKey()
        assertArrayEquals(key, store().secretKey())
    }

    @Test
    fun every_crash_point_of_the_upgrade_converges() {
        // 清配对之后、写密文之前崩溃：盘上只剩旧明文（或连它也删了），下一次照常换新身份。
        legacy.writeBytes(ByteArray(32) { 3 })
        seedPairing()
        val crashing = store(beforeNewIdentity = { recordNewIdentity(); throw IllegalStateException("crash") })
        assertUnavailable { crashing.secretKey() }
        assertFalse(pairing.exists())
        val key = store().secretKey()
        assertFalse(legacy.exists())
        assertArrayEquals(key, store().secretKey())
    }

    // ── 用户重置 ───────────────────────────────────────────────

    @Test
    fun reset_mints_a_new_identity_and_clears_pairing() {
        val old = store().secretKey()
        wrapper.failOpen = { KeyStoreException("stuck") }
        val s = store()
        assertUnavailable { s.secretKey() }
        seedPairing()
        newIdentityCalls.clear()
        wrapper.failOpen = null
        s.reset()
        val key = s.secretKey()
        assertFalse(key.contentEquals(old))
        assertFalse(pairing.exists())
        assertEquals(1, newIdentityCalls.size)
        assertArrayEquals(key, store().secretKey())
    }

    @Test
    fun reset_that_fails_reports_unavailable() {
        store().secretKey()
        wrapper.failRecreate = { ProviderException("keymint dead") }
        assertUnavailable { store().reset() }
    }

    // ── 并发首次启动 ───────────────────────────────────────────

    @Test
    fun concurrent_first_use_mints_exactly_once() {
        val s = store()
        val pool = Executors.newFixedThreadPool(8)
        val go = CountDownLatch(1)
        val results = (1..8).map { pool.submit<ByteArray> { go.await(); s.secretKey() } }
        go.countDown()
        val keys = results.map { it.get(10, TimeUnit.SECONDS) }
        pool.shutdown()
        keys.forEach { assertArrayEquals(keys.first(), it) }
        assertEquals(1, wrapper.recreated)
        assertEquals(1, newIdentityCalls.size)
        assertArrayEquals(keys.first(), store().secretKey())
    }

    private class OneShot(private val make: () -> Exception) {
        private var fired = false
        fun fire(): Exception? = if (fired) null else make().also { fired = true }
    }

    private fun ByteArray.containsRun(needle: ByteArray): Boolean =
        (0..size - needle.size).any { i -> needle.indices.all { this[i + it] == needle[it] } }
}
