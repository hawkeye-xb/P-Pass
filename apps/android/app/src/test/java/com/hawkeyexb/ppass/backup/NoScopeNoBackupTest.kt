// MOB-40（2026-08-26 真机实锤，L0）：**没选过备份范围 = 一张都不备。**
//
// 验收人原话：「我就选择了一个 11 张的相册，你给我同步几百个？又出现 bug 了，
// 我都不用往下测试了！」
//
// logcat 铁证（全新安装 0.4.0-test.6）：
//   15:53:05  安装（新 uid → SharedPreferences 全空 → 范围 = null）
//   15:54:14  work d9b69afe  scanning 254/254   ← 整库，用户还没进选相册页
//   15:55:13  CANCELLED_BY_APP(1)              ← 用户看到不对，手动按暂停
//   15:55:26  auto backup: offered=11 pushed=11 ← 选完相册后的正确一轮
//
// 根因是一条语义：`selectedBucketIds() == null` 表示「**从未选过**」，
// 全链路却把它解释成「**全量备份**」（T6 给升级用户留的兼容）。
// 「我还不知道你要备什么」不等于「那就全备」。
package com.hawkeyexb.ppass.backup

import androidx.work.Data
import androidx.work.WorkInfo
import com.hawkeyexb.ppass.ui.BackupUiState
import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NoScopeNoBackupTest {

    /** 剥注释行：正向 contains 会被「把那行注释掉」骗过（本仓既有惯例）。 */
    private fun codeOf(rel: String): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/$rel")
            .readText().lines()
            .filterNot {
                val t = it.trimStart()
                t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
            }
            .joinToString("\n")
    }

    private fun info(state: WorkInfo.State, output: Data) = WorkInfo(
        id = UUID.randomUUID(),
        state = state,
        tags = setOf(BackupWorker::class.java.name),
        outputData = output,
        progress = Data.EMPTY,
    )

    // ── ① 闸门在管线咽喉，且在扫描**之前** ──

    @Test
    fun a_null_scope_never_reaches_the_scanner() {
        // 本卡的本体判据。钉的是**顺序**这个不变量：读到 null 就返回，
        // 位置必须在 scanSince 之前——那才是「一张都不备」的物理保证。
        // 具体走 `if (bucketIds == null)` 还是别的写法是实现细节，所以只
        // 要求「早退语句出现在扫描调用之前」。
        val worker = codeOf("backup/BackupWorker.kt")
        val gate = worker.indexOf("KEY_NO_SCOPE to true")
        val scan = worker.indexOf("scanner.scanSince(")
        assertTrue("源码锚点已消失：KEY_NO_SCOPE to true", gate >= 0)
        assertTrue("源码锚点已消失：scanner.scanSince(", scan >= 0)
        assertTrue(
            "没选过范围的早退必须在扫描之前——否则整库已经被查出来了",
            gate < scan,
        )
    }

    @Test
    fun the_gate_lives_in_the_pipeline_not_in_the_triggers() {
        // 备份有五条触发通道，每条各加一道门控 = 把同一个判断写五遍。
        // MOB-33/34/35/38 四个 bug 全是「漏接一处」，那个形状不能再复制。
        // 判据：五个 trigger 函数体内一个都不许读范围。
        val worker = codeOf("backup/BackupWorker.kt")
        for (fn in listOf(
            "fun triggerUserPresentBackup(",
            "fun triggerManualBackup(",
            "fun triggerProcessStartCatchup(",
            "fun scheduleAutoBackup(",
            "fun rescheduleAutoBackup(",
        )) {
            val at = worker.indexOf(fn)
            assertTrue("源码锚点已消失：$fn", at >= 0)
            val body = worker.substring(at, minOf(at + 700, worker.length))
            assertTrue(
                "$fn 里不许自己读备份范围——闸门只有管线那一道（MOB-40）",
                !body.contains("selectedBucketIds"),
            )
        }
    }

    // ── ② 界面不许把「没选过」说成「都存好了」 ──

    @Test
    fun the_ui_never_claims_everything_is_safe_when_no_scope_was_ever_picked() {
        assertEquals(
            "没选过范围的那一轮必须渲染成「没有可备份的相册」，不是「照片都存好了」",
            BackupUiState.NoAlbums,
            uiStateOf(listOf(info(
                WorkInfo.State.SUCCEEDED,
                Data.Builder().putBoolean(KEY_NO_SCOPE, true).build(),
            ))),
        )
    }

    @Test
    fun an_empty_scope_still_renders_the_same_way() {
        // 空集（用户把相册全取消）与 null（从未选过）**行为相同、盖戳不同**。
        // 文案共用是刻意的：对用户是同一件事（去选相册）。这条确认 FIX-T6
        // 的老行为没被本卡改坏。
        assertEquals(
            BackupUiState.NoAlbums,
            uiStateOf(listOf(info(
                WorkInfo.State.SUCCEEDED,
                Data.Builder().putBoolean(KEY_NO_ALBUMS, true).build(),
            ))),
        )
    }

    @Test
    fun the_two_stamps_are_distinct_keys() {
        // 盖戳分开的全部意义就是诊断时能区分这两种。同一个 key 就白做了。
        assertTrue("两个戳必须是不同的 key", KEY_NO_SCOPE != KEY_NO_ALBUMS)
    }

    // ── ③ 三元组不许替 worker 编一个待备份数 ──

    @Test
    fun the_triplet_stays_hidden_until_a_scope_is_picked() {
        // `MediaScanner.countAll(null)` 是**全库**口径，而 worker 现在一张都
        // 不传。两边一拼，状态条会走 `Pending(254)`——挂着一句「还有 254 张
        // 待备份」永不收敛，正是 MOB-40 要杀的同一类谎话。
        //
        // 出口与 DOG-01c/d 的「媒体查询失败 → 三元组不显示」同一个：还没告诉
        // 我要备什么，我就报不出待备份张数。resolver 传 null 会让 MediaScanner
        // 的 checkNotNull 抛出、被 Throwable 级兜底吞掉，所以这里只能验证
        // 「null 范围不产出三元组」这一半；范围检查在源码上排在 resolver 之后，
        // 由下面那条位置断言守住。
        val worker = codeOf("backup/BackupUiStateHolder.kt")
        val at = worker.indexOf("internal fun computeTripletSafe(")
        assertTrue("源码锚点已消失：computeTripletSafe", at >= 0)
        val body = worker.substring(at, minOf(at + 900, worker.length))
        assertTrue(
            "没选过范围时三元组必须退化为不显示，不许按全库口径算 K",
            body.contains("if (bucketIds == null)"),
        )
        val nullBranch = body.indexOf("if (bucketIds == null)")
        val count = body.indexOf("countAll(")
        assertTrue("源码锚点已消失：countAll(", count >= 0)
        assertTrue("范围检查必须在 countAll 之前", nullBranch in 0 until count)
    }

    // ── ④ 首次选择 = 全部新增 → 水位归零 ──

    @Test
    fun the_first_ever_selection_resets_the_watermark() {
        // 新语义下「从未选过」= 一张都没备过，首次选择就是全部新增，按
        // MOB-20 的规矩应归零水位。旧代码 `added = emptySet()` 是旧语义
        // （null 已经全备过了）的残留，不改的话首次选择要靠 MOB-36 的补齐
        // 兜底才收敛——能收敛，但语义不自洽。
        val main = codeOf("MainActivity.kt")
        val at = main.indexOf("val prevScope =")
        assertTrue("源码锚点已消失：val prevScope =", at >= 0)
        val window = main.substring(at, minOf(at + 400, main.length))
        assertTrue(
            "prevScope == null（从未选过）时差集必须是**全选中集**，不是空集",
            window.contains("if (prevScope == null) sel"),
        )
        assertTrue(
            "差集非空必须归零水位（MOB-20 不变量，本卡不许改坏）",
            main.contains("WatermarkStore(context.filesDir).save(0)"),
        )
    }
}
