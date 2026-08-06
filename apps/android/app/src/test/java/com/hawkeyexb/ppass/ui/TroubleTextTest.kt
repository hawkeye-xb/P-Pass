// T-083 目标 3：失败红卡渲染闸门单测——设计红线「报错永远不出现代码，
// 先说『照片没丢』」。troubleTextOf 是原始错误串（IrohError dump / 异常
// toString）进 UI 的唯一通道：主文案（main）恒为人话正文，绝不含代码
// 碎片；原文只落 detail（默认收起的「查看技术详情」+ 诊断导出可达）。
// 同 BackupStatusTest 手法解析真实 values-zh/strings.xml，把断言落到
// 实际中文文案上，防止有人改字符串绕过红线。
package com.hawkeyexb.ppass.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class TroubleTextTest {

    /** 卡面钦定的输入形状：iroh 原始错误 dump。 */
    private val rawIrohError =
        """IrohError { kind: KeyParsing, message: "invalid public key: length 12, expected 32" }"""

    // ── 主文案绝不含代码碎片（验收第 2 条） ────────────────────────

    @Test
    fun rawIrohErrorNeverReachesMainCopy() {
        val t = troubleTextOf(
            rawError = rawIrohError,
            humanBody = zhStrings().getValue("run_failed"),
        )
        assertFalse("主文案不得含 '{': ${t.main}", t.main.contains("{"))
        assertFalse("主文案不得含 'kind:': ${t.main}", t.main.contains("kind:"))
        assertFalse("主文案不得含错误类名 'IrohError': ${t.main}", t.main.contains("IrohError"))
    }

    @Test
    fun exceptionDumpAlsoStaysOutOfMainCopy() {
        // BackupUiStateHolder catch 的真实形状：Throwable.toString()。
        val dump = IllegalStateException("backup.begin failed: err.backup_failed").toString()
        val t = troubleTextOf(rawError = dump, humanBody = zhStrings().getValue("run_failed"))
        assertFalse("主文案不得含异常类名: ${t.main}", t.main.contains("IllegalStateException"))
        assertFalse("主文案不得含 msg_key: ${t.main}", t.main.contains("err.backup_failed"))
    }

    // ── 详情字段才含原文（折叠区 + 诊断路径的输入） ────────────────

    @Test
    fun detailKeepsTheFullRawError() {
        val t = troubleTextOf(rawError = rawIrohError, humanBody = "人话正文")
        assertTrue("详情必须含原文 kind 字段: ${t.detail}", t.detail.contains("kind: KeyParsing"))
        assertTrue("详情必须含原文 message: ${t.detail}", t.detail.contains("invalid public key"))
        assertEquals("详情 = 原文（仅 trim）", rawIrohError, t.detail)
    }

    // ── 资源级红线：红卡人话正文先说「照片没丢」，自身不含代码 ──────

    @Test
    fun redCardHumanCopySaysPhotosSafeAndCarriesNoCode() {
        val zh = zhStrings()
        for (key in listOf("run_failed", "pairing_lost_body")) {
            val v = zh.getValue(key)
            assertTrue("$key 必须先说照片没丢: $v", v.contains("没丢") || v.contains("安全"))
            assertFalse("$key 不得含代码碎片: $v", v.contains("{") || v.contains("kind:"))
        }
        // 哨兵态主按钮文案 = 「重新扫码连接」（T-083 目标 4）。
        assertEquals("重新扫码连接", zh.getValue("reconnect"))
        // 普通失败主按钮 = 「再试一次」语义。
        assertEquals("再试一次", zh.getValue("try_again"))
    }

    // ── 工具：解析真实 values-zh/strings.xml（同 BackupStatusTest 手法）──

    private fun zhStrings(): Map<String, String> {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found above ${System.getProperty("user.dir")}")
        }
        val xml = File(dir, "apps/android/app/src/main/res/values-zh/strings.xml")
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(xml)
        val nodes = doc.getElementsByTagName("string")
        val result = LinkedHashMap<String, String>()
        for (i in 0 until nodes.length) {
            val el = nodes.item(i) as Element
            result[el.getAttribute("name")] = el.textContent?.trim().orEmpty()
        }
        return result
    }
}
