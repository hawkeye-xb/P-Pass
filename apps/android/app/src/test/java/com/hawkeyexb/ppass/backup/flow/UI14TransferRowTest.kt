// #250 UI-14 / #251 UI-15：首页「当前这一张」那一块的投影契约（E2，纯函数）。
//  - 正常增长 vs 字节停滞 → 不同的节奏（#250 验收 3）；
//  - 文件名中间截断、保住扩展名、宽度有上限（#251：单行的前提）；
//  - 「12.3 / 189 MB」。
// 接线（holder → MainActivity → HomeScreen、单行约束）的源文本门禁在 ui/UI15TransferRowWiringTest.kt。
// 反证写在每个测试上方。
package com.hawkeyexb.ppass.backup.flow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UI14TransferRowTest {
    private val total = 189_000_000L
    private fun item(sent: Long, orderId: Long = 7, name: String = "20260915_155239.mp4", size: Long = total) =
        CurrentItem(orderId, name, sent, size)

    /** 按 1 秒一拍把一串「此刻看到的当前项」喂给投影，返回每一拍的那一行（holder 的 ticker 就是这么做的）。 */
    private fun replay(samples: List<CurrentItem?>): List<TransferRow?> {
        var mark: TransferMark? = null
        return samples.mapIndexed { second, current ->
            val now = 1_000_000L + second * 1_000L
            mark = advanceTransferMark(mark, current, now)
            transferRowOf(current, mark, now)
        }
    }

    // E2 主契约：同样 20 秒，一个字节一直在涨（慢，但在涨：每秒 100 KB），一个第 3 秒起字节不动。
    // 前者从头到尾都是 MOVING，后者满 15 秒变 SLOW——两条时间线在界面上必须分得开。
    // 反证 1：transferPaceOf 去掉「nowMs − 标记 ≥ 门槛」这条（恒返回 MOVING）→ 停滞那条最后是 MOVING，两者一致，红。
    // 反证 2：advanceTransferMark 不比 bytesSent（字节变了也不重新打点）→ 标记停在第一拍的字节数上，停滞那条永远 MOVING，红。
    @Test
    fun `a slow but moving transfer and a stalled one project to different paces`() {
        val moving = replay((0..20).map { item(sent = 1_000_000L + it * 100_000L) })
        val stalled = replay((0..20).map { item(sent = 1_000_000L + minOf(it, 3) * 100_000L) })

        assertTrue("慢但在涨：每一拍都是 MOVING", moving.all { it!!.pace == TransferPace.MOVING })
        // 第 3 秒最后一次前进；第 3 + 14 秒还差 1 秒；第 3 + 15 秒起 SLOW。
        assertEquals(TransferPace.MOVING, stalled[3 + 14]!!.pace)
        assertEquals(TransferPace.SLOW, stalled[3 + 15]!!.pace)
        assertEquals(15, stalled[3 + 15]!!.quietSeconds)
        assertEquals(TransferPace.SLOW, stalled[20]!!.pace)
        assertEquals("「N 秒没有新数据」的 N 随时间走", 17, stalled[20]!!.quietSeconds)
        assertNotEquals(moving.last()!!.pace, stalled.last()!!.pace)
    }

    // 停下之后字节又动了 → 立刻回到 MOVING，计时清零。
    // 反证：advanceTransferMark 不比 bytesSent、且 transferPaceOf / transferRowOf 只按 orderId 认标记
    // （两层都不看字节）→ 恢复后仍是 SLOW，红。（只去掉其中一层时，另一层兜住；单去 advance 那层红在主契约。）
    @Test
    fun `bytes moving again clears the slow verdict at once`() {
        val samples = (0..20).map { item(sent = 5_000_000L) } + item(sent = 5_100_000L)
        val rows = replay(samples)
        assertEquals(TransferPace.SLOW, rows[20]!!.pace)
        assertEquals(TransferPace.MOVING, rows.last()!!.pace)
        assertEquals(0, rows.last()!!.quietSeconds)
    }

    // 换到下一张 → 重新计时，不继承上一张攒下的「没动」。App 刚打开时第一眼看到的也从 0 算（不能一打开就说「在等」）。
    // 反证：advanceTransferMark 不比 orderId、且 transferPaceOf / transferRowOf 不看标记属于哪一张 → 第二张（同样从 0 字节
    // 开始）直接继承上一张攒下的 16 秒，第一拍就是 SLOW，红。（只去掉其中一层时，另一层兜住。）
    @Test
    fun `a new item or a first look starts the clock from zero`() {
        val first = (0..16).map { item(sent = 0, orderId = 1) }
        val second = listOf(item(sent = 0, orderId = 2))
        val rows = replay(first + second)
        assertEquals(TransferPace.SLOW, rows[16]!!.pace)
        assertEquals(TransferPace.MOVING, rows.last()!!.pace)
        assertEquals(0, rows.last()!!.quietSeconds)

        val firstLook = replay(listOf(item(sent = 120_000_000L)))
        assertEquals(TransferPace.MOVING, firstLook.single()!!.pace)
    }

    // 字节全部发出、在等电脑确认收下（BLAKE3 + 入库，189 MB 要一会儿）→ FINISHING，不是 SLOW：100% 时不许报警。
    // 反证：去掉 transferPaceOf 开头的「sent ≥ total → FINISHING」→ 第 20 拍是 SLOW，红。
    @Test
    fun `all bytes sent and waiting for the receipt is not slow`() {
        val rows = replay((0..20).map { item(sent = total) })
        assertTrue(rows.all { it!!.pace == TransferPace.FINISHING })
    }

    // 门槛的依据（写在 TRANSFER_SLOW_AFTER_MS 的注释里）钉成断言：高于正常传输下首页字节数的最长空档
    // （500ms 本地读取 + 1s 刷新节流，以及 status 兜底封顶 8s），远低于 3 分钟断开，与「去问桌面」同一个数。
    // 反证：把门槛改成 1_000 → 第一条红（健康传输会闪「没有新数据」）；改成 BYTE_STALL_THRESHOLD_MS → 第二条红。
    @Test
    fun `the slow threshold sits between healthy refresh gaps and the hard stall`() {
        assertTrue(TRANSFER_SLOW_AFTER_MS > LOCAL_STATUS_RECHECK_MS + STATUS_REFRESH_MIN_INTERVAL_MS + nextStatusPollDelayMs(99))
        assertTrue(TRANSFER_SLOW_AFTER_MS * 10 <= BYTE_STALL_THRESHOLD_MS)
        assertEquals(LOCAL_IDLE_STALL_THRESHOLD_MS, TRANSFER_SLOW_AFTER_MS)
    }

    @Test
    fun `not transferring means no row`() {
        assertNull(transferRowOf(null, null, 0))
        assertNull(advanceTransferMark(TransferMark(1, 2, 3), null, 10))
    }

    // ---------------------------------------------------------------- #251 文件名

    // 验收人现场的长名字：单行放得下（宽度 ≤ 上限），扩展名和尾部的序号都还在，开头也认得出。
    // 反证：middleEllipsize 改成 `name.take(maxUnits)`（纯尾部截断）→ 扩展名没了，红；改成原样返回 → 宽度超限，红。
    @Test
    fun `long names are cut in the middle and keep the extension`() {
        val names = listOf(
            "Screenshot_20260910_161635_One UI Home.jpg",
            "ppass-test-large-video-for-progress-row-0001.mp4",
            "20260915_155239_with_a_very_long_suffix_here.mp4",
        )
        for (name in names) {
            val cut = middleEllipsize(name)
            assertTrue("$cut 太宽", displayUnits(cut) <= TRANSFER_FILE_NAME_MAX_UNITS)
            assertTrue("$cut 丢了扩展名", cut.endsWith(name.substringAfterLast('.').let { ".$it" }))
            assertTrue("$cut 没有省略号", cut.contains("…"))
            assertTrue("$cut 开头认不出", cut.startsWith(name.take(6)))
        }
        assertTrue(middleEllipsize("ppass-test-large-video-for-progress-row-0001.mp4").endsWith("0001.mp4"))
    }

    // 短名字原样；没有扩展名的长名字也只在中间截；中文按两个单位算、不切开 emoji（代理对）。
    // 反证：displayUnits 把中文算 1 → 中文长名字截出来比上限宽一倍，第二条红。
    @Test
    fun `short names are untouched and wide characters count double`() {
        assertEquals("20260915_155239.mp4", middleEllipsize("20260915_155239.mp4"))
        assertEquals("IMG_1.jpg", middleEllipsize("IMG_1.jpg"))

        val cjk = "微信图片_二零二六年九月十五日下午三点五十二分三十九秒.jpg"
        val cjkCut = middleEllipsize(cjk)
        assertTrue(cjkCut, displayUnits(cjkCut) <= TRANSFER_FILE_NAME_MAX_UNITS)
        assertTrue(cjkCut, cjkCut.endsWith(".jpg"))

        val noExt = "a".repeat(20) + "MIDDLE" + "z".repeat(20)
        val noExtCut = middleEllipsize(noExt)
        assertTrue(noExtCut.startsWith("aaaa") && noExtCut.endsWith("zzzz") && "MIDDLE" !in noExtCut)

        val emoji = "😀".repeat(30) + ".png"
        val emojiCut = middleEllipsize(emoji)
        assertTrue(emojiCut.endsWith(".png"))
        assertTrue("不切开代理对", emojiCut.codePoints().allMatch { it !in 0xD800..0xDFFF })
        assertTrue(displayUnits(emojiCut) <= TRANSFER_FILE_NAME_MAX_UNITS)
    }

    // 投影出的那一行已经截好：HomeScreen 直接拿 row.fileName 单行渲染。
    @Test
    fun `the row carries the already-shortened name`() {
        val row = transferRowOf(item(0, name = "Screenshot_20260910_161635_One UI Home.jpg"), null, 0)!!
        assertEquals(middleEllipsize("Screenshot_20260910_161635_One UI Home.jpg"), row.fileName)
    }

    // ---------------------------------------------------------------- #250 字节文案

    // 单位按总大小选、两边同一个单位；十进制；小于 100 一位小数，否则取整。
    // 反证：单位按已传字节各自选 → 「900 KB / 189 MB」，第二条红。
    @Test
    fun `bytes text uses the total's unit on both sides`() {
        assertEquals("12.3 / 189 MB", bytesProgressText(12_300_000, 189_000_000))
        assertEquals("0.9 / 189 MB", bytesProgressText(900_000, 189_000_000))
        assertEquals("0 / 189 MB", bytesProgressText(0, 189_000_000))
        assertEquals("189 / 189 MB", bytesProgressText(250_000_000, 189_000_000))
        assertEquals("1.2 / 4.3 GB", bytesProgressText(1_200_000_000, 4_300_000_000))
        assertEquals("512 / 800 KB", bytesProgressText(512_000, 800_000))
        assertNull("总大小未知不编数字", bytesProgressText(10, 0))
        assertEquals("12.3 / 189 MB", transferRowOf(item(12_300_000), null, 0)!!.bytesText)
    }
}
