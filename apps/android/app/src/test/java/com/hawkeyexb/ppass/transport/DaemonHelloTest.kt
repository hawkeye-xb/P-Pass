// T-051 acceptance: a REAL round trip — this JVM test binds an actual
// iroh endpoint (the iroh-ffi jar ships desktop natives) and speaks
// hello to a live storage daemon, exactly like the phone will.
//
// Needs a daemon: set PPF_DAEMON_QR to a fresh pairing QR string
// (`ppf://pair?node=…&t=…&r=…`). Skipped when unset so CI stays hermetic;
// `just android-hello` runs the full script locally.
//
// E2E-02（2026-08-20）：本测试原先第一步断言 `parsed.addr != null`，也就是
// 要求配对码带 `&a=` 段。而 **H-10b（2026-08-08）已经把 `a=` 从配对码里
// 去掉了**——完整 PeerAddr（100–180 字符 base64）太密扫不动，新码只带
// relay URL（`r=`），手机端从 node+relay 重建地址。于是这个断言从那天起
// 恒假，e2e 门禁（nightly + 每个 release tag）**一直是红的**，且 daemon
// 日志一切正常，迷惑性极强（用户打 v0.3.3-test.7 时实际撞到）。
//
// 修法就是照生产代码走：地址重建逻辑与 `PairFlow.kt` 完全同源
// （`parsed.addr ?: relayUrl -> PeerAddrParts(node, relay, [])`）。
// 测试必须走用户真实走的那条路，不能停在一个三周前就废弃的契约上。
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.ProtoJson
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class DaemonHelloTest {

    @Test
    fun helloRoundTripAgainstLiveDaemon() {
        val qr = System.getenv("PPF_DAEMON_QR")
        assumeTrue("PPF_DAEMON_QR not set — skipping live-daemon test", !qr.isNullOrBlank())

        runBlocking {
            val parsed = parsePairingQr(qr!!.trim())
            // H-10b 之后的正路：新码只有 r=，从 node+relay 重建；旧码的
            // a= 仍兼容。与 PairFlow.pairWithQr 同一套判断，不许两边漂移。
            // E2E-02: 重建逻辑抽进 addrOf（PairingQrAddr.kt）——四个 e2e
            // 测试共用一份，下次协议变只改那里。
            val addr: PeerAddrParts = addrOf(parsed)

            val client = DaemonClient()
            client.bind()
            try {
                val resp = client.call(addr, Methods.HELLO, buildJsonObject {})
                assertTrue("hello must succeed: ${resp.error}", resp.ok)
                val hello: Hello =
                    ProtoJson.decodeFromJsonElement(Hello.serializer(), resp.result!!)
                assertEquals(1, hello.protoVer)
                assertTrue(
                    "daemon must announce thumbnail.v1: ${hello.capabilities}",
                    hello.capabilities.contains("thumbnail.v1"),
                )
                println("HELLO OK: ${hello.deviceName} caps=${hello.capabilities}")
            } finally {
                client.close()
            }
        }
    }
}
