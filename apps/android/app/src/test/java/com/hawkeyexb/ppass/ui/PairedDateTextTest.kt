package com.hawkeyexb.ppass.ui

import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * #1206：「存储电脑」的配对日期按界面语言给本地化长日期，不写死中文格式串。
 * E2 反证：把实现改回 `SimpleDateFormat("yyyy年M月d日")`，下面两条用例都会红。
 */
class PairedDateTextTest {
    // 本地 2026-10-14 正午：无论机器在哪个时区，格式化出来都是 10 月 14 日。
    private val pairedAt: Long = LocalDate.of(2026, 10, 14)
        .atTime(LocalTime.NOON)
        .atZone(ZoneId.systemDefault())
        .toInstant()
        .toEpochMilli()

    @Test
    fun chinese_locale_keeps_chinese_long_date_and_follows_locale() {
        val zh = pairedDateText(pairedAt, Locale.SIMPLIFIED_CHINESE)
        assertEquals("2026年10月14日", zh)
        // 同一时间戳换 locale 必须换写法——写死中文格式串时这里会相等。
        assertNotEquals("日期格式没有跟随界面语言", zh, pairedDateText(pairedAt, Locale.US))
    }

    @Test
    fun us_english_locale_uses_english_long_date() {
        val en = pairedDateText(pairedAt, Locale.US)
        assertEquals("October 14, 2026", en)
        for (cjk in listOf("年", "月", "日")) {
            assertFalse("英文界面不该出现「$cjk」：$en", en.contains(cjk))
        }
    }
}
