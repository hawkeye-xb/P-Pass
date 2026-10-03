// UPD-02: minisign 验签的端到端锁——真实密钥对 + 真实签名向量（生成脚本
// 用 PyNaCl/libsodium，与 minisign/rsign2 同一密码学底座）。
//
// 向量形状与生产完全一致：公钥恒 "Ed"，签名默认 "ED"（预哈希）——
// rsign2/tauri signer 产出的正是这个组合（见 MinisignVerifier 类注释）。
// 另有一组 legacy "Ed"（对原始字节直签）向量覆盖第二条分支。
//
// 反证红线（tamper-must-fail）：被改一个字节的 APK 必须验出 Invalid，
// 绝不许 Valid——这是整条验签链存在的意义。
package com.hawkeyexb.ppass.update

import java.io.File
import java.util.Base64
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MinisignVerifierTest {

    private val dir = File(System.getProperty("java.io.tmpdir"), "minisign-test-${System.nanoTime()}")
        .apply { mkdirs() }

    @After
    fun cleanup() {
        dir.deleteRecursively()
    }

    // ── 向量（与 MinisignVerifier 内嵌生产公钥相互独立） ──

    /** 假 APK 字节（385B），两组向量共用同一份「文件」。 */
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

    /** 组 1（生产形状）：公钥 "Ed" + 签名 "ED"（BLAKE2b-512 预哈希后 plain Ed25519）。 */
    private val pub1 = "RWQlHTdgn2S8yLJAYosflvG6BItGKzFlzXKBUvZojq6+qcyn0m1b3j2L"
    private val sig1 =
        "RUQlHTdgn2S8yK+nKv3AHb73rZspfi31XAmOGYIazD5cxmEDABrCyTees74DlHzz" +
            "1cNUSWcJt8sj2NCSWpg13GGBmrxcw7dG/gE="

    /** 组 2（legacy 分支）：签名 "Ed"（对原始字节直签）。 */
    private val pub2 = "RWQBAgMEBQYHCNBKsjJ0K7SrOhNovUYV5ObQIkq3GgFrr4UgozLJd4c3"
    private val sig2 =
        "RWQBAgMEBQYHCLOrh/pKYSEyc2aBgQeA2nyCN3r0ItyoIr62ZgF6A/ti0xbdSmo2" +
            "0omksq49Da1jGe2ElVQ8yGXwNocmjSxrFAM="

    /** 生产公钥（tauri.conf.json 同款）——keynum 与组 1 不同，用于 UnknownSigner。 */
    private val prodPub = "RWTIvGSfYDcdJRoFUZpc2fMvV0lKHio6B8UXCKhN8DJ4vzCe4495zPrp"

    private fun writeApk(bytes: ByteArray = apkBytes): File =
        File(dir, "app-release.apk").apply { writeBytes(bytes) }

    @Test
    fun prehashedSignatureVerifies() {
        assertEquals(
            MinisignVerifier.Result.Valid,
            MinisignVerifier.verify(writeApk(), sig1, pub1),
        )
    }

    @Test
    fun legacyPlainSignatureVerifies() {
        assertEquals(
            MinisignVerifier.Result.Valid,
            MinisignVerifier.verify(writeApk(), sig2, pub2),
        )
    }

    @Test
    fun tamperedApkMustFail() {
        // 反证：APK 被改 1 字节，验签必须 Invalid（不是 Valid、不是 Error）。
        val tampered = apkBytes.copyOf().apply { this[0] = (this[0] + 1).toByte() }
        assertEquals(
            MinisignVerifier.Result.Invalid,
            MinisignVerifier.verify(writeApk(tampered), sig1, pub1),
        )
    }

    @Test
    fun tamperedApkMustFailLegacyBranch() {
        val tampered = apkBytes.copyOf().apply { this[100] = (this[100] + 1).toByte() }
        assertEquals(
            MinisignVerifier.Result.Invalid,
            MinisignVerifier.verify(writeApk(tampered), sig2, pub2),
        )
    }

    @Test
    fun signatureFromAnotherKeyIsInvalid() {
        // 组 2 的签名配组 1 的公钥：keynum 不同 → UnknownSigner 先于密码学。
        assertEquals(
            MinisignVerifier.Result.UnknownSigner,
            MinisignVerifier.verify(writeApk(), sig2, pub1),
        )
    }

    @Test
    fun productionKeynumMismatchIsUnknownSigner() {
        // 生产公钥的 keynum 与测试签名不同——签名者身份对不上必须如实区分，
        // 不能混进「签名无效」（换钥/串包是两种事故）。
        assertEquals(
            MinisignVerifier.Result.UnknownSigner,
            MinisignVerifier.verify(writeApk(), sig1, prodPub),
        )
    }

    @Test
    fun malformedInputsAreMalformedNotCrash() {
        assertEquals(
            MinisignVerifier.Result.MalformedSignature,
            MinisignVerifier.verify(writeApk(), "not-base64!!!", pub1),
        )
        // 合法 base64 但 blob 长度不对。
        assertEquals(
            MinisignVerifier.Result.MalformedSignature,
            MinisignVerifier.verify(writeApk(), Base64.getEncoder().encodeToString(ByteArray(10)), pub1),
        )
    }

    @Test
    fun missingFileIsError() {
        val r = MinisignVerifier.verify(File(dir, "nope.apk"), sig1, pub1)
        assertTrue("$r", r is MinisignVerifier.Result.Error)
    }
}
