// #250 UI-14 / #251 UI-15 生产链路门禁（源文本，只钉接线）：投影出的 TransferRow 真的经 holder → MainActivity →
// HomeScreen 渲染；进行中那一块每格单行、进度条没有时留同高空位；「在等」用等待色。
// 行为判据（停滞 vs 正常、中间截断、字节文案）在 backup/flow/UI14TransferRowTest.kt。
package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UI15TransferRowWiringTest {
    private val main = File("src/main/java/com/hawkeyexb/ppass")
    private fun read(path: String) = File(main, path).readText()

    /** HomeScreen 里「进行中」那一块：从 `if (busy) {` 到空闲分支之前。 */
    private val busyBlock: String
        get() {
            val home = read("ui/HomeScreen.kt")
            val start = home.indexOf("if (busy) {")
            val end = home.indexOf("// 规则 P（#413）", start)
            assertTrue("找不到进行中那一块", start >= 0 && end > start)
            return home.substring(start, end)
        }

    // 反证：MainActivity 不把 holder.transferRow 交给 HomeScreen → 首页永远走旧的一句话，红。
    @Test
    fun the_transfer_row_is_wired_from_the_projection_to_the_screen() {
        val holder = read("backup/BackupUiStateHolder.kt")
        assertTrue(holder.contains("transferMark = advanceTransferMark(transferMark, current, now)"))
        assertTrue(holder.contains("_transferRow.value = transferRowOf(current, transferMark, now)"))
        // 字节停下时引擎不再发任何东西：必须有按秒走的 ticker 重算，否则「N 秒没有新数据」永远不出现。
        assertTrue(holder.contains("delay(TRANSFER_TICK_MS)"))
        assertTrue(holder.contains("publishTransferRow(p)"))

        val call = read("MainActivity.kt").substringAfter("HomeScreen(").substringBefore("onDisconnect")
        assertTrue(call.contains("transferRow = holder.transferRow.value"))

        val block = busyBlock
        assertTrue(block.contains("row?.fileName ?: workingText(line)"))
        assertTrue(block.contains("stringResource(R.string.state_sending_slow, row.quietSeconds)"))
        assertTrue(block.contains("stringResource(R.string.state_sending_detail, row.bytesText, sending.done, sending.total)"))
        assertTrue("「在等」要与正常传输看得出不同：等待色", block.contains("if (slow) PPColor.Waiting else PPColor.Ink60"))
    }

    // #251：进行中那一块高度固定——两行文字都是单行不折行，进度条没有时留同高空位。
    // 反证：去掉任一 Text 的 `maxLines = 1, softWrap = false` → 计数变 1，红；删掉进度条的同高空位 → 第二条红。
    @Test
    fun every_line_in_the_busy_block_is_single_line_and_the_bar_slot_is_reserved() {
        val block = busyBlock
        val texts = Regex("""\bText\(""").findAll(block).count()
        val singleLine = Regex("""maxLines = 1, softWrap = false, overflow = TextOverflow\.Ellipsis""").findAll(block).count()
        assertEquals("进行中那一块的每个 Text 都必须单行", texts, singleLine)
        assertEquals(2, texts)
        assertTrue(block.contains("Spacer(Modifier.fillMaxWidth().height(6.dp))"))
        assertTrue(block.contains("modifier = Modifier.fillMaxWidth().height(6.dp)"))
    }
}
