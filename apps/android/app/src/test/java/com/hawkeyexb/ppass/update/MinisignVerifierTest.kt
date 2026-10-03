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

    // ── UPD-11 (#641)：生产形状 = base64(整个 `.minisig` 文本盒) ──────────
    // 线上 manifest 的 `signature` 字段就是这一形状（与桌面端 tauri updater 消费的同一个
    // 字段、同一种形状）。旧实现把它当裸 74 字节结构解 ⇒ 每次更新必然「校验未通过」。

    /** 线上 v0.8.2 `manifest.json` → `platforms["android-arm64"].signature` 的**原文**。 */
    private val productionSignatureBox =
        "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVUSXZHU2ZZRGNkSlFaUUFpQ05TcGVuamtTSS8ybV" +
            "g0eDhwQlpBeTNmcElBRU91eHRMNHptOHZSZjd5WEtBUzZzb3VCNlJOcGtjYzlBY3RuVmFFM1NYei93SWxIZmdCNXdjPQp0cnVzdGVkIGN" +
            "vbW1lbnQ6IHRpbWVzdGFtcDoxNzkxMDM3OTU1CWZpbGU6YXBwLXJlbGVhc2UuYXBrCjVsT0d4QU1VYkU2TnVVU1RXU1F3aUJvKzRGVkNX" +
            "aGJCY01KeUc1Wm05a1huTjdadm9PRmd2cTZ0RFZTVWpFY0F5a290SHcvR3FGeERyelpTWTVQaUJBPT0K"

    /** 这一形状就是生产字段的样子：文本盒，四行。 */
    private fun textBox(sigBareB64: String): String =
        "untrusted comment: signature from tauri secret key\n" +
            "$sigBareB64\n" +
            "trusted comment: timestamp:1791037955\tfile:app-release.apk\n" +
            Base64.getEncoder().encodeToString(ByteArray(64)) + "\n"

    @Test
    fun productionSignatureBoxIsParsed() {
        // 反证锚：旧实现就是死在这一步——整盒解码是 300 字节文本，不是 74 字节结构。
        assertEquals(300, Base64.getDecoder().decode(productionSignatureBox).size)
        val blob = MinisignVerifier.decodeBlob(productionSignatureBox, 2 + 8 + 64)
        assertTrue("生产签名字段必须能解出 74 字节结构", blob != null)
        val parsed = MinisignVerifier.parseSig(blob!!)!!
        assertEquals("ED", parsed.algorithm)
        assertEquals("c8bc649f60371d25", parsed.keynum.joinToString("") { "%02x".format(it) })
    }

    @Test
    fun signatureBoxVerifiesEndToEnd() {
        // 把组 1 的签名包成生产形状的文本框：端到端必须 Valid。
        val boxed = Base64.getEncoder().encodeToString(textBox(sig1).toByteArray())
        assertEquals(MinisignVerifier.Result.Valid, MinisignVerifier.verify(writeApk(), boxed, pub1))
    }

    @Test
    fun tamperedSignatureBoxMustBeInvalid() {
        // 反证：只动签名**本体**（keynum 之后的第 20 字节），keynum 不变 ⇒ 必须 Invalid。
        val bare = Base64.getDecoder().decode(sig1)
        val tampered = bare.copyOf().apply { this[20] = (this[20] + 1).toByte() }
        val boxed = Base64.getEncoder()
            .encodeToString(textBox(Base64.getEncoder().encodeToString(tampered)).toByteArray())
        assertEquals(MinisignVerifier.Result.Invalid, MinisignVerifier.verify(writeApk(), boxed, pub1))
    }

    @Test
    fun boxedSignatureFromAnotherKeynumIsUnknownSigner() {
        // 盒子形状下也要保留「签名者身份对不上」与「签名无效」的区分：改 keynum ⇒ UnknownSigner。
        val boxed = Base64.getEncoder()
            .encodeToString(textBox(sig2).toByteArray())
        assertEquals(MinisignVerifier.Result.UnknownSigner, MinisignVerifier.verify(writeApk(), boxed, pub1))
    }

    @Test
    fun boxWithoutSignatureBlobIsMalformed() {
        val boxed = Base64.getEncoder().encodeToString("untrusted comment: tauri\n".toByteArray())
        assertEquals(
            MinisignVerifier.Result.MalformedSignature,
            MinisignVerifier.verify(writeApk(), boxed, pub1),
        )
    }
}
