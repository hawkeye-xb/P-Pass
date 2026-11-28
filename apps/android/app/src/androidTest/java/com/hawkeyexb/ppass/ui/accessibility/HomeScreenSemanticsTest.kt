// #1801 E2：设置页开关行、单次入口两行、英雄区单次传输状态行的读屏语义回归。
//
// 语义口径 = #1801 第三轮真机报告（.evidence/1801/round3/ 的 uiautomator dump）实测：
//   - 开关行（RuleSwitchRow）：整行一个语义节点——checkable + checked 报开合状态，
//     名称（自动备份 / 仅 Wi-Fi / 通知）合并在行子树里，行内 Switch 只画状态、
//     不单独暴露 checkable 子节点；点整行切换开关（TalkBack 双击走同一个 ACTION_CLICK）。
//   - 单次入口两行（CellRow 从相册选择 / 从文件选择）：整行可点（Role.Button 的
//     a11y 体现是 className Button），不是勾选项，名称合并在行子树里。
//   - 英雄区单次传输状态行：进度「Sending x/y」与结果「Delivered N」是可读的文本节点，
//     且带 liveRegion=polite——文案会变，TalkBack 变化后要主动报（#1801 阻断 1）。
//   - 分组标题：三个固定分组不贴标签（2026-09-14 用户拍板，组名即首行），首行标 heading
//     语义——a11y 边界的体现是 isHeading=true（#1801 阻断 1）。#1889 起「更多」并入「通知」
//     所在组，不再是分组首行，也就没有 heading 语义。
//   - 触控目标：开关行与入口行高 ≥48dp（round3 实测 51.9dp）。
//
// 反证（卡上验收「至少一条删掉语义后变红」的第二条）：把 RuleSwitchRow 行本体的
// .toggleable(...) 删掉（退回 #1799 之前「行无语义 + Switch 自带 onCheckedChange」
// 的旧写法），本类开关行三条全红；heading/liveRegion 两条各自把生产里的
// .semantics { heading() } / { liveRegion = … } 删掉也红（group_first_rows… /
// hero_status_line_announces…）。

package com.hawkeyexb.ppass.ui.accessibility

import android.graphics.Rect
import android.os.Build
import android.view.View
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

    /** 分组标题：第 1 组紧跟英雄卡、首行「自动备份」带 heading 语义；第 2、3 组由独立分组标题（单次手动传 / 偏好与更多）承载 heading 语义（#2082）。 */
    @Test
    fun group_first_rows_carry_heading_semantics() {
        host {
            // 语言随宿主 App；按资源 id 取当前语言的组名文本。
            val firstGroupRow = testContext.getString(R.string.auto_backup_rule_label)
            val row = awaitNode("第 1 组首行文本「$firstGroupRow」") { it.text?.toString() == firstGroupRow }
                .clickableSelfOrAncestor()
                ?: throw AssertionError("分组首行必须可点（$firstGroupRow）；树：\n${describeTree()}")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                assertTrue("第 1 组首行「$firstGroupRow」必须带 heading 语义", row.isHeading)
            }
            for (headerRes in intArrayOf(
                R.string.settings_section_single_transfer,
                R.string.settings_section_preferences,
            )) {
                val label = testContext.getString(headerRes)
                val headerNode = awaitNode("分组标题「$label」") { it.text?.toString() == label }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    assertTrue(
                        "分组标题「$label」必须带 heading 语义（TalkBack 按标题在分组间导航）",
                        headerNode.isHeading,
                    )
                }
            }
            saveTree("homescreen-headings.txt", a11yRoot())
        }
    }

    /** #1889：设置页「更多」并入「通知」所在的那一组——不再单独分组。
     *  两件事一起判：① 它不再是分组首行（不带 heading 语义，撤掉生产改动这条就红）；
     *  ② 它紧跟在「通知」下面、中间只有一条分隔线，不是隔了 18dp 组间距的另一张卡。
     *  行序与间距在真机上是分组的唯一可见边界（组内不贴 section 标签，2026-09-14 用户拍板）。 */
    @Test
    fun more_row_joins_the_notify_group() {
        host {
            val notifyLabel = testContext.getString(R.string.rule_notify)
            val moreLabel = testContext.getString(R.string.more_label)
            val notifyRow = awaitNode("「通知」开关行文本") { it.text?.toString() == notifyLabel }
                .checkableSelfOrAncestor()
                ?: throw AssertionError("「通知」必须是开关行；树：\n${describeTree()}")
            val moreRow = awaitNode("「更多」行文本") { it.text?.toString() == moreLabel }
                .clickableSelfOrAncestor()
                ?: throw AssertionError("「更多」必须整行可点；树：\n${describeTree()}")
            val notifyBounds = Rect().also { notifyRow.getBoundsInScreen(it) }
            val moreBounds = Rect().also { moreRow.getBoundsInScreen(it) }
            assertTrue(
                "「更多」必须排在「通知」下面（并入同一组）",
                moreBounds.top >= notifyBounds.bottom,
            )
            val gapDp = (moreBounds.top - notifyBounds.bottom) / density
            assertTrue(
                "「更多」与「通知」之间只隔一条分隔线（实测 ${gapDp}dp），不是隔了组间距的另一张卡",
                gapDp <= 12.0,
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                assertFalse(
                    "「更多」已并入「通知」所在组，不再是分组首行（不该带 heading 语义）",
                    moreRow.isHeading,
                )
            }
            saveTree("homescreen-more-group.txt", a11yRoot())
        }
    }

    /** 按文本点一个整行入口（TalkBack 双击走同一个 ACTION_CLICK）。 */
    private fun clickByLabel(label: String) {
        val target = awaitNode("「$label」可点节点") {
            it.text?.toString() == label || it.contentDescription?.toString() == label
        }.clickableSelfOrAncestor()
            ?: throw AssertionError("「$label」必须整行可点；树：\n${describeTree()}")
        assertTrue("ACTION_CLICK 必须被「$label」接受", target.performAction(AccessibilityNodeInfo.ACTION_CLICK))
    }

    /** 等一个 heading 语义的标题节点：按文本找，API>=P 时同时要求 isHeading，从而与
     *  「同文本但未标 heading 的入口行」（如首页「更多」行）区分开，等的是二级页页标题。 */
    private fun awaitHeading(label: String): AccessibilityNodeInfo =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            awaitNode("标题（heading）「$label」") { it.text?.toString() == label && it.isHeading }
        } else {
            awaitNode("标题「$label」") { it.text?.toString() == label }
        }

    /** #1888：首页「更多」二级页的 24sp 页标题必须带 heading 语义（TalkBack 按标题导航直达本页，
     *  与 BucketScreen 页标题同款，WCAG 2.2 AA 2.4.1 Section Headings）。
     *  反证：撤掉生产里 MorePage 标题的 `.semantics { heading() }`，本用例超时变红。 */
    @Test
    fun more_page_title_carries_heading_semantics() {
        host {
            clickByLabel(testContext.getString(R.string.more_label))
            val title = awaitHeading(testContext.getString(R.string.more_label))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                assertTrue("「更多」二级页标题必须带 heading 语义", title.isHeading)
            }
            saveTree("homescreen-more-title.txt", a11yRoot())
        }
    }

    /** #1888：从「更多」进「存储电脑」详情页，其 24sp 页标题必须带 heading 语义。
     *  反证：撤掉 StorageComputerDetail 标题的 `.semantics { heading() }`，本用例超时变红。 */
    @Test
    fun storage_detail_title_carries_heading_semantics() {
        host {
            clickByLabel(testContext.getString(R.string.more_label))
            awaitHeading(testContext.getString(R.string.more_label))
            clickByLabel(testContext.getString(R.string.storage_computer))
            val title = awaitHeading(testContext.getString(R.string.storage_computer))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                assertTrue("「存储电脑」详情页标题必须带 heading 语义", title.isHeading)
            }
            saveTree("homescreen-storage-title.txt", a11yRoot())
        }
    }

    /** #1888：英雄区主状态行（idleLine）会随状态变化（等待原因/空闲裁决文案），必须 liveRegion=polite——
     *  TalkBack 在变化后主动播报一句。默认 host（Idle + 自动备份开 + 仅 Wi-Fi）下主状态行就是
     *  `idle_auto_hint`；它是本屏该状态下唯一的 polite 区域（单次传输行此时不渲染）。
     *  反证：撤掉生产里 idleLine Text 的 `.semantics { liveRegion = LiveRegionMode.Polite }`，本用例变红。 */
    @Test
    fun hero_idle_line_announces_via_polite_live_region() {
        host {
            val expected = testContext.getString(R.string.idle_auto_hint)
            val node = awaitNode("英雄区主状态行「$expected」") { it.text?.toString() == expected }
            assertEquals(
                "英雄区主状态行会随状态变化，必须 liveRegion=polite（TalkBack 变化后主动播报）",
                View.ACCESSIBILITY_LIVE_REGION_POLITE,
                node.liveRegion,
            )
            saveTree("homescreen-idle-line.txt", a11yRoot())
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

    /** 英雄区状态行（有失败）：部分送达+部分失败也只报失败句，不再拼送达张数（#1459）。 */
    @Test
    fun hero_line_reads_failure_result_only() {
        heroLineTest(
            PickedBatchSummary(batchId = 1, total = 2, open = 0, delivered = 1, alreadyThere = 0, failed = 1),
        ) { line ->
            when (line) {
                is SingleTransferStatus.Line.Result ->
                    testContext.getString(R.string.picked_result_failed, line.failed)
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
                val node = awaitNode("英雄区状态行「$expected」") { it.text?.toString() == expected }
                assertEquals(
                    "英雄区单次传输状态行会变文案，必须 liveRegion=polite（TalkBack 变化后主动播报）",
                    View.ACCESSIBILITY_LIVE_REGION_POLITE,
                    node.liveRegion,
                )
                saveTree("homescreen-hero.txt", a11yRoot())
            }
        } finally {
            pickedBatch.value = null
        }
    }
}
