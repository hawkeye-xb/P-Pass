package com.hawkeyexb.ppass.update

import java.io.File
import java.security.Signature
import java.util.Base64
import net.i2p.crypto.eddsa.EdDSAPublicKey
import net.i2p.crypto.eddsa.EdDSASecurityProvider
import net.i2p.crypto.eddsa.spec.EdDSANamedCurveTable
import net.i2p.crypto.eddsa.spec.EdDSAPublicKeySpec

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
 *   RFC 8032 Ed25519ph; net.i2p eddsa 0.3.0 has no Ed25519ph anyway).
 *
 * The embedded key MUST stay in sync with `tauri.conf.json` (updater pubkey).
 */
object MinisignVerifier {

    /** Production public key (matches tauri.conf.json updater pubkey). */
    private const val PROD_PUBLIC_KEY_B64 =
        "RWTIvGSfYDcdJRoFUZpc2fMvV0lKHio6B8UXCKhN8DJ4vzCe4495zPrp"

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
    }

    internal data class ParsedKey(val algorithm: String, val keynum: ByteArray, val key: ByteArray)
    internal data class ParsedSig(val algorithm: String, val keynum: ByteArray, val sig: ByteArray)

    fun verify(file: File, signatureBase64: String): Result =
        verify(file, signatureBase64, PROD_PUBLIC_KEY_B64)

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
        val publicKey = EdDSAPublicKey(
            EdDSAPublicKeySpec(pub.key, EdDSANamedCurveTable.ED_25519_CURVE_SPEC)
        )
        // 分发只看签名的算法标签（公钥恒为 "Ed"，见类注释）——生产组合就是
        // 公钥 "Ed" + 签名 "ED"，要求两者相等会把每个真实签名拒之门外。
        return when (sig.algorithm) {
            ALG_PLAIN ->
                newSigner("NONEwithEdDSA").verifyWith(publicKey, sig.sig) {
                    it.update(file.readBytes())
                }

            ALG_PREHASHED -> {
                val digest = Blake2b(digestSize = 64).apply { update(file.readBytes()) }.digest()
                newSigner("NONEwithEdDSA").verifyWith(publicKey, sig.sig) { it.update(digest) }
            }

            else -> false // unknown signature algorithm tag
        }
    }

    private fun newSigner(algorithm: String): Signature =
        Signature.getInstance(algorithm, EdDSASecurityProvider())

    private fun Signature.verifyWith(
        publicKey: EdDSAPublicKey,
        signature: ByteArray,
        feed: (Signature) -> Unit,
    ): Boolean = try {
        initVerify(publicKey)
        feed(this)
        verify(signature)
    } catch (_: Exception) {
        false
    }
}
