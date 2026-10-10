// #548：Android 日志脱敏与电脑端同口径——跑 daemon / 桌面壳 / transport 共用的同一份
// assets/privacy/redact-vectors.json。日志写入器只用 `redact()`，所以跑 exact + keep 两段
// （export 段是导出件专用的路径规则，桌面 log_guard 同样不用）。
package com.hawkeyexb.ppass.log

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RedactVectorsTest {

    private fun vectorFile(): File {
        var dir = File(System.getProperty("user.dir")).absoluteFile
        while (!File(dir, "assets/privacy/redact-vectors.json").isFile) {
            dir = dir.parentFile ?: error("assets/privacy/redact-vectors.json not found")
        }
        return File(dir, "assets/privacy/redact-vectors.json")
    }

    @Test
    fun `shared vectors hold - same file as the desktop`() {
        val v = Json.parseToJsonElement(vectorFile().readText()).jsonObject
        var n = 0
        for (case in v.getValue("exact").jsonArray) {
            val input = case.jsonObject.getValue("in").jsonPrimitive.content
            val want = case.jsonObject.getValue("out").jsonPrimitive.content
            assertEquals("input: $input", want, Redact.redact(input))
            assertEquals("not idempotent: $want", want, Redact.redact(want))
            n++
        }
        for (keep in v.getValue("keep").jsonArray) {
            val s = keep.jsonPrimitive.content
            assertEquals("false positive", s, Redact.redact(s))
            n++
        }
        assertTrue("vector file shrank to $n log cases", n >= 40)
    }

    @Test
    fun `ip literals parse like Rust core net, never via DNS`() {
        assertArrayEquals(intArrayOf(203, 0, 113, 7), Redact.parseIpv4("203.0.113.7"))
        assertNull("前导 0 Rust 不认", Redact.parseIpv4("203.0.113.07"))
        assertNull(Redact.parseIpv4("256.1.1.1"))
        assertNull(Redact.parseIpv4("1.2.3"))
        assertArrayEquals(intArrayOf(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), Redact.parseIpv6("2001:db8::1"))
        assertArrayEquals(intArrayOf(0, 0, 0, 0, 0, 0xffff, 0xcb00, 0x7107), Redact.parseIpv6("::ffff:203.0.113.7"))
        assertArrayEquals(IntArray(8), Redact.parseIpv6("::"))
        assertNull(":: 至少代表一组", Redact.parseIpv6("1:2:3:4:5:6:7::8"))
        assertNull(Redact.parseIpv6(":::"))
        assertNull(Redact.parseIpv6("12345::1"))
        assertNull("v4 不能出现在 :: 之前", Redact.parseIpv6("1.2.3.4::1"))
    }
}
