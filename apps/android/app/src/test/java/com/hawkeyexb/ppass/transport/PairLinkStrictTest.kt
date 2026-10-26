// #1149：配对串只有一个解析器——Rust 核心的 `parse_pair_link`（经 uniffi 绑定，与 iOS 共用）。
// 畸形串（长度不对、非 hex、relay 非 https、relay 含引号或反斜杠……）一律是
// 「不是 P-Pass 配对码」，pairWithQr 在拨号、写任何本地数据之前就返回。
//
// 真解析器的两条需要宿主机版 libtransport（`cargo build -p transport --features mobile-ffi`）；CI 的 Android
// 单测不构建它，那两条在库缺失时跳过（Rust 侧 `pair_link` 单测覆盖同一批畸形串）。
// 与原生库无关的「解析失败即返回、不拨号」由注入解析器的那一条在任何环境下钉住。
//
// 反证：pairWithQr 改回手写解析（或解析失败后继续往下走）⇒ 「畸形串」一条变红，
// 因为未绑定的 DaemonClient 一被调用就抛异常，且返回值不再是 invalidCodeMessage。
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.ffi.parsePairLink
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class PairLinkStrictTest {
    // Ed25519 基点的压缩编码：一个真实的公钥（NodeId 解析会检查曲线点）。
    private val node = "58" + "66".repeat(31)
    private val token = "9fc4f658f6ce2c0300000000"
    private val relay = "https://relay.example.com:8443"
    private val invalid = "NOT-A-P-PASS-CODE"

    private fun nativeAvailable(): Boolean =
        try {
            parsePairLink("x")
            true
        } catch (e: com.hawkeyexb.ppass.ffi.FfiException) {
            true // 库在，解析器按预期拒绝了
        } catch (e: Throwable) {
            false // UnsatisfiedLinkError / ExceptionInInitializerError：没有宿主机版 libtransport
        }

    private fun outcomeOf(qr: String, parseLink: ((String) -> com.hawkeyexb.ppass.ffi.ParsedPairLink)? = null): PairOutcome = runBlocking {
        pairWithQr(
            client = DaemonClient(), // 未绑定：任何一次调用都会抛
            qr = qr,
            deviceName = "test",
            onCode = { _, _, _ -> error("must not reach the code step") },
            invalidCodeMessage = invalid,
            parseLink = parseLink ?: ::parsePairLink,
        )
    }

    @Test
    fun `a link the parser rejects ends the flow before any dial`() {
        val outcome = outcomeOf("ppf://pair?whatever", parseLink = { throw IllegalArgumentException("malformed") })
        assertTrue(outcome is PairOutcome.Failed)
        assertEquals(invalid, (outcome as PairOutcome.Failed).reason)
    }

    @Test
    fun `a well-formed link parses to node, token and a dialable relay token`() {
        assumeTrue("host libtransport not built", nativeAvailable())
        val p = parsePairLink("ppf://pair?node=$node&t=$token&r=$relay")
        assertEquals(node, p.nodeId)
        assertEquals(token, p.token)
        val addr = parsePeerAddrToken(p.peerToken)
        assertEquals(node, addr.idHex)
        assertTrue(addr.relayUrl!!.startsWith("https://relay.example.com:8443"))
    }

    @Test
    fun `malformed links are not P-Pass pairing codes`() {
        assumeTrue("host libtransport not built", nativeAvailable())
        val bad = listOf(
            "",
            "https://example.com",
            "ppf://pair?node=${node.dropLast(2)}&t=$token&r=$relay", // node 太短
            "ppf://pair?node=${node}00&t=$token&r=$relay", // node 太长
            "ppf://pair?node=${"zz".repeat(32)}&t=$token&r=$relay", // 非 hex
            "ppf://pair?node=$node&t=${token.dropLast(1)}&r=$relay", // token 太短
            "ppf://pair?node=$node&t=${token}0&r=$relay", // token 太长
            "ppf://pair?node=$node&t=${"zz".repeat(12)}&r=$relay", // token 非 hex
            "ppf://pair?node=$node&t=$token&r=http://relay.example.com", // 非 https
            "ppf://pair?node=$node&t=$token&r=relay.example.com", // 无协议
            "ppf://pair?node=$node&t=$token&r=https://re\"lay.example.com", // 引号
            "ppf://pair?node=$node&t=$token&r=https://re\\lay.example.com", // 反斜杠
            "ppf://pair?node=$node&t=$token&r=https://x.com\",\"evil\":\"1", // JSON 注入尝试
            "ppf://pair?node=$node&t=$token&r=https://user@relay.example.com", // userinfo
        )
        for (qr in bad) {
            val outcome = outcomeOf(qr)
            assertTrue("$qr should fail, got $outcome", outcome is PairOutcome.Failed)
            assertEquals(qr, invalid, (outcome as PairOutcome.Failed).reason)
        }
    }
}
