// #565: 「我断开了这次配对」走发件箱——先持久登记、再清本地；按结构化错误码判结局；
// 重试有期限；通知带上要结束的那次配对的纪元（daemon 只在纪元一致时吊销）。
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Resp
import com.hawkeyexb.ppass.proto.RespError
import java.io.File
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UnpairNoticeTest {

    /**
     * 反证：把 NOT_AUTHORIZED 判成 Retry（= 电脑已不认这台手机还一直重发）→ 第二条红；
     * 把连不上判成 Done（= 回到「只发一次」）→ 第四条红。
     */
    @Test
    fun deliveryIsClassifiedByTheStructuredErrorCode() {
        assertEquals(UnpairDelivery.Done, unpairDeliveryOf(Resp(ok = true)))
        assertEquals(
            "电脑已不认这台手机（已吊销 / 没有这行）= 目标已达成",
            UnpairDelivery.Done,
            unpairDeliveryOf(Resp(ok = false, error = RespError(code = UNPAIR_ALREADY_GONE_CODE, msgKey = "err.not_authorized"))),
        )
        assertEquals(
            "服务端内部错误：稍后再投",
            UnpairDelivery.Retry,
            unpairDeliveryOf(Resp(ok = false, error = RespError(code = "INTERNAL", msgKey = "err.unsupported"))),
        )
        assertEquals("连不上：稍后再投", UnpairDelivery.Retry, unpairDeliveryOf(null))
        assertEquals(
            "只认结构化错误码，不认文案",
            UnpairDelivery.Retry,
            unpairDeliveryOf(Resp(ok = false, error = RespError(code = "INTERNAL", msgKey = "err.not_authorized"))),
        )
    }

    @Test
    fun retriesStopAfterTheDeliveryWindow() {
        val start = 1_000_000L
        assertFalse(unpairNoticeExpired(start, start))
        assertFalse(unpairNoticeExpired(start, start + UNPAIR_NOTICE_MAX_AGE_MS))
        assertTrue("过了 7 天仍送不到就放弃，不无限重试", unpairNoticeExpired(start, start + UNPAIR_NOTICE_MAX_AGE_MS + 1))
    }

    /** 反证：去掉纪元参数 → daemon 走无条件吊销，迟到的旧通知会吊销新配对——第一条红。 */
    @Test
    fun theNoticeNamesThePairingItEnds() {
        assertEquals(JsonPrimitive("epoch-1"), unpairParams("epoch-1")["pairing_epoch"])
        assertFalse("旧配对没有纪元：不带参数，daemon 走旧语义", unpairParams("").containsKey("pairing_epoch"))
    }

    /** 反证：把 enqueue 挪到 clearLocalPairing 之后（或删掉）→ 红。 */
    @Test
    fun disconnectRecordsTheNoticeBeforeClearingLocalPairing() {
        val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        val branch = main.substringAfter("onDisconnect = {").substringBefore("\n                        },")
        val enqueue = branch.indexOf("UnpairNotice.enqueue(context, s.pairing)")
        val clear = branch.indexOf("clearLocalPairing(context, s.pairing)")
        assertTrue("断开必须登记通知: $branch", enqueue >= 0)
        assertTrue("先登记通知、再清本地配对（通知自带地址，不依赖之后被清的 pairing.json）", enqueue in 0 until clear)
        assertFalse("不再有「只发一次、失败吞掉」的直连", branch.contains("client.unpair("))
    }
}
