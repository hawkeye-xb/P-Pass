// #1883 存储电脑详情页「已连接」与照片页「连接已中断」同屏矛盾——E2 合同测试。
//
// 本质要保证的：屏幕上任何一句「连接状态」都来自**一个**权威事实，文案说的就是那个事实本身。
// 「已连接」这种强断言，只能在真的有连接时用。
//
// 钉住的不变量（详情页与照片页都从 connectionStateOf 出的 ConnectionState 取文案与显示条件）：
//   1. 「配对有效 + 订阅退避耗尽」时两页结论一致（都说没连上）——旧写法在这里红：旧
//      storageDetailBody(pairingLost = false, …) 会给「已连接」，而照片页同时给「已中断」。
//   2. 配对被吊销时，两页都走「重新扫码连接」。
//   3. 真正直连/中继时，两页都说已连接。
//   4. 失联天数由同一个状态携带，不再是第三个独立信号。
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class S1883ConnectionConsistencyTest {

    private fun live() = SubscriptionSessionState(subscribeConnected = true)
    private fun reconnecting() = SubscriptionSessionState(subscribeHadFailure = true)
    private fun exhausted() = SubscriptionSessionState(subscribeHadFailure = true, subscribeExhausted = true)

    /** 详情页第一行是不是在声称「已连接」。 */
    private fun detailClaimsConnected(c: ConnectionState) =
        storageDetailLines(c.status, pairedAt = 0L).statusRes == R.string.storage_detail_connected

    /** 照片页是不是在说「连接已中断」+ 给「重试」。 */
    private fun photosClaimsDisconnected(c: ConnectionState) =
        photosTimelineChrome(c, error = null).showExhaustedRetry

    // ── 合成 ──

    @Test
    fun pairingLostOutranksEverything() {
        for (s in listOf(live(), reconnecting(), exhausted(), SubscriptionSessionState())) {
            assertEquals(
                "配对已失效是另一个维度，优先于实时连接",
                ConnectionState.Status.PairingLost,
                connectionStateOf(pairingLost = true, state = s).status,
            )
        }
    }

    @Test
    fun liveSubscriptionIsConnected() {
        assertEquals(ConnectionState.Status.Connected, connectionStateOf(pairingLost = false, state = live()).status)
    }

    @Test
    fun exhaustedBackoffIsOffline() {
        assertEquals(ConnectionState.Status.Offline, connectionStateOf(pairingLost = false, state = exhausted()).status)
    }

    @Test
    fun failedButNotExhaustedIsReconnecting() {
        assertEquals(
            ConnectionState.Status.Reconnecting,
            connectionStateOf(pairingLost = false, state = reconnecting()).status,
        )
    }

    @Test
    fun freshSessionIsUnknownNotConnected() {
        // 刚进前台、这次订阅还没连上：不许默认成「已连接」（那正是原缺陷）。
        assertEquals(
            ConnectionState.Status.Unknown,
            connectionStateOf(pairingLost = false, state = SubscriptionSessionState()).status,
        )
    }

    // ── 不变量 1：配对有效 + 订阅退避耗尽 → 两页结论一致（旧写法在这里红） ──

    @Test
    fun pairedButSubscriptionExhaustedReadsDisconnectedOnBothPages() {
        val c = connectionStateOf(pairingLost = false, state = exhausted())
        assertEquals(ConnectionState.Status.Offline, c.status)
        assertFalse("详情页不得再说「已连接」（旧写法 pairingLost=false 就给已连接）", detailClaimsConnected(c))
        assertEquals(R.string.storage_detail_offline, storageDetailLines(c.status, pairedAt = 0L).statusRes)
        assertTrue("照片页同一时刻说「连接已中断」+「重试」", photosClaimsDisconnected(c))
    }

    // ── 不变量 2：配对被吊销 → 两页都走「重新扫码连接」 ──

    @Test
    fun pairingRevokedSendsBothPagesToRepair() {
        val c = connectionStateOf(pairingLost = true, state = exhausted())
        assertTrue(c.needsRepair)
        assertEquals(R.string.storage_detail_lost, storageDetailLines(c.status, pairedAt = 0L).statusRes)
        // 照片页：红卡是唯一出路，时间线区域的重连 / 重试 / 原始错误三处全部收起。
        val chrome = photosTimelineChrome(c, error = "timeline: err.not_authorized")
        assertFalse(chrome.showReconnecting)
        assertFalse(chrome.showExhaustedRetry)
        assertFalse(chrome.showTimelineError)
    }

    // ── 不变量 3：真正直连/中继 → 两页都说已连接 ──

    @Test
    fun liveConnectionReadsConnectedOnBothPages() {
        // 手机侧不区分直连与中继（路径分类只在诊断探测里），连上就是连上——两页同一个结论。
        val c = connectionStateOf(pairingLost = false, state = live())
        assertTrue(detailClaimsConnected(c))
        assertFalse("照片页不得同时说「连接已中断」", photosClaimsDisconnected(c))
        assertEquals(PhotosTimelineChrome(false, false, false), photosTimelineChrome(c, error = null))
    }

    // ── 不变量 4：失联天数由同一个状态携带 ──

    @Test
    fun daysUnreachableRidesOnTheOneState() {
        assertEquals(7, connectionStateOf(pairingLost = true, state = exhausted(), daysUnreachable = 7).daysUnreachable)
        // 从未确认可达过 → null，不编天数（照片页红卡改用不带天数的兜底文案）。
        assertNull(connectionStateOf(pairingLost = true, state = exhausted()).daysUnreachable)
    }

    // ── 配对已失效那张卡只有一行（旧写法是早返回，改状态源时不能把这条丢掉） ──

    @Test
    fun pairingLostCardCarriesNoPairedLine() {
        val pairedAt = 1_700_000_000_000L
        val lost = storageDetailLines(ConnectionState.Status.PairingLost, pairedAt)
        assertFalse(
            "配对已失效时不得再拼「配对 X · 已备份 N 张」——同一张卡不能既说失效又说还配着",
            lost.showPairedLine,
        )
        assertFalse("「配对已失效」那行不带「最近同步」参数", lost.statusTakesLastSuccess)
        assertEquals(R.string.storage_detail_lost, lost.statusRes)
    }

    @Test
    fun otherStatesCarryThePairedLineOnlyWhenTheDateIsKnown() {
        for (status in listOf(
            ConnectionState.Status.Connected,
            ConnectionState.Status.Reconnecting,
            ConnectionState.Status.Offline,
            ConnectionState.Status.Unknown,
        )) {
            assertTrue("$status 配对日期已知时要拼第二行", storageDetailLines(status, pairedAt = 1L).showPairedLine)
            assertFalse("$status 配对日期未知（0）时不硬凑第二行", storageDetailLines(status, pairedAt = 0L).showPairedLine)
            assertTrue("$status 第一行带「最近同步」参数", storageDetailLines(status, pairedAt = 0L).statusTakesLastSuccess)
        }
    }

    // ── 连上之后照片页不再整页说「无法连接电脑」（评审 #1898 建议 1，Bugbot 复审后改了做法） ──

    @Test
    fun photosChromeShowsTheRawErrorOnlyWhileThereIsOne() {
        // 这一层不再按连接状态二次遮 error：遮掉会让下面「error 非空且一张都没有」那条
        // 落到空白页（Bugbot 在 #1898 上抓到过）。真正的修法在源头——holder 在 onConnected
        // 里补一次整页，把连上之后作废的旧 error 清掉（协程级断言见
        // TimelineSubscriptionHolderTest.connectingRetriesThePageThatFailedBeforeTheConnection）。
        val connected = connectionStateOf(pairingLost = false, state = live())
        assertTrue(connected.isConnected)
        assertFalse("没有 error 就不显", photosTimelineChrome(connected, error = null).showTimelineError)
        assertTrue("有 error 就显——由 holder 保证连上后它会清掉", photosTimelineChrome(connected, error = "boom").showTimelineError)
        // 配对已失效时红卡是唯一出路，本来就不显。
        val lost = connectionStateOf(pairingLost = true, state = live())
        assertFalse(photosTimelineChrome(lost, error = "boom").showTimelineError)
    }

    // ── 接线门禁（源文本）：裁决算对了但正文没用它 = 白做（独立评审 #1898 建议 2） ──

    /** 剥注释行：正向 contains 会被「把那行注释掉」骗过。 */
    private fun homeScreenSource(): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()
            .lines()
            .filterNot {
                val t = it.trimStart()
                t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
            }
            .joinToString("\n")
    }

    @Test
    fun storageDetailBodyActuallyUsesTheVerdict() {
        // 把正文改回「非失效一律已连接」而留着 helper，上面那些纯函数断言仍会全绿——所以钉接线。
        val body = homeScreenSource().substringAfter("internal fun storageDetailBody(")
        assertTrue(
            "正文必须由 storageDetailLines 裁决行数与文案",
            body.contains("storageDetailLines(connection.status, pairedAt)"),
        )
        assertTrue("正文必须用裁决出的资源", body.contains("stringResource(lines.statusRes"))
        assertTrue("第二行必须受裁决门控", body.contains("if (!lines.showPairedLine) return line1"))
    }

    @Test
    fun storageDetailScreenPassesTheOneStateToTheBodyAndTheDot() {
        val detail = homeScreenSource().substringAfter("private fun StorageComputerDetail(")
        assertTrue("详情页正文必须吃唯一连接状态", detail.contains("storageDetailBody(connection,"))
        assertTrue("状态点必须吃同一份状态", detail.contains("storageDetailDotColor(connection.status)"))
    }

    // ── 逐状态：两页不可能给出相反结论 ──

    @Test
    fun everyStatusAgreesAcrossBothPages() {
        for (status in ConnectionState.Status.values()) {
            val c = ConnectionState(status)
            val detailConnected = detailClaimsConnected(c)
            val photosDisconnected = photosClaimsDisconnected(c)
            assertEquals("「已连接」只许在 Connected 出现", status == ConnectionState.Status.Connected, detailConnected)
            assertEquals("「连接已中断 + 重试」只许在 Offline 出现", status == ConnectionState.Status.Offline, photosDisconnected)
            assertFalse("同屏不可能一边说已连接、一边说已中断", detailConnected && photosDisconnected)
            assertEquals("配对已失效时详情页说失效", status == ConnectionState.Status.PairingLost, c.needsRepair)
        }
    }
}
