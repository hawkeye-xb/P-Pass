// UI-17（#354）：配对失效时照片 tab 只剩红卡这一个出路。
//
// 2026-09-28 回归实测：同一屏里同时出现「和家里的电脑失去了联系 … 重新扫码连接」红卡、
// 时间线区域的「正在重新连接电脑…」，以及「没能连上电脑。(timeline: err.not_authorized)」。
// 一个说要重新扫码，一个说正在重连，还露出了原始错误 key。设置 tab 同一信号下只给「重新扫码」。
//
// 判据：pairingLost（与红卡、设置 tab 同一个 holder.pairingLost）为真时，时间线区域的
// 重连 / 耗尽重试 / 原始错误三处提示全部收起；为假时行为与改动前一致。
package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UI17PhotosPairingLostTest {

    private val reconnecting = SubscriptionSessionState(subscribeHadFailure = true, subscribeConnected = false)
    private val exhausted = SubscriptionSessionState(subscribeHadFailure = true, subscribeExhausted = true)
    private val rawKey = "timeline: err.not_authorized"

    @Test
    fun pairingLostHidesReconnectingAndRawError() {
        // 回归现场的组合：订阅被拒在重连 + 初始整页加载失败带原始 key。
        val c = photosTimelineChrome(pairingLost = true, state = reconnecting, error = rawKey)
        assertFalse("配对失效时不得再说「正在重新连接电脑…」", c.showReconnecting)
        assertFalse("配对失效时不得露出原始错误 key", c.showTimelineError)
        assertFalse(c.showExhaustedRetry)
    }

    @Test
    fun pairingLostHidesExhaustedRetry() {
        // 「重试」是另一个出路（重连），与红卡「重新扫码」冲突。
        val c = photosTimelineChrome(pairingLost = true, state = exhausted, error = rawKey)
        assertFalse("配对失效时不得给「重试」这个出路", c.showExhaustedRetry)
        assertFalse(c.showReconnecting)
        assertFalse(c.showTimelineError)
    }

    @Test
    fun notPairingLostKeepsExistingBehaviour() {
        // 普通断线（桌面停服/没网）不受影响——SYNC-04 的提示照旧。
        val r = photosTimelineChrome(pairingLost = false, state = reconnecting, error = null)
        assertEquals(PhotosTimelineChrome(showReconnecting = true, showExhaustedRetry = false, showTimelineError = false), r)

        val e = photosTimelineChrome(pairingLost = false, state = exhausted, error = "boom")
        assertEquals(PhotosTimelineChrome(showReconnecting = false, showExhaustedRetry = true, showTimelineError = true), e)

        val ok = photosTimelineChrome(
            pairingLost = false,
            state = SubscriptionSessionState(subscribeConnected = true),
            error = null,
        )
        assertEquals(PhotosTimelineChrome(false, false, false), ok)
    }

    // ── 接线门禁（源文本）：投影算对了但 PhotosScreen 没用它 = 白做。

    /** 剥注释行：正向 contains 会被「把那行注释掉」骗过。 */
    private fun photosScreen(): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt").readText()
            .lines()
            .filterNot {
                val t = it.trimStart()
                t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
            }
            .joinToString("\n")
    }

    @Test
    fun photosScreenRendersTimelineNoticesThroughTheProjection() {
        val src = photosScreen()
        val body = src.substringAfter("internal fun PhotosScreen(")
        assertTrue(
            "投影输入必须是红卡同一个 pairingLost 参数",
            body.contains("photosTimelineChrome(pairingLost, holder.state, error)"),
        )
        assertTrue("「正在重新连接」必须经投影", body.contains("if (chrome.showReconnecting)"))
        assertTrue("「重试」必须经投影", body.contains("if (chrome.showExhaustedRetry)"))
        assertTrue("原始错误必须经投影", body.contains("error != null && chrome.showTimelineError ->"))
        assertTrue(
            "配对失效且空列表不得落到「照片库还是空的」（另一个出路）",
            body.contains("error != null && items.isEmpty() -> Unit"),
        )
        assertFalse(
            "composable 里不得再直接按订阅标志渲染重连提示（绕过投影）",
            body.contains("if (subscribeHadFailure") || body.contains("if (subscribeExhausted)"),
        )
    }
}
