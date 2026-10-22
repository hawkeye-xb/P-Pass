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
    private val pairing get() = File(dir, "pairing.json")
    private val retired get() = File(dir, IdentityStore.RETIRED_PLAINTEXT_FILE)

    @Before
    fun setUp() {
        dir = tmp.newFolder("files")
    }

    /** A fresh store = a fresh process (no in-memory cache), same files and same Keystore. */
    private fun store(beforeNewIdentity: () -> Unit = ::recordNewIdentity) =
        IdentityStore(dir, wrapper, beforeNewIdentity = beforeNewIdentity, sleep = { sleeps += it })

    private fun recordNewIdentity() {
        newIdentityCalls += "sealed=${sealed.exists()} pairing=${pairing.exists()}"
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
        assertFalse("密钥原文不许出现在盘上", sealed.readBytes().containsRun(key))
        assertEquals(listOf("sealed=false pairing=false"), newIdentityCalls)
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

    // ── 旧版明文：退役密钥，不读、只销毁 ──────────────────────

    @Test
    fun retired_plaintext_is_destroyed_after_the_new_identity_is_in_place() {
        val old = ByteArray(32) { 7 }
        retired.writeBytes(old)
        File(dir, "identity.key.tmp").writeBytes(old)
        seedPairing()
        val key = store().secretKey()
        assertFalse("不迁移：新身份不是旧明文", key.contentEquals(old))
        assertFalse(retired.exists())
        assertFalse(File(dir, "identity.key.tmp").exists())
        assertFalse("配对属于旧身份，必须清", pairing.exists())
        assertEquals(1, newIdentityCalls.size)
        assertArrayEquals(key, store().secretKey())
    }

    @Test
    fun retired_plaintext_next_to_a_sealed_identity_still_means_a_new_device() {
        // 上一次换新身份写完密文、删明文之前被杀：明文还在，就再走一遍同一条路。
        val first = store().secretKey()
        retired.writeBytes(ByteArray(32) { 1 })
        seedPairing()
        newIdentityCalls.clear()
        val key = store().secretKey()
        assertFalse(key.contentEquals(first))
        assertFalse(retired.exists())
        assertFalse(pairing.exists())
        assertEquals(1, newIdentityCalls.size)
    }

    private fun assertRetiredKeptWhen(inject: () -> Unit, beforeNewIdentity: () -> Unit = ::recordNewIdentity) {
        val old = ByteArray(32) { 5 }
        retired.writeBytes(old)
        inject()
        assertUnavailable { store(beforeNewIdentity).secretKey() }
        assertArrayEquals("删之前任何一步失败都不删", old, retired.readBytes())
    }

    @Test
    fun retired_plaintext_survives_a_failure_to_create_the_wrapping_key() =
        assertRetiredKeptWhen({ wrapper.failRecreate = { ProviderException("keymint dead") } })

    @Test
    fun retired_plaintext_survives_a_failure_to_seal() =
        assertRetiredKeptWhen({ wrapper.failSeal = { ProviderException("seal failed") } })

    @Test
    fun retired_plaintext_survives_a_failed_read_back() =
        assertRetiredKeptWhen({ wrapper.corruptOpen = true })

    @Test
    fun retired_plaintext_survives_a_failure_to_clear_the_pairing() =
        assertRetiredKeptWhen({}, beforeNewIdentity = { throw IllegalStateException("cannot clear pairing") })

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
        assertEquals("不回退明文：目录里只有密文和配对", setOf(IdentityStore.SEALED_FILE, "pairing.json"), dir.list()!!.toSet())
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
    fun a_crash_after_clearing_pairing_and_before_writing_converges() {
        // 已配对但没有密文（例如密钥库被清后新身份写到一半就崩）：清了配对、没写密文，下一次照常换新身份。
        seedPairing()
        val crashing = store(beforeNewIdentity = { recordNewIdentity(); throw IllegalStateException("crash") })
        assertUnavailable { crashing.secretKey() }
        assertFalse(pairing.exists())
        assertFalse(sealed.exists())
        val key = store().secretKey()
        assertArrayEquals(key, store().secretKey())
    }

    @Test
    fun pairing_is_cleared_before_the_new_sealed_file_is_written() {
        store().secretKey()
        sealed.delete()
        seedPairing()
        newIdentityCalls.clear()
        store().secretKey()
        assertEquals("清配对发生在新密文落盘之前", listOf("sealed=false pairing=true"), newIdentityCalls)
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
