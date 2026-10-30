// Device identity + pairing state, persisted in the app's sandboxed
// files dir. The 32-byte secret IS the device: pairing authorization
// binds to the NodeId derived from it.
//
// #1106: the secret is never on disk in the clear. It is sealed with a
// non-exportable AES-256-GCM key in Android Keystore ([IdentityKeyWrapper])
// and unsealed into memory once per process; a copied file is useless off
// this phone. iroh needs the raw secret in memory, so this is
// "Keystore-wrapped storage", not Keystore-held signing.
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.io.atomicReplace
import java.io.File
import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** One sealed blob: the IV Keystore chose (randomized encryption) + GCM ciphertext-with-tag. */
class SealedSecret(val iv: ByteArray, val ciphertext: ByteArray)

/** The Keystore half of [IdentityStore]; production is [AndroidKeystoreIdentityWrapper]. */
interface IdentityKeyWrapper {
    /** Whether the wrapping key exists. A Keystore failure throws — it is never reported as `false`. */
    fun exists(): Boolean

    /** Drop the wrapping key if present and generate a fresh one. */
    fun recreate()

    fun seal(plain: ByteArray): SealedSecret

    /** Throws [IdentityKeyGoneException] when the key is missing or permanently invalidated. */
    fun open(sealed: SealedSecret): ByteArray

    /**
     * #1152 (MASWE-0042 family): where the wrapping key lives — `strongbox`, `tee`, `software`, … — for the
     * diagnostics log line only. Never throws and never changes behaviour; unknown when the platform can't say.
     */
    fun securityLevel(): String = "unknown"
}

/** Definitive: the wrapping key is not there (or Keystore says it is permanently invalid). */
class IdentityKeyGoneException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Keystore failed in a way that is not a definitive loss, after retrying. Nothing was cleared: the
 * sealed identity and the pairing are untouched, and there is no plaintext fallback.
 */
class IdentityUnavailableException(cause: Throwable) : Exception("device identity unavailable", cause)

/**
 * The device identity, one instance per process (owned by `PPassApplication`).
 *
 * #1106 states (decided 2026-10-22; no migration — an old plaintext `identity.key` is never read,
 * only destroyed as a retired key, same as iOS `DeviceIdentity`):
 * - old plaintext present → a new device (even next to a sealed file: that is a crash leftover
 *   from the previous attempt, and the plaintext's presence is what makes it converge).
 * - sealed file opens → that is the identity.
 * - definitive loss (wrapping key absent, GCM tag mismatch, key permanently invalidated, wrong
 *   length) or no sealed file at all (first run, a new phone)
 *   → a new device: [beforeNewIdentity] clears the pairing first,
 *   then a fresh secret is minted, sealed, written and read back.
 * - anything else → [IdentityUnavailableException] after retrying; nothing is touched.
 */
class IdentityStore(
    private val dir: File,
    private val wrapper: IdentityKeyWrapper,
    /** Runs before a new identity is persisted: the old pairing belongs to the old NodeId. */
    private val beforeNewIdentity: () -> Unit = {},
    private val log: (String) -> Unit = {},
    private val sleep: (Long) -> Unit = Thread::sleep,
    private val random: SecureRandom = SecureRandom(),
) {
    private val sealedFile = File(dir, SEALED_FILE)
    private val retiredPlaintext = File(dir, RETIRED_PLAINTEXT_FILE)
    private val lock = Any()

    @Volatile private var cached: ByteArray? = null

    /** True once this process holds the secret (no Keystore call needed). */
    val isReady: Boolean get() = cached != null

    /** The persistent secret; resolves (and on a new device, mints) it on first use. */
    fun secretKey(): ByteArray {
        cached?.let { return it.copyOf() }
        synchronized(lock) {
            cached?.let { return it.copyOf() }
            var last: Exception? = null
            for ((attempt, delay) in RETRY_DELAYS_MS.withIndex()) {
                if (delay > 0) sleep(delay)
                try {
                    return resolve().also {
                        cached = it
                        // #1152：只记录，不据此拒绝启动（不在安全硬件里怎么处理另行评估，口径见 #1106）。
                        log("identity: wrapping key security level=${runCatching { wrapper.securityLevel() }.getOrDefault("unknown")}")
                    }.copyOf()
                } catch (e: Exception) {
                    last = e
                    log("identity: attempt ${attempt + 1}/${RETRY_DELAYS_MS.size} failed: ${e.javaClass.simpleName}: ${e.message}")
                }
            }
            throw IdentityUnavailableException(checkNotNull(last))
        }
    }

    /**
     * User-initiated way out of [IdentityUnavailableException] ("重置并重新配对"): abandon the
     * identity, clear the pairing, mint a new one. One attempt; a failure throws
     * [IdentityUnavailableException] again.
     */
    fun reset() {
        synchronized(lock) {
            cached = null
            try {
                cached = mint("user reset")
            } catch (e: Exception) {
                log("identity: reset failed: ${e.javaClass.simpleName}: ${e.message}")
                throw IdentityUnavailableException(e)
            }
        }
    }

    private fun resolve(): ByteArray {
        if (retiredPlaintext.exists()) return mint("retired plaintext identity present")
        if (!sealedFile.isFile) {
            return mint("no identity yet")
        }
        val opened = try {
            open()
        } catch (lost: DefinitiveLoss) {
            return mint("identity lost: ${lost.message}")
        }
        return opened
    }

    /** The sealed identity, or [DefinitiveLoss]; any other failure propagates (transient). */
    private fun open(): ByteArray {
        val sealed = decode(sealedFile.readBytes())
        if (!wrapper.exists()) throw DefinitiveLoss("wrapping key absent")
        val plain = try {
            wrapper.open(sealed)
        } catch (e: AEADBadTagException) {
            throw DefinitiveLoss("tag mismatch")
        } catch (e: IdentityKeyGoneException) {
            throw DefinitiveLoss(e.message ?: "wrapping key gone")
        }
        if (plain.size != SECRET_BYTES) throw DefinitiveLoss("unsealed ${plain.size} bytes")
        return plain
    }

    private fun mint(reason: String): ByteArray {
        log("identity: minting a new identity ($reason)")
        // Order matters for crash recovery: pairing first (a new key must never meet the old
        // pairing — there is no install marker on Android, so a sealed file written before the
        // pairing is cleared would open fine next start and keep the stale pairing), then the new
        // sealed file and its read-back, and only last the retired plaintext. Any failure before
        // that leaves the plaintext in place, and its presence re-runs this same path next start.
        beforeNewIdentity()
        sealedFile.delete()
        wrapper.recreate()
        val secret = ByteArray(SECRET_BYTES).also(random::nextBytes)
        dir.mkdirs()
        // Write-then-rename so a crash never leaves a half-written file.
        val tmp = File(dir, "$SEALED_FILE.tmp")
        tmp.writeBytes(encode(wrapper.seal(secret)))
        check(atomicReplace(tmp, sealedFile)) { "cannot persist $SEALED_FILE" }
        // Read back through Keystore before anyone gets the key: a seal we cannot open is not saved.
        val back = try {
            open()
        } catch (e: DefinitiveLoss) {
            sealedFile.delete()
            error("sealed identity does not read back: ${e.message}")
        }
        if (!back.contentEquals(secret)) {
            sealedFile.delete()
            error("sealed identity reads back different bytes")
        }
        destroyRetiredPlaintext()
        return secret
    }

    /** Not migration: the old key is never read, only destroyed. A failed delete is retried next start. */
    private fun destroyRetiredPlaintext() {
        for (f in listOf(retiredPlaintext, File(dir, "$RETIRED_PLAINTEXT_FILE.tmp"))) {
            if (f.exists() && !f.delete()) log("identity: could not delete ${f.name}; retrying next start")
        }
    }

    private class DefinitiveLoss(message: String) : Exception(message)

    companion object {
        const val SEALED_FILE = "identity.sealed"
        const val RETIRED_PLAINTEXT_FILE = "identity.key"
        const val SECRET_BYTES = 32
        private const val FORMAT_V1: Byte = 1

        /** Before each attempt. Bounded: ~1.3 s worst case before the refusal screen. */
        internal val RETRY_DELAYS_MS = longArrayOf(0, 300, 1000)

        /** `[version=1][ivLen][iv][ciphertext+tag]`. */
        internal fun encode(s: SealedSecret): ByteArray {
            require(s.iv.size in 1..255) { "iv length ${s.iv.size}" }
            return byteArrayOf(FORMAT_V1, s.iv.size.toByte()) + s.iv + s.ciphertext
        }

        /**
         * An unknown version is NOT a definitive loss (a newer build wrote it; downgrade) — it
         * surfaces as unavailable, never as an automatic reset. A truncated v1 blob is.
         */
        private fun decode(bytes: ByteArray): SealedSecret {
            check(bytes.isNotEmpty() && bytes[0] == FORMAT_V1) { "unknown sealed identity format" }
            val ivLen = if (bytes.size > 1) bytes[1].toInt() and 0xff else 0
            if (ivLen == 0 || bytes.size <= 2 + ivLen) throw DefinitiveLoss("truncated sealed identity")
            return SealedSecret(bytes.copyOfRange(2, 2 + ivLen), bytes.copyOfRange(2 + ivLen, bytes.size))
        }
    }
}

@Serializable
data class Pairing(
    /** Storage daemon's NodeId (64 hex). */
    val daemonNodeId: String,
    /** Its last known PeerAddr token (redialable without discovery). */
    val daemonAddrToken: String,
    /** Human name shown in the UI („P-Pass 存储端“…). */
    val storageDeviceName: String,
    /** M11（全页面状态稿）"配对日期"用——本地时间戳，配对成功时打上；
     *  0 = 未知（老版本升级上来的存量 pairing，字段不存在，`ignoreUnknownKeys`
     *  兜底出默认值，不倒推瞎编一个日期）。 */
    val pairedAt: Long = 0L,
    /** Owner-approved pairing generation for Flow delivery. Empty means this
     * legacy pairing must be renewed before it can authorize a Flow item. */
    val pairingId: String = "",
)

class PairingStore(private val dir: File) {
    private val file = File(dir, "pairing.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun load(): Pairing? =
        if (file.isFile) runCatching {
            json.decodeFromString(Pairing.serializer(), file.readText())
        }.getOrNull()?.takeIf { it.pairingId.isNotBlank() } else null // #1117: 旧格式（只有 pairing_id）= 未配对

    fun save(p: Pairing) {
        dir.mkdirs()
        val tmp = File(dir, "pairing.json.tmp")
        tmp.writeText(json.encodeToString(Pairing.serializer(), p))
        check(atomicReplace(tmp, file)) { "cannot persist pairing.json" }
    }

    fun clear() {
        file.delete()
    }
}
