package com.hawkeyexb.ppass.update

import java.io.File
import java.security.MessageDigest

/**
 * Integrity gate between download and install. An APK that fails verification
 * is never handed to the installer.
 */
object ApkVerifier {

    sealed interface Result {
        data object Ok : Result
        /** Manifest declared a sha256 that does not match the downloaded bytes. */
        data class Sha256Mismatch(val expected: String, val actual: String) : Result
        /** Manifest carries no minisign signature; installing is refused. */
        data object NoSignature : Result
        data class SignatureInvalid(val reason: MinisignVerifier.Result) : Result
        data class Error(val cause: Throwable) : Result
    }

    fun sha256Hex(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * @param sha256HexExpected manifest `sha256`; blank = field absent (transitional
     *   tolerance for manifests produced by older tooling, minisign still applies).
     * @param signatureB64 manifest `signature` (minisign). Blank = hard failure.
     */
    fun verifyDownloadedApk(file: File, sha256HexExpected: String, signatureB64: String): Result =
        verifyDownloadedApk(file, sha256HexExpected, signatureB64, MinisignVerifier::verify)

    /** 测试可注入验签器（JVM 测试用独立测试密钥对，不动生产常量）。 */
    internal fun verifyDownloadedApk(
        file: File,
        sha256HexExpected: String,
        signatureB64: String,
        verifySignature: (File, String) -> MinisignVerifier.Result,
    ): Result {
        if (!file.isFile || file.length() == 0L) {
            return Result.Error(IllegalStateException("downloaded apk missing or empty"))
        }
        if (sha256HexExpected.isNotBlank()) {
            val actual = sha256Hex(file)
            if (!actual.equals(sha256HexExpected.trim(), ignoreCase = true)) {
                return Result.Sha256Mismatch(expected = sha256HexExpected.trim(), actual = actual)
            }
        }
        if (signatureB64.isBlank()) {
            return Result.NoSignature
        }
        return when (val sig = verifySignature(file, signatureB64)) {
            MinisignVerifier.Result.Valid -> Result.Ok
            is MinisignVerifier.Result.Error -> Result.Error(sig.cause)
            else -> Result.SignatureInvalid(sig)
        }
    }
}
