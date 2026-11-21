package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.flow.InMemoryPickedStore
import com.hawkeyexb.ppass.backup.picked.NewPicked
import com.hawkeyexb.ppass.backup.picked.PickedBatchSummary
import com.hawkeyexb.ppass.backup.picked.PickedState
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
    fun settled_batch_shows_the_result_sentence() {
        assertEquals(
            SingleTransferStatus.Line.Result(delivered = 3, failed = 0),
            SingleTransferStatus.heroLine(batch(total = 3, delivered = 3, open = 0)),
        )
        // 电脑上已有的也算送达（2026-11-04 口径）。
        assertEquals(
            SingleTransferStatus.Line.Result(delivered = 3, failed = 0),
            SingleTransferStatus.heroLine(batch(total = 3, delivered = 1, alreadyThere = 2, open = 0)),
        )
        assertEquals(
            SingleTransferStatus.Line.Result(delivered = 2, failed = 1),
            SingleTransferStatus.heroLine(batch(total = 3, delivered = 2, failed = 1, open = 0)),
        )
        // 全部失败：没有送达半句，只有失败。
        assertEquals(
            SingleTransferStatus.Line.Result(delivered = null, failed = 2),
            SingleTransferStatus.heroLine(batch(total = 2, failed = 2, open = 0)),
        )
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

        // 全部结算后（没有未结束项）：出结果句（验收「没有未结束项时，再显示结算结果」）。
        (2L..5L).forEach { store.mark(it, PickedState.DELIVERED) }
        (6L..8L).forEach { store.mark(it, PickedState.ALREADY_THERE) }
        assertEquals(
            SingleTransferStatus.Line.Result(delivered = 7, failed = 0),
            SingleTransferStatus.heroLine(store.summary()),
        )
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

    // ── ② 源文本门禁 ──────────────────────────────────────────────

    private fun homeScreen() = File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()
    private fun decisionScreen() = File("src/main/java/com/hawkeyexb/ppass/ui/DecisionScreen.kt").readText()
    private fun mainActivity() = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()

    private fun group(source: String, marker: String): String? =
        Regex("(?s)// ── #1789 固定分组 ${marker}.*?(?=// ── #1789 固定分组|// ── #1789 固定分组结束)").find(source)?.value

    /** #1784：设置按「自动备份 / 单次传输 / 传输条件与通知」固定分组，组序固定。
     *  #1889：「更多」并入「传输条件与通知」组，不再单独成组，所以是三个分组。 */
    @Test
    fun settings_groups_are_fixed_and_in_order() {
        val source = homeScreen()
        val one = source.indexOf("// ── #1789 固定分组 1/3")
        val two = source.indexOf("// ── #1789 固定分组 2/3")
        val three = source.indexOf("// ── #1789 固定分组 3/3")
        assertTrue("三个固定分组都要在", one >= 0 && two >= 0 && three >= 0)
        assertTrue("组序：自动备份 → 单次传输 → 传输条件与通知（含「更多」）", one < two && two < three)
        assertFalse(
            "「更多」不再单独成组（不该再有自己的分组标记）",
            source.contains("// ── #1789 固定分组 4/"),
        )
        // 只判标记不够：把「更多」挪出第三组、顺手删掉标记注释，上面三条仍会绿（评审建议）。
        // 所以按第三组的**区间**判——它必须含「更多」，且只能有一张卡（Surface）。
        val third = group(source, "3/3")
        assertTrue("第三组必须可读", third != null)
        third.let { g ->
            assertTrue(
                "「更多」必须留在第三组内（挪出第三组这条就红）",
                g!!.contains("R.string.more_label"),
            )
            assertEquals(
                "第三组只能有一张卡——「更多」必须并进「通知」那张卡，不能自己另起一张",
                1,
                g.split("Surface(").size - 1,
            )
        }
    }

    /** #1784：单次传输下固定为「从相册选择」「从文件选择」，两行只发起选择，不显示进度、结果或最近一批。
     *  评审 Cy：逐行核对标签与动作的配对——把两行的 onClick 互换，「组里存在两个标签 + 两个动作」的写法仍会通过。 */
    @Test
    fun the_two_single_transfer_entries_only_initiate_selection() {
        val group = group(homeScreen(), "2/3")
        assertTrue(group != null)
        group.let { g ->
            // 按 CellRow 切开：每行入口的标签与 onClick 必须一一配对。
            val rows = g!!.split("CellRow(").drop(1)
            assertTrue("单次传输组固定两行入口", rows.size == 2)
            assertTrue(
                "「从相册选择」必须配发起相册选择（onPickPhotos）",
                rows.any { it.contains("R.string.pick_from_photos_label") && it.contains("onClick = onPickPhotos") },
            )
            assertTrue(
                "「从文件选择」必须配发起文件选择（onPickFiles）",
                rows.any { it.contains("R.string.pick_from_files_label") && it.contains("onClick = onPickFiles") },
            )
            assertFalse("入口行不显示进度 / 结果 / 最近一批", g.contains("pickedBatch"))
            assertFalse("入口行不带状态句", g.contains("picked_progress"))
        }
    }

    /** #1943：无独立系统照片选择器（如鸿蒙卓易通，PickVisualMedia 回退到 ACTION_OPEN_DOCUMENT）时，
     *  HomeScreen 分组 2/3 与 DecisionScreen 均隐藏「从相册选择」与分隔线、只保留「从文件选择」单一行，
     *  且 HomeScreen 单行模式下将分组无障碍 heading 移交给「从文件选择」（heading = !photoPickerAvailable）。 */
    @Test
    fun single_transfer_collapses_to_files_row_when_dedicated_photo_picker_is_unavailable() {
        val group = group(homeScreen(), "2/3")!!
        assertTrue(
            "HomeScreen 单次传输组必须按 SingleTransferFilePicker.hasDedicatedPhotoPicker 检测系统照片选择器",
            group.contains("val photoPickerAvailable = SingleTransferFilePicker.hasDedicatedPhotoPicker(LocalContext.current)"),
        )
        val homeGuarded = group.substringAfter("if (photoPickerAvailable) {", "").substringBefore("\n                }")
        assertTrue(
            "HomeScreen 的「从相册选择」与分隔线必须在 if (photoPickerAvailable) 分支内",
            homeGuarded.contains("R.string.pick_from_photos_label") &&
                homeGuarded.contains("HorizontalDivider(color = PPColor.Divider)"),
        )
        assertFalse(
            "HomeScreen 的「从文件选择」必须在条件分支外始终渲染",
            homeGuarded.contains("R.string.pick_from_files_label"),
        )
        val filesRow = group.substringAfter("R.string.pick_from_files_label")
        assertTrue(
            "HomeScreen 单行回退时「从文件选择」必须接管分组无障碍 heading（heading = !photoPickerAvailable）",
            filesRow.contains("heading = !photoPickerAvailable"),
        )

        val decision = decisionScreen()
        assertTrue(
            "DecisionScreen 必须默认按 SingleTransferFilePicker.hasDedicatedPhotoPicker(LocalContext.current) 检测",
            decision.contains("photoPickerAvailable: Boolean = SingleTransferFilePicker.hasDedicatedPhotoPicker(LocalContext.current)"),
        )
        val decisionGuarded = decision.substringAfter("if (photoPickerAvailable) {", "").substringBefore("\n                        }")
        assertTrue(
            "DecisionScreen 的「从相册选择」与分隔线必须在 if (photoPickerAvailable) 分支内",
            decisionGuarded.contains("R.string.pick_from_photos_label") &&
                decisionGuarded.contains("HorizontalDivider(color = PPColor.Divider)"),
        )
        assertFalse(
            "DecisionScreen 的「从文件选择」必须在条件分支外始终渲染",
            decisionGuarded.contains("R.string.pick_from_files_label"),
        )
    }

    /** #1784：设置页不再有「挑几张传」的进度/结果行——单次状态只在英雄区出现。 */
    @Test
    fun no_pick_progress_line_is_left_in_the_settings_card() {
        val source = homeScreen()
        assertFalse("旧「挑几张传」行值函数必须退场", source.contains("pickedBatchLine"))
        assertFalse("设置卡里不再消费最近一批", Regex("(?s)// ── #1789 固定分组 1/3.*?// ── #1789 固定分组结束")
            .find(source)!!.value.contains("pickedBatch"))
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
