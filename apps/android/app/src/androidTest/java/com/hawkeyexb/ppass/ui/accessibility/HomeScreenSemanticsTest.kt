// #1801 E2：设置页开关行、单次入口两行、英雄区单次传输状态行的读屏语义回归。
//
// 语义口径 = #1801 第三轮真机报告（.evidence/1801/round3/ 的 uiautomator dump）实测：
//   - 开关行（RuleSwitchRow）：整行一个语义节点——checkable + checked 报开合状态，
//     名称（自动备份 / 仅 Wi-Fi / 通知）合并在行子树里，行内 Switch 只画状态、
//     不单独暴露 checkable 子节点；点整行切换开关（TalkBack 双击走同一个 ACTION_CLICK）。
//   - 单次入口两行（CellRow 从相册选择 / 从文件选择）：整行可点（Role.Button 的
//     a11y 体现是 className Button），不是勾选项，名称合并在行子树里。
//   - 英雄区单次传输状态行：进度「Sending x/y」与结果「Delivered N」是可读的文本节点。
//   - 触控目标：开关行与入口行高 ≥48dp（round3 实测 51.9dp）。
//
// 反证（卡上验收「至少一条删掉语义后变红」的第二条）：把 RuleSwitchRow 行本体的
// .toggleable(...) 删掉（退回 #1799 之前「行无语义 + Switch 自带 onCheckedChange」
// 的旧写法），本类开关行三条全红。

package com.hawkeyexb.ppass.ui.accessibility

import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.runtime.mutableStateOf
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.picked.PickedBatchSummary
import com.hawkeyexb.ppass.ui.BackupUiState
import com.hawkeyexb.ppass.ui.HomeScreen
import com.hawkeyexb.ppass.ui.SingleTransferStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HomeScreenSemanticsTest {

    private val density get() = testContext.resources.displayMetrics.density

    private val wifiOnly = mutableStateOf(true)
    private val notifyOnFailure = mutableStateOf(false)
    private val pickedBatch = mutableStateOf<PickedBatchSummary?>(null)

    private fun host(block: () -> Unit) {
        hostCompose(
            {
                HomeScreen(
                    storageName = "storage-pc",
                    state = BackupUiState.Idle,
                    onBackupNow = {},
                    wifiOnly = wifiOnly.value,
                    onWifiOnlyChange = { wifiOnly.value = it },
                    notifyOnFailure = notifyOnFailure.value,
                    onNotifyOnFailureChange = { notifyOnFailure.value = it },
                    autoBackupRuleOn = true,
                    pickedBatch = pickedBatch.value,
                )
            },
            block,
        )
    }

    /** 找「子树里合并了 [label] 文本」的 checkable 行——开关行整行一个语义节点的直接体现。 */
    private fun switchRow(label: String): AccessibilityNodeInfo {
        val deadline = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < deadline) {
            a11yRoot()?.let { root ->
                walk(root).firstOrNull { n -> n.isCheckable && walk(n).any { it.text?.toString() == label } }
                    ?.let { return it }
            }
            Thread.sleep(200)
        }
        throw AssertionError("没找到带名称「$label」的开关行；树：\n${describeTree()}")
    }

    /** 断言开关行的三条口径：checkable/checked、名称合并、行内 Switch 不单独暴露 checkable。 */
    private fun assertSwitchRow(labelRes: Int, expectedChecked: Boolean) {
        val label = testContext.getString(labelRes)
        val row = switchRow(label)
        assertTrue("开关行必须可点", row.isClickable)
        assertEquals("开关行 checked 必须随参数（整行报开合状态）", expectedChecked, row.isChecked)
        assertEquals(
            "行内 Switch 只画状态：行子树里只能有行自己一个 checkable 节点",
            1,
            walk(row).count { it.isCheckable },
        )
        val bounds = Rect()
        runCatching { row.getBoundsInScreen(bounds) }
        assertTrue(
            "开关行高 ${bounds.height() / density}dp 必须 ≥48dp（触控目标）",
            bounds.height() / density >= 48.0,
        )
    }

    /** 三个开关行：自动备份（开）、仅 Wi-Fi（开）、通知（关）——名称与开合状态都在整行一个节点上。 */
    @Test
    fun switch_rows_carry_name_and_checked_state_on_the_row() {
        host {
            assertSwitchRow(R.string.auto_backup_rule_label, expectedChecked = true)
            assertSwitchRow(R.string.setting_wifi_only, expectedChecked = true)
            assertSwitchRow(R.string.rule_notify, expectedChecked = false)
            saveTree("homescreen-rows.txt", a11yRoot())
        }
    }

    /** 点整行切开关：TalkBack 双击走的同一个 ACTION_CLICK， checked 翻转、状态回到行上。 */
    @Test
    fun switch_row_toggles_from_the_row_via_a11y_click() {
        host {
            val label = testContext.getString(R.string.rule_notify)
            val before = switchRow(label)
            assertFalse("点击前通知开关应为关", before.isChecked)
            assertTrue("ACTION_CLICK 必须被行接受", before.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            val deadline = System.currentTimeMillis() + 5_000
            var flipped = false
            while (System.currentTimeMillis() < deadline && !flipped) {
                flipped = switchRowOrNull(label)?.isChecked == true
                if (!flipped) Thread.sleep(200)
            }
            assertTrue("点整行后开关必须翻开（checked 翻转）", flipped)
            saveTree("homescreen-toggled.txt", a11yRoot())
        }
    }

    private fun switchRowOrNull(label: String): AccessibilityNodeInfo? {
        return try {
            a11yRoot()?.let { root ->
                walk(root).firstOrNull { n -> n.isCheckable && walk(n).any { it.text?.toString() == label } }
            }
        } catch (_: IllegalStateException) {
            null
        }
    }

    /** 单次入口两行：整行可点、带 Role.Button 的 a11y 体现、名称合并、不是勾选项、行高 ≥48dp。 */
    @Test
    fun single_entry_rows_are_clickable_buttons_with_names() {
        host {
            for (labelRes in intArrayOf(R.string.pick_from_photos_label, R.string.pick_from_files_label)) {
                val label = testContext.getString(labelRes)
                val textNode = awaitNode("单次入口行文本「$label」") { it.text?.toString() == label }
                val row = textNode.clickableSelfOrAncestor()
                    ?: throw AssertionError("入口行必须整行可点（$label）；树：\n${describeTree()}")
                assertFalse("入口行是按钮不是勾选项", row.isCheckable)
                val subtree = walk(row).toList()
                assertTrue(
                    "入口行要带 Role.Button 的 a11y 体现（className Button）",
                    subtree.any { it.className?.toString()?.endsWith("Button") == true },
                )
                val bounds = Rect()
                runCatching { row.getBoundsInScreen(bounds) }
                assertTrue(
                    "入口行高 ${bounds.height() / density}dp 必须 ≥48dp（触控目标）",
                    bounds.height() / density >= 48.0,
                )
            }
            saveTree("homescreen-single-entry.txt", a11yRoot())
        }
    }

    /** 英雄区状态行（进行中）：open>0 时报「Sending x/y」，与 round3「正在传 2/2」同口径。 */
    @Test
    fun hero_line_reads_single_transfer_progress() {
        heroLineTest(
            PickedBatchSummary(batchId = 1, total = 2, open = 1, delivered = 0, alreadyThere = 0, failed = 0),
        ) { line ->
            when (line) {
                is SingleTransferStatus.Line.Progress ->
                    testContext.getString(R.string.picked_progress, line.done, line.total)
                is SingleTransferStatus.Line.Result -> error("不该出结果句")
            }
        }
    }

    /** 英雄区状态行（已结算）：报「Delivered N」（failed=0 时没有后半句，与生产拼法一致）。 */
    @Test
    fun hero_line_reads_delivery_result() {
        heroLineTest(
            PickedBatchSummary(batchId = 1, total = 2, open = 0, delivered = 2, alreadyThere = 0, failed = 0),
        ) { line ->
            when (line) {
                is SingleTransferStatus.Line.Result ->
                    line.delivered?.let { testContext.getString(R.string.picked_result_delivered, it) } ?: ""
                is SingleTransferStatus.Line.Progress -> error("不该出进度句")
            }
        }
    }

    private fun heroLineTest(batch: PickedBatchSummary, expectedText: (SingleTransferStatus.Line) -> String) {
        pickedBatch.value = batch
        try {
            host {
                val line = SingleTransferStatus.heroLine(batch)
                    ?: throw AssertionError("heroLine(batch.total=${batch.total}) 必须非空")
                val expected = expectedText(line)
                awaitNode("英雄区状态行「$expected」") { it.text?.toString() == expected }
                saveTree("homescreen-hero.txt", a11yRoot())
            }
        } finally {
            pickedBatch.value = null
        }
    }
}
