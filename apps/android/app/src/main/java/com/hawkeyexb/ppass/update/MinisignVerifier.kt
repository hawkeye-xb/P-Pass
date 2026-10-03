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
        val pub = parseKey(Base64.getDecoder().decode(publicKeyB64))
        val sig = parseSig(Base64.getDecoder().decode(signatureBase64.trim()))
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
