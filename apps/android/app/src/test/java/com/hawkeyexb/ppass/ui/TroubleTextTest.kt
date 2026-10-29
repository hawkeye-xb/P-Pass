// T-083 目标 3：失败红卡渲染闸门单测——设计红线「报错永远不出现代码」
// （10-29 文案定稿起不再要求先说『照片没丢』：安抚话一律删除）。troubleTextOf 是原始错误串（IrohError dump / 异常
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

    // ── 资源级红线：红卡人话正文只说现状和出路，自身不含代码 ──────

    @Test
    fun redCardHumanCopySaysWhatHappenedAndCarriesNoCode() {
        val zh = zhStrings()
        // 配对失效卡：10-29 文案定稿删掉安抚话（「一张没丢」），只说现状和出路；不含代码碎片（T-083 红线）。
        val pairingLost = zh.getValue("pairing_lost_body")
        assertTrue("pairing_lost_body 要给出路「重新配对」: $pairingLost", pairingLost.contains("重新配对"))
        assertFalse("pairing_lost_body 不再写安抚话: $pairingLost", pairingLost.contains("没丢"))
        assertFalse("pairing_lost_body 不得含代码碎片", pairingLost.contains("{") || pairingLost.contains("kind:"))
        // 10-29 文案定稿：失败只自动重试到上限，之后要点「再试一次」——文案不再承诺「会自动再试」。
        // 资源级红线保留：人话正文、不含任何代码碎片。
        val runFailed = zh.getValue("run_failed")
        assertEquals("run_failed 必须是定稿文案", "有照片没能备份。", runFailed)
        assertFalse("run_failed 不许承诺自动重试: $runFailed", runFailed.contains("自动再试"))
        assertFalse("run_failed 不得含代码碎片", runFailed.contains("{") || runFailed.contains("kind:"))
        // 配对失效主按钮 = 「重新配对」（进去后可扫码也可输入配对码）。
        assertEquals("重新配对", zh.getValue("reconnect"))
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
