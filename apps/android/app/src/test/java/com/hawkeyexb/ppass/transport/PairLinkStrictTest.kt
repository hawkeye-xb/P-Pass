// #1149：配对串只有一个解析器——Rust 核心的 `parse_pair_link`（经 uniffi 绑定，与 iOS 共用）。
// 畸形串（长度不对、非 hex、relay 非 https、relay 含引号或反斜杠……）一律是
// 「不是 P-Pass 配对码」，pairWithQr 在拨号、写任何本地数据之前就返回。
//
// 需要宿主机版 libtransport（`cargo build -p transport --features mobile-ffi`，同 C1124DesktopCloseTest）。
//
// 反证：pairWithQr 改回手写解析（或解析失败后继续往下走）⇒ 「畸形串」一条变红，
// 因为未绑定的 DaemonClient 一被调用就抛异常，且返回值不再是 invalidCodeMessage。
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.ffi.parsePairLink
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PairLinkStrictTest {
    // Ed25519 基点的压缩编码：一个真实的公钥（NodeId 解析会检查曲线点）。
    private val node = "58" + "66".repeat(31)
    private val token = "9fc4f658f6ce2c0300000000"
    private val relay = "https://relay.example.com:8443"
    private val invalid = "NOT-A-P-PASS-CODE"

    private fun outcomeOf(qr: String): PairOutcome = runBlocking {
        pairWithQr(
            client = DaemonClient(), // 未绑定：任何一次调用都会抛
            qr = qr,
            deviceName = "test",
            onCode = { _, _, _ -> error("must not reach the code step") },
            invalidCodeMessage = invalid,
        )
    }

    @Test
    fun `a well-formed link parses to node, token and a dialable relay token`() {
        val p = parsePairLink("ppf://pair?node=$node&t=$token&r=$relay")
        assertEquals(node, p.nodeId)
        assertEquals(token, p.token)
        val addr = parsePeerAddrToken(p.peerToken)
        assertEquals(node, addr.idHex)
        assertTrue(addr.relayUrl!!.startsWith("https://relay.example.com:8443"))
    }

    @Test
    fun `malformed links are not P-Pass pairing codes`() {
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
