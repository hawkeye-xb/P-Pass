// UPD-02: 下载 → 安装之间完整性闸门的全路径锁。
// sha256 管「传输完整」（字节没坏），minisign 管「真实来源」（是我们的签名）；
// 两道都过才 Ok，任何一道不过都绝不进安装器。
// 验签器经 internal 重载注入（测试密钥对，不碰生产公钥）。
package com.hawkeyexb.ppass.update

import java.io.File
import java.util.Base64
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ApkVerifierTest {

    private val dir = File(System.getProperty("java.io.tmpdir"), "apkverify-test-${System.nanoTime()}")
        .apply { mkdirs() }

    @After
    fun cleanup() {
        dir.deleteRecursively()
    }

    private val apkBytes: ByteArray = Base64.getDecoder().decode(
        "UC1QYXNzIGZha2UgYXBrIGJ5dGVzIGZvciB1cGRhdGUtc2lnbmF0dXJlIHRlc3QgdmVjdG9y" +
            "ClAtUGFzcyBmYWtlIGFwayBieXRlcyBmb3IgdXBkYXRlLXNpZ25hdHVyZSB0ZXN0IHZlY3Rv" +
            "cgpQLVBhc3MgZmFrZSBhcGsgYnl0ZXMgZm9yIHVwZGF0ZS1zaWduYXR1cmUgdGVzdCB2ZWN0" +
            "b3IKUC1QYXNzIGZha2UgYXBrIGJ5dGVzIGZvciB1cGRhdGUtc2lnbmF0dXJlIHRlc3QgdmVj" +
            "dG9yClAtUGFzcyBmYWtlIGFwayBieXRlcyBmb3IgdXBkYXRlLXNpZ25hdHVyZSB0ZXN0IHZl" +
            "Y3RvcgpQLVBhc3MgZmFrZSBhcGsgYnl0ZXMgZm9yIHVwZGF0ZS1zaWduYXR1cmUgdGVzdCB2" +
            "ZWN0b3IKUC1QYXNzIGZha2UgYXBrIGJ5dGVzIGZvciB1cGRhdGUtc2lnbmF0dXJlIHRlc3Qg" +
            "dmVjdG9yCg=="
    )

    /** APK_BYTES 的 sha256（与 ApkVerifier.sha256Hex 同一算法，独立算得）。 */
    private val apkSha256 = "bfa60e04df30709df98f16111c766c6ef1e0db9810196d344a67cc8b50b2338f"

    // 测试密钥对（同 MinisignVerifierTest 组 1：预哈希签名）。
    private val testPub = "RWQlHTdgn2S8yLJAYosflvG6BItGKzFlzXKBUvZojq6+qcyn0m1b3j2L"
    private val testSig =
        "RUQlHTdgn2S8yK+nKv3AHb73rZspfi31XAmOGYIazD5cxmEDABrCyTees74DlHzz" +
            "1cNUSWcJt8sj2NCSWpg13GGBmrxcw7dG/gE="

    private fun writeApk(bytes: ByteArray = apkBytes): File =
        File(dir, "ppass-update.apk").apply { writeBytes(bytes) }

    private fun verify(file: File, sha256: String, signature: String): ApkVerifier.Result =
        ApkVerifier.verifyDownloadedApk(file, sha256, signature) { f, s ->
            MinisignVerifier.verify(f, s, testPub)
        }

    @Test
    fun sha256HexMatchesIndependentDigest() {
        assertEquals(apkSha256, ApkVerifier.sha256Hex(writeApk()))
    }

    @Test
    fun bothGatesPassIsOk() {
        assertEquals(ApkVerifier.Result.Ok, verify(writeApk(), apkSha256, testSig))
    }

    @Test
    fun shaMismatchIsCaughtBeforeSignature() {
        val r = verify(writeApk(), "0".repeat(64), testSig)
        assertTrue("$r", r is ApkVerifier.Result.Sha256Mismatch)
        assertEquals(apkSha256, (r as ApkVerifier.Result.Sha256Mismatch).actual)
    }

    @Test
    fun blankShaSkipsTransportGateButSignatureStillApplies() {
        // 旧工具产出的 manifest 没有 sha256 字段：传输门豁免，真实性门不豁免。
        assertEquals(ApkVerifier.Result.Ok, verify(writeApk(), "", testSig))
    }

    @Test
    fun blankSignatureIsHardFailure() {
        assertEquals(ApkVerifier.Result.NoSignature, verify(writeApk(), apkSha256, ""))
        assertEquals(ApkVerifier.Result.NoSignature, verify(writeApk(), "", "   "))
    }

    @Test
    fun tamperedBytesWithValidShaFieldFailAtSha() {
        // 篡改后的文件 + manifest 里原 sha256：传输门先拦。
        val tampered = apkBytes.copyOf().apply { this[0] = (this[0] + 1).toByte() }
        assertTrue(verify(writeApk(tampered), apkSha256, testSig) is ApkVerifier.Result.Sha256Mismatch)
    }

    @Test
    fun tamperedBytesWithoutShaFieldFailAtSignature() {
        // 没有 sha256 字段时，minisign 是唯一的门——必须拦得住（反证）。
        val tampered = apkBytes.copyOf().apply { this[0] = (this[0] + 1).toByte() }
        val r = verify(writeApk(tampered), "", testSig)
        assertTrue("$r", r is ApkVerifier.Result.SignatureInvalid)
        assertEquals(
            MinisignVerifier.Result.Invalid,
            (r as ApkVerifier.Result.SignatureInvalid).reason,
        )
    }

    @Test
    fun missingOrEmptyFileIsError() {
        assertTrue(verify(File(dir, "nope.apk"), apkSha256, testSig) is ApkVerifier.Result.Error)
        assertTrue(verify(writeApk(ByteArray(0)), apkSha256, testSig) is ApkVerifier.Result.Error)
    }
}
