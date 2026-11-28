package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.flow.InMemoryPickedStore
import com.hawkeyexb.ppass.backup.picked.NewPicked
import com.hawkeyexb.ppass.backup.picked.PickedBatchSummary
import com.hawkeyexb.ppass.backup.picked.PickedState
import com.hawkeyexb.ppass.runPickedEnqueue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

private fun newPicked(n: Int) = NewPicked(
    uri = "content://test/$n",
    fileName = "$n.jpg",
    mimeType = "image/jpeg",
    sizeBytes = 1L,
    captureAtMs = 0L,
)

/**
 * #1789（父卡 #1784）：设置固定分组、两个单次入口只发起选择、单次状态只在英雄区出现。
 *
 * 两件能测的事（HomeScreen 是 Compose，本仓没有 Robolectric，同 MOB94 的分工）：
 * ① 单次传输状态句的判据本体（[SingleTransferStatus.heroLine]，纯函数）；
 * ② 源文本门禁——固定分组的组序、入口行不带进度/结果、英雄区接线、选择时清理已结束记录。
 * ②是源文本，只能证明写法，证明不了效果；真机表现随版本验收台账验。
 */
class SingleTransferStatusTest {

    private fun batch(
        total: Int,
        delivered: Int = 0,
        alreadyThere: Int = 0,
        failed: Int = 0,
        open: Int = total - delivered - alreadyThere - failed,
    ) = PickedBatchSummary(batchId = 1, total = total, open = open, delivered = delivered, alreadyThere = alreadyThere, failed = failed)

    // ── ① 判据本体 ────────────────────────────────────────────────

    @Test
    fun no_batch_means_no_hero_line() {
        assertNull(SingleTransferStatus.heroLine(null))
    }

    @Test
    fun open_items_show_progress_counting_the_one_in_flight() {
        // #1272 同口径：正在传的那一张算进度（settled + 1）。
        assertEquals(SingleTransferStatus.Line.Progress(done = 3, total = 5), SingleTransferStatus.heroLine(batch(total = 5, delivered = 2)))
        assertEquals(SingleTransferStatus.Line.Progress(done = 1, total = 5), SingleTransferStatus.heroLine(batch(total = 5)))
    }

    @Test
    fun settled_batch_hides_delivered_and_only_shows_failures() {
        // #1459：全部送达（含电脑上已有）后不再显示结果句。
        assertNull(SingleTransferStatus.heroLine(batch(total = 3, delivered = 3, open = 0)))
        assertNull(SingleTransferStatus.heroLine(batch(total = 3, delivered = 1, alreadyThere = 2, open = 0)))
        // 部分送达 + 部分失败：只显示失败张数，不再拼「送达 N 张」。
        val partialFail = SingleTransferStatus.heroLine(batch(total = 3, delivered = 2, failed = 1, open = 0))
        assertTrue(partialFail is SingleTransferStatus.Line.Result)
        assertEquals(1, (partialFail as SingleTransferStatus.Line.Result).failed)
        assertFalse("结果句不再携带送达计数", partialFail.toString().contains("delivered"))
        // 全部失败：同样只产出失败张数。
        val allFail = SingleTransferStatus.heroLine(batch(total = 2, failed = 2, open = 0))
        assertTrue(allFail is SingleTransferStatus.Line.Result)
        assertEquals(2, (allFail as SingleTransferStatus.Line.Result).failed)
        assertFalse("结果句不再携带送达计数", allFail.toString().contains("delivered"))
    }

    @Test
    fun interrupted_process_does_not_count_as_failure() {
        // #1789 验收 4：进程被杀时没传完的行留在 pending/transferring——它们仍是 open，
        // 英雄区出的是进度句，绝不是把没传完的张数记进 failed。
        val killed = batch(total = 12, delivered = 9, open = 3)
        assertEquals(SingleTransferStatus.Line.Progress(done = 10, total = 12), SingleTransferStatus.heroLine(killed))
        assertEquals(0, killed.failed)
    }

    /** #1789 验收 3（评审 Ad 判红）：上一批还在传时再挑新一批，`summary()` 必须并成两批的汇总——
     *  `latestBatch()` 只报新一批（对照），旧批的未结束项不能在英雄区消失。撤销修复（summary 改回按
     *  MAX(batch_id) 过滤、或消费方改回 latestBatch）任一条都变红。
     *  评审（#1878 建议 2）：按真实入口的顺序走——MainActivity 两个入口都是 enqueue 成功后先
     *  clearSettled() 再读 summary()（评审 AP），上一批已送达的行此时被清掉：上一批剩 4 个未结束
     *  （1 在传 3 排队）+ 新批 3 = 7 行全未结束，英雄区出「正在传 1/7」，不是 2/8；
     *  「已送达的不丢」由 clearSettled 之前的对照断言锁住。 */
    @Test
    fun summary_spans_all_batches_while_the_previous_one_is_still_in_flight() {
        val store = InMemoryPickedStore()
        val first = store.addBatch((1..5).map(::newPicked))
        assertTrue(first > 0)
        // 上一批：1 送达、1 在传、3 还在排队。
        store.mark(1, PickedState.DELIVERED)
        store.mark(2, PickedState.TRANSFERRING)
        // 用户又挑了 3 张（同 #1784 验收 3：相册选 2 项后文件选 3 项）。
        val second = store.addBatch((6..8).map(::newPicked))
        assertTrue(second > first)
        // 入口同款时序（MainActivity.kt 两个单次入口）：登记成功 → 清已结算 → 读汇总。
        // 上一批已送达的 1 行随这次选择被清掉；未结束的 4 行原样保留。
        store.clearSettled()

        val all = store.summary()
        assertEquals("聚合覆盖两批：上一批 4 个未结束 + 新批 3 = 7 行", 7, all!!.total)
        assertEquals(7, all.open)
        assertEquals("已送达行已随入口清理", 0, all.delivered)
        assertEquals(
            "英雄区出进度句：正在传 1/7（在传那张算进度，与单批同口径）",
            SingleTransferStatus.Line.Progress(done = 1, total = 7),
            SingleTransferStatus.heroLine(all),
        )
        // 对照：latestBatch 的单批口径正是缺陷本体——只报新一批 3 行，旧批 4 个未结束在英雄区消失。
        assertEquals(3, store.latestBatch()!!.total)

        // 全部送达后（无失败）：英雄区不再显示结果句（#1459）。
        (2L..5L).forEach { store.mark(it, PickedState.DELIVERED) }
        (6L..8L).forEach { store.mark(it, PickedState.ALREADY_THERE) }
        assertNull(SingleTransferStatus.heroLine(store.summary()))

        // 只要有失败项：结算后只产出失败张数。
        store.mark(8L, PickedState.FAILED)
        val withFailure = SingleTransferStatus.heroLine(store.summary())
        assertTrue(withFailure is SingleTransferStatus.Line.Result)
        assertEquals(1, (withFailure as SingleTransferStatus.Line.Result).failed)
    }

    /** 设置入口、轮询及决定页的共用回调都读跨批次汇总，不能只展示最后一批。 */
    @Test
    fun the_hero_feed_reads_the_cross_batch_summary_not_the_latest_batch() {
        val main = mainActivity()
        assertFalse("英雄区不得只读最后一批", main.contains(".latestBatch()"))
        val summary = "PickedUploads.store(context).summary()"
        val photos = main.substringAfter("val pickPhotosLauncher").substringBefore("val filePickLauncher")
        val files = main.substringAfter("val filePickLauncher").substringBefore("androidx.compose.runtime.LaunchedEffect")
        val decision = main.substringAfter("val decisionPickLauncherResult:").substringBefore("val launchDecisionFile:")
        assertTrue("设置相册入口刷新跨批次汇总", photos.contains(summary))
        assertTrue("设置文件入口刷新跨批次汇总", files.contains(summary))
        assertTrue("决定页共用的回调刷新跨批次汇总", decision.contains(summary))
        assertTrue("决定页相册选择使用共用回调", decision.contains("onResult = decisionPickLauncherResult"))
        assertTrue("决定页文件选择使用共用回调", decision.contains("decisionPickLauncherResult(if (result.resultCode"))
        val polling = main.substringAfter("androidx.compose.runtime.LaunchedEffect(Unit) {").substringBefore("val decisionPickLauncherResult:")
        assertTrue("轮询刷新跨批次汇总", polling.contains(summary))
        val store = File("src/main/java/com/hawkeyexb/ppass/backup/picked/PickedStore.kt").readText()
        // 评审：按语句边界切出 summary() 的实现段整体断言——之前的负向正则 [^"'] 跨不过 SQL 里的
        // 'pending' 这类引号，永远匹配不上，反证防线失效；这里改回单批口径（SQL 加 WHERE）必红。
        val summarySql = store.substringAfter("override fun summary()", "").substringBefore("override fun clearSettled()")
        assertTrue("summary() 实现必须存在（含 FROM picked 的全表查询）", summarySql.contains("FROM picked"))
        assertTrue(
            "summary() 必须是全表聚合，不许再按 MAX(batch_id) 过滤（改回去本条红）",
            !summarySql.contains("WHERE"),
        )
    }

    // ── #1864 单次传输入队失败：给用户提示，不静默 ─────────────────

    /** #1864：用户选了东西而 PickedUploads.enqueue 抛异常——弹出既有 command_failed 提示，
     *  不进成功路径（不 clearSettled、不刷新汇总、不唤醒传输循环），异常原样交给调用方记日志。 */
    @Test
    fun picked_enqueue_exception_notifies_the_user_and_skips_the_success_path() {
        var success = 0
        val notices = mutableListOf<Int>()
        val failures = mutableListOf<Throwable?>()
        val ok = runPickedEnqueue(
            uriCount = 2,
            enqueue = { throw IllegalStateException("disk full") },
            onSuccess = { success++ },
            onFailure = { failures.add(it) },
            notifyFailure = { notices.add(it) },
        )
        assertFalse("入队抛异常不算登记成功", ok)
        assertEquals("失败不进成功路径", 0, success)
        assertEquals("失败只报一次既有提示", listOf(R.string.command_failed), notices)
        assertTrue("异常原样交给调用方记日志", failures.single() is IllegalStateException)
    }

    /** #1864：enqueue 正常返回但一个都没登记上（返回 0）——同样提示，同样不进成功路径。 */
    @Test
    fun picked_enqueue_registering_nothing_notifies_the_user() {
        var success = 0
        val notices = mutableListOf<Int>()
        val failures = mutableListOf<Throwable?>()
        val ok = runPickedEnqueue(
            uriCount = 3,
            enqueue = { 0 },
            onSuccess = { success++ },
            onFailure = { failures.add(it) },
            notifyFailure = { notices.add(it) },
        )
        assertFalse(ok)
        assertEquals(0, success)
        assertEquals(listOf(R.string.command_failed), notices)
        assertNull("没有异常时 onFailure 收到 null", failures.single())
    }

    /** #1864：登记成功——进成功路径，不弹失败提示。反证：去掉 notifyFailure 调用只影响失败分支。 */
    @Test
    fun picked_enqueue_success_runs_the_success_path_without_a_notice() {
        var enqueued = 0
        var success = 0
        var notices = 0
        val ok = runPickedEnqueue(
            uriCount = 4,
            enqueue = { enqueued++; 3 },
            onSuccess = { success++ },
            onFailure = { throw AssertionError("成功路径不应走失败回调") },
            notifyFailure = { notices++ },
        )
        assertTrue(ok)
        assertEquals(1, enqueued)
        assertEquals(1, success)
        assertEquals("成功时不弹失败提示", 0, notices)
    }

    /** #1864：用户取消选择（空列表）不是错误——不登记、不提示，也不当成失败日志。 */
    @Test
    fun cancelling_the_picker_is_not_an_error() {
        var enqueued = 0
        var success = 0
        var notices = 0
        var failures = 0
        val ok = runPickedEnqueue(
            uriCount = 0,
            enqueue = { enqueued++; 1 },
            onSuccess = { success++ },
            onFailure = { failures++ },
            notifyFailure = { notices++ },
        )
        assertFalse(ok)
        assertEquals("取消时不入队", 0, enqueued)
        assertEquals(0, success)
        assertEquals("取消时不弹错误提示", 0, notices)
        assertEquals(0, failures)
    }

    /** #1864：首页相册、首页文件、决定页三处单次入口都接到失败反馈链路（源文本门禁，只能证明写法）。 */
    @Test
    fun all_three_single_transfer_entries_surface_enqueue_failures_to_the_user() {
        val main = mainActivity()
        assertTrue(
            "Snackbar 宿主必须在单次选择回调之前声明（回调里要用同一个 hostState）",
            main.indexOf("val snackbarHostState") in 0 until main.indexOf("val pickPhotosLauncher"),
        )
        val photos = main.substringAfter("val pickPhotosLauncher").substringBefore("val filePickLauncher")
        val files = main.substringAfter("val filePickLauncher").substringBefore("androidx.compose.runtime.LaunchedEffect")
        val decision = main.substringAfter("val decisionPickLauncherResult:").substringBefore("val launchDecisionFile:")
        listOf("首页相册" to photos, "首页文件" to files, "决定页" to decision).forEach { (name, block) ->
            assertTrue("${name}入口必须走 runPickedEnqueue 的统一失败反馈", block.contains("runPickedEnqueue("))
            assertTrue("${name}入口失败要弹 Snackbar", block.contains("showSnackbar"))
        }
        assertTrue(
            "决定页入队失败必须解锁按钮，留在决定页重试",
            decision.contains("decisionLock.unlock()"),
        )
        val hostAt = main.indexOf("SnackbarHost(")
        assertTrue(
            "Snackbar 宿主挂在页面最外层（在 when (val s = screen) 之外），首页与决定页都能看到",
            main.indexOf("when (val s = screen)") in 0 until hostAt &&
                main.substring(hostAt).contains("hostState = snackbarHostState"),
        )
    }

    // ── ② 源文本门禁 ──────────────────────────────────────────────

    private fun homeScreen() = File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()
    private fun decisionScreen() = File("src/main/java/com/hawkeyexb/ppass/ui/DecisionScreen.kt").readText()
    private fun mainActivity() = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()

    @Test
    fun settings_groups_are_fixed_and_in_order() {
        assertEquals(
            listOf(SettingsLayout.Group.BACKUP, SettingsLayout.Group.SELECTION, SettingsLayout.Group.CONDITIONS),
            SettingsLayout.sections,
        )
        assertEquals(null, SettingsLayout.Group.BACKUP.headerRes)
        assertEquals(R.string.settings_section_single_transfer, SettingsLayout.Group.SELECTION.headerRes)
        assertEquals(R.string.settings_section_preferences, SettingsLayout.Group.CONDITIONS.headerRes)
        assertEquals(
            listOf(SettingsLayout.Condition.WIFI, SettingsLayout.Condition.NOTIFICATIONS, SettingsLayout.Condition.MORE),
            SettingsLayout.conditionRows,
        )
    }

    @Test
    fun the_two_single_transfer_entries_only_initiate_selection() {
        val requested = mutableListOf<String>()
        val entries = SettingsLayout.selectionRows(photoPickerAvailable = true)
        assertEquals(
            listOf(R.string.pick_from_photos_label, R.string.pick_from_files_label),
            entries.map { it.labelRes },
        )
        entries[0].request(photos = { requested += "photos" }, files = { requested += "files" })
        assertEquals(listOf("photos"), requested)
        entries[1].request(photos = { requested += "photos" }, files = { requested += "files" })
        assertEquals(listOf("photos", "files"), requested)
    }

    @Test
    fun single_transfer_collapses_to_files_row_when_dedicated_photo_picker_is_unavailable() {
        val withPicker = SettingsLayout.selectionRows(photoPickerAvailable = true)
        assertEquals(listOf(SettingsLayout.Selection.PHOTOS, SettingsLayout.Selection.FILES), withPicker)

        val withoutPicker = SettingsLayout.selectionRows(photoPickerAvailable = false)
        assertEquals(listOf(SettingsLayout.Selection.FILES), withoutPicker)
    }

    @Test
    fun no_pick_progress_line_is_left_in_the_settings_card() {
        assertEquals(listOf(SettingsLayout.Backup.RULE), SettingsLayout.backupRows(autoRule = false))
        assertEquals(
            listOf(SettingsLayout.Backup.RULE, SettingsLayout.Backup.SCOPE, SettingsLayout.Backup.BACKGROUND),
            SettingsLayout.backupRows(autoRule = true),
        )
    }

    /** #1784：英雄区读取手选状态（进度 / 结果），自动与单次状态统一由英雄区展示。 */
    @Test
    fun hero_shows_the_single_transfer_status_line() {
        val source = homeScreen()
        assertTrue("英雄区消费单次传输投影", source.contains("SingleTransferStatus.heroLine(pickedBatch)"))
    }

    /** #1784：已结束记录随下一次选择清理（评审 B1：各自回调内断言顺序，不靠全文包含；
     *  评审 AP：清理在**登记成功之后**——登记失败时不得动原状态，所以顺序是 enqueue → clearSettled）。 */
    @Test
    fun picking_again_clears_the_settled_records_first() {
        val main = mainActivity()
        val photoPick = main.substringAfter("pickPhotosLauncher", "").substringBefore("decisionPickLauncher")
        assertTrue("相册入口登记后清理已结束记录", photoPick.contains("clearSettled()"))
        val clearInPhoto = photoPick.indexOf("store.clearSettled()")
        val enqueueInPhoto = photoPick.indexOf("PickedUploads.enqueue(context, uris)")
        assertTrue("相册入口必须先登记新一批（成功后）、再清理已结算行", clearInPhoto > enqueueInPhoto && enqueueInPhoto >= 0)
        // 文件入口的回调块截到轮询 LaunchedEffect 为止，不把后面无关回调里的 clearSettled 也算进来。
        val filePick = main.substringAfter("filePickLauncher", "").substringBefore("androidx.compose.runtime.LaunchedEffect")
        assertTrue(
            "文件入口解析复用 SingleTransferFilePicker（评审：SAF 多选/单选边界只写一处）",
            filePick.contains("SingleTransferFilePicker.urisFromResult"),
        )
        assertTrue("文件入口登记后清理已结束记录", filePick.contains("clearSettled()"))
        val clearInFile = filePick.indexOf("store.clearSettled()")
        val enqueueInFile = filePick.indexOf("PickedUploads.enqueue(context, uris)")
        assertTrue("文件入口必须先登记新一批（成功后）、再清理已结算行", clearInFile > enqueueInFile && enqueueInFile >= 0)
        // 入口存在：HomeScreen 的「从文件选择」行确实从 SingleTransferFilePicker 拿 intent。
        assertTrue("文件入口存在", main.contains("filePickLauncher.launch(com.hawkeyexb.ppass.ui.SingleTransferFilePicker.intent())"))
    }

    /** #1784：条件行只在原组内显隐、尊重系统减少动态效果——状态变化直接呈现，不加过渡动画。 */
    @Test
    fun settings_and_hero_render_state_directly_without_transitions() {
        val source = homeScreen()
        for (api in listOf("AnimatedVisibility", "animateContentSize", "animateFloatAsState", "animateColorAsState", "animateDpAsState", "Crossfade", "AnimatedContent")) {
            assertFalse("英雄区与设置组直接呈现状态，不使用 $api（尊重系统减少动态效果）", source.contains(api))
        }
    }

    /**
     * #1799：设置组里可点的行给标准 button 语义（role = Role.Button，TalkBack 报「按钮」）；
     * 账目行（onClick = null）保持不可点——MOB-100：有雪佛龙却点不动比没有更坏，这条防线不许松。
     * 行高例外（UI-13：不套 ListItem 的量出理由）原样保留。
     * 反证：可点行退回无 role 的 clickable、或把 clickable 提出条件分支（无条件挂上、回调传空），
     * 第一条红；箭头或间距改成无条件显示，第二、三条红。
     * #1881：CellRow 改按内容量宽后，尾部守卫统一用局部 `clickable = onClick != null`（remember 键也含它）；
     * 「›」在并排与堆叠两个分支都要守——堆叠分支曾漏守卫（评审阻断项）。改断言保意图，不删测试。
     */
    @Test
    fun clickable_rows_carry_button_semantics_and_accounts_stay_inert() {
        val row = homeScreen().substringAfter("internal fun CellRow(").substringBefore("\n}\n")
        // #1879 评审：断言拆开、各自可判红——role 挂在「onClick != null」守卫分支里，
        // 不是「clickable 无条件挂上、回调传空」的假不可点。
        assertTrue(
            "可点行必须带 role = Role.Button，且 clickable 只在 onClick != null 分支里",
            row.contains(".let { if (onClick != null) it.clickable(role = Role.Button, onClick = onClick) else it }"),
        )
        assertTrue(
            "账目行不画右侧间距（value 行的 Spacer 由可点性守卫）",
            row.contains("if (clickable) Spacer(Modifier.width(4.dp))"),
        )
        assertEquals(
            "「›」只在可点时画，且并排与堆叠两个分支都守（#1881：堆叠分支曾漏守卫）",
            2,
            Regex(Regex.escape("if (clickable) Text(\"›\"")).findAll(row).count(),
        )
    }
}
