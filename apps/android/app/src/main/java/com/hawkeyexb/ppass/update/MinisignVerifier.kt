package com.hawkeyexb.ppass.update

import com.hawkeyexb.ppass.BuildConfig
import java.io.File
import java.io.FileInputStream
import java.util.Base64
import org.bouncycastle.crypto.digests.Blake2bDigest
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer

/**
 * Verifies a downloaded APK against a minisign detached signature.
 *
 * Minisign blob layout (both public key and signature):
 *   algorithm(2 bytes, "Ed" or "ED") || keynum(8 bytes) || payload(32 pk or 64 sig)
 *
 * The algorithm tag is a property of the SIGNATURE, not of the key: minisign
 * public keys always carry "Ed", while the signatures they verify normally
 * carry "ED" (rsign2/tauri signer emit prehashed; `minisign -l` legacy emits
 * "Ed"). Verification therefore dispatches on the signature's tag alone:
 *
 * - sig "Ed": plain Ed25519 over the raw file bytes (legacy algorithm).
 * - sig "ED": the file is first hashed with BLAKE2b-512 and the digest is
 *   signed with *plain* Ed25519 (minisign/rsign2 behavior — "ED" is NOT
 *   RFC 8032 Ed25519ph, so BouncyCastle's plain [Ed25519Signer] is the right one).
 *
 * #1151: crypto comes from BouncyCastle (maintained) — Ed25519 verify + Blake2bDigest.
 *
 * #1121: the keys are not hand-copied any more. Gradle reads them from the single
 * source at build time (BuildConfig.UPDATE_PUBKEY_*): stable = desktop
 * `tauri.conf.json` updater pubkey, test = `release/update-keys/test.pub`.
 * A build only ever verifies with the key of its own channel.
 */
object MinisignVerifier {

    private const val ALG_PLAIN = "Ed"
    private const val ALG_PREHASHED = "ED"

    sealed interface Result {
        data object Valid : Result
        /** Blob could not be decoded / has unexpected shape. */
        data object MalformedSignature : Result
        /** Signature keynum does not match the embedded public key. */
        data object UnknownSigner : Result
        /** Well-formed but does not verify. */
        data object Invalid : Result
        /** Local failure while reading the file or running crypto. */
        data class Error(val cause: Throwable) : Result
        /** #1121: this build carries no public key for its channel; every update is refused. */
        data object NoKeyForChannel : Result
    }

    internal data class ParsedKey(val algorithm: String, val keynum: ByteArray, val key: ByteArray)
    internal data class ParsedSig(val algorithm: String, val keynum: ByteArray, val sig: ByteArray)

    /** #1121: the public key of [channel] as built into this APK (tauri text-box form); blank = none. */
    fun publicKeyFor(channel: UpdateChannel): String = when (channel) {
        UpdateChannel.Stable -> BuildConfig.UPDATE_PUBKEY_STABLE
        UpdateChannel.Test -> BuildConfig.UPDATE_PUBKEY_TEST
    }

    /** Verify with the key of the channel this build belongs to (derived from its version). */
    fun verify(file: File, signatureBase64: String): Result =
        verifyForChannel(file, signatureBase64, channelFromVersion(BuildConfig.VERSION_NAME), ::publicKeyFor)

    internal fun verifyForChannel(
        file: File,
        signatureBase64: String,
        channel: UpdateChannel,
        keyOf: (UpdateChannel) -> String,
    ): Result {
        val key = keyOf(channel)
        if (key.isBlank()) return Result.NoKeyForChannel
        return verify(file, signatureBase64, key)
    }

    /** 测试可注入公钥（JVM 测试用独立测试密钥对，不动生产常量）。 */
    internal fun verify(file: File, signatureBase64: String, publicKeyB64: String): Result = try {
        val pub = decodeBlob(publicKeyB64, 2 + 8 + 32)?.let(::parseKey)
        val sig = decodeBlob(signatureBase64, 2 + 8 + 64)?.let(::parseSig)
        when {
            pub == null || sig == null -> Result.MalformedSignature
            !sig.keynum.contentEquals(pub.keynum) -> Result.UnknownSigner
            verifyParsed(file, pub, sig) -> Result.Valid
            else -> Result.Invalid
        }
    } catch (e: IllegalArgumentException) {
        Result.MalformedSignature // bad base64
    } catch (e: Exception) {
        Result.Error(e)
    }

    /**
     * UPD-11 (#641)：manifest 的 `signature` 字段装的是 **base64(整个 `.minisig` 文本盒)**，
     * 不是裸结构 —— 与桌面端 tauri updater 消费的是同一个字段、同一种形状，也与
     * `tauri.conf.json` 的 pubkey（base64(.pub 文本盒)）同构。旧实现直接把字段当裸
     * 结构解，`blob.size != 74` 一律 null ⇒ **每次更新都必然「校验未通过」**。
     *
     * 这里两种形状都收：先按裸结构试（老向量/未来格式），尺寸不对再按文本盒逐行找
     * 内层 base64。`expectedSize` 由调用方给定，避免「认出一个不是我们要的东西」。
     */
    internal fun decodeBlob(field: String, expectedSize: Int): ByteArray? {
        val decoded = try {
            Base64.getDecoder().decode(field.trim())
        } catch (_: IllegalArgumentException) {
            return null
        }
        if (decoded.size == expectedSize) return decoded
        // 文本盒：`untrusted comment: …` / <base64 blob> / [`trusted comment: …` / <base64 global sig>]
        for (line in decoded.toString(Charsets.UTF_8).lineSequence()) {
            val t = line.trim()
            if (t.isEmpty() || t.startsWith("untrusted comment") || t.startsWith("trusted comment")) continue
            val inner = try {
                Base64.getDecoder().decode(t)
            } catch (_: IllegalArgumentException) {
                continue
            }
            if (inner.size == expectedSize) return inner
        }
        return null
    }

    internal fun parseKey(blob: ByteArray): ParsedKey? {
        if (blob.size != 2 + 8 + 32) return null
        return ParsedKey(String(blob, 0, 2), blob.copyOfRange(2, 10), blob.copyOfRange(10, 42))
    }

    internal fun parseSig(blob: ByteArray): ParsedSig? {
        if (blob.size != 2 + 8 + 64) return null
        return ParsedSig(String(blob, 0, 2), blob.copyOfRange(2, 10), blob.copyOfRange(10, 74))
    }

    private fun verifyParsed(file: File, pub: ParsedKey, sig: ParsedSig): Boolean {
        // 分发只看签名的算法标签（公钥恒为 "Ed"，见类注释）——生产组合就是
        // 公钥 "Ed" + 签名 "ED"，要求两者相等会把每个真实签名拒之门外。
        val message = when (sig.algorithm) {
            ALG_PLAIN -> file.readBytes()
            ALG_PREHASHED -> blake2b512(file)
            else -> return false // unknown signature algorithm tag
        }
        return try {
            Ed25519Signer().run {
                init(false, Ed25519PublicKeyParameters(pub.key, 0))
                update(message, 0, message.size)
                verifySignature(sig.sig)
            }
        } catch (_: Exception) {
            false
        }
    }

    /** BLAKE2b-512 of the file, streamed (the APK can be tens of MB). */
    private fun blake2b512(file: File): ByteArray {
        val digest = Blake2bDigest(512)
        val buf = ByteArray(64 * 1024)
        FileInputStream(file).use { input ->
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                digest.update(buf, 0, n)
            }
        }
        return ByteArray(digest.digestSize).also { digest.doFinal(it, 0) }
    }
}
