// MOB-35：中断待确认时，只挡「重挂后台监听」，不挡「用户在前台的补捞」。
//
// 原来 MainActivity 的 LaunchedEffect 里一个 `if (backupInterrupted) return`
// 把两件事一起挡了。真机实测（2026-08-25）：force-stop → 停止期间拍照 →
// 重开 App 放前台不动 → 轮询 90 秒零上传。
//
// 用户定调（2026-08-25）："重新启动之后，我依旧没有启动后台是合理的，但是
// 前台情况下，都无法上传，是不是不合理呢？"——前台 = 人在场 = 该传。
// MOB-28 要防的是"背着用户把后台监听装回去"，不是"人在看着也不许传"。
//
// 为什么用源码断言而不是行为测试：这段逻辑长在 @Composable 的
// LaunchedEffect 里，起 Compose 测试环境的成本远大于它锁住的东西，而本仓
// 已有同款惯例（见 backup/OneBackupPipelineTest）。
package com.hawkeyexb.ppass

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ForegroundSyncNotFrozenTest {

    private fun codeOf(file: File): String =
        file.readText()
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .lines()
            .filterNot { it.trimStart().startsWith("//") }
            .joinToString("\n")

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return dir
    }

    /** 夹出那个 LaunchedEffect 的**块内**源码。
     *
     *  ⚠️ 必须夹右边界。OneBackupPipelineTest 记过这个教训：只切左边界会把
     *  锚点之后的整个文件都带进来，于是"块内不许有 X"这条断言实际是在全文
     *  找 X，改坏了也照样绿。 */
    private fun launchedEffectBody(): String {
        val src = codeOf(
            File(repoRoot(), "apps/android/app/src/main/java/com/hawkeyexb/ppass/MainActivity.kt")
        )
        // MOB-38 之后逻辑搬了家：从 `LaunchedEffect` 块内挪进共用函数
        // `foregroundCatchup`（因为 ON_RESUME 也要调它，两处各写一遍就是
        // 「漏接一处」的复发形状）。本卡三条不变量一个没变，只是位置变了。
        //
        // ⚠️ 这已经是本仓第四次「逻辑正当搬家 → 源码断言误伤」。判据本身
        // 是对的（它守的是真不变量），但**源码文本断言天生与位置耦合**——
        // 记在这里给 MOB-39 的实施者：那次重构会搬动更多逻辑，这类断言会
        // 成批变红，届时要改的是切片位置，不是不变量。
        val from = "val foregroundCatchup ="
        assertTrue("源码锚点已消失，断言失效：$from", src.contains(from))
        val tail = src.substringAfter(from)
        val to = "LaunchedEffect(backupInterrupted)"
        assertTrue("源码结束锚点已消失，断言失效：$to", tail.contains(to))
        return tail.substringBefore(to)
    }

    @Test
    fun foreground_catchup_is_not_gated_by_the_interruption_flag() {
        val body = launchedEffectBody()
        assertTrue(
            "前台补捞必须在块内被调用",
            body.contains("triggerUserPresentBackup"),
        )
        // 反证靶：块内不许出现"命中中断标志就整块早退"的写法。命中它
        // 就等于前台同步又被冻住了（MOB-35 回归）。
        assertFalse(
            "中断待确认时不许整块早退——那会把前台补捞一起冻住（MOB-35）",
            body.contains("if (backupInterrupted) return"),
        )
        // ⚠️ 这里曾加过一条「不许用 `!backupInterrupted` 把前台补捞包住」的
        // 正则断言，**当场就误报了**：Kotlin 的单语句 `if` 没有花括号，
        // `if (!backupInterrupted) scheduleAutoBackup(context)` 之后紧跟的
        // `triggerUserPresentBackup(context)` 其实在 `if` 之外，而正则按
        // 「N 个字符内出现」判命中，分不出作用域。已删。
        //
        // 真正守住这条的是姊妹测试 background_rearm_is_still_gated：它断言
        // `if (!backupInterrupted) scheduleAutoBackup`——单语句形式意味着门控
        // 只作用于那一句，前台补捞必然在门外。**别再用正则去猜作用域**，
        // 文本匹配做不到这件事。
    }

    @Test
    fun background_rearm_is_still_gated() {
        val body = launchedEffectBody()
        assertTrue(
            "后台监听的重挂必须仍受中断标志门控（MOB-28 红线）",
            body.contains("if (!backupInterrupted) scheduleAutoBackup"),
        )
    }

    @Test
    fun resume_stays_the_only_rearm_entry_point() {
        // MOB-28 的红线：除了用户点「恢复备份」，没有别的地方允许重挂。
        val health = codeOf(
            File(
                repoRoot(),
                "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupHealth.kt",
            )
        )
        assertTrue(
            "resumeAfterInterruption 仍须是那个入口",
            health.contains("fun resumeAfterInterruption"),
        )
        // ASK_USER 分支里不许出现重挂调用。
        val askUser = health
            .substringAfter("WatchRecovery.ASK_USER ->")
            .substringBefore("WatchRecovery.NORMAL")
        assertFalse(
            "ASK_USER 分支不许重挂后台监听",
            askUser.contains("scheduleAutoBackup"),
        )
    }

    /** 每一条「顺带」重挂监听的路径都必须有门。
     *
     *  这条是 MOB-35 第一版漏掉的东西：只拆了 MainActivity 那个 `return` 就
     *  报绿，而 `BackupWorker.doWork` 的 `finally` 里还有一句无条件的
     *  `ensureMediaWatch`——前台补捞一放行，那趟 work 跑完就把监听装回去，
     *  用户一次「恢复」都没点，MOB-28 红线当场破。上面那几条断言抓不到它，
     *  因为它们只看那个 `LaunchedEffect` 块，破线发生在下游。
     *
     *  所以这里的判据是**全文级**的：`ensureMediaWatch(` 的每一处调用，
     *  要么带门控，要么属于白名单里那两个「显式重挂」入口。 */
    @Test
    fun every_incidental_rearm_path_is_gated() {
        val worker = codeOf(
            File(
                repoRoot(),
                "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt",
            )
        )
        // 白名单：scheduleAutoBackup 是显式重挂入口（resumeAfterInterruption
        // 与开机/正常路径都靠它），它自己不设门。
        val explicitEntry = "fun scheduleAutoBackup"
        val callSites = worker.lines()
            .withIndex()
            .filter { (_, l) -> l.contains("ensureMediaWatch(") && !l.contains("fun ensureMediaWatch") }
        assertTrue("源码锚点已消失：找不到任何 ensureMediaWatch 调用", callSites.isNotEmpty())

        // scheduleAutoBackup 函数体的行号区间——它里面那一处允许无门。
        val startIdx = worker.lines().indexOfFirst { it.contains(explicitEntry) }
        assertTrue("源码锚点已消失：$explicitEntry", startIdx >= 0)
        val endIdx = worker.lines()
            .drop(startIdx + 1)
            .indexOfFirst { it.startsWith("fun ") || it.startsWith("private fun ") }
            .let { if (it < 0) worker.lines().size else startIdx + 1 + it }

        for ((idx, line) in callSites) {
            val insideExplicitEntry = idx in startIdx until endIdx
            if (insideExplicitEntry) continue
            assertTrue(
                "第 ${idx + 1} 行的 ensureMediaWatch 没有门控——中断待确认时它会" +
                    "把监听悄悄装回去，破 MOB-28 红线：${line.trim()}",
                line.contains("mayRearmWatchIncidentally"),
            )
        }
    }

    @Test
    fun interruption_copy_says_it_is_the_background_that_stopped() {
        // 文案不许自相矛盾：前台明明在传，提示不能说"什么都没在传"。
        val zh = File(
            repoRoot(),
            "apps/android/app/src/main/res/values-zh/strings.xml",
        ).readText()
        val line = zh.lines().first { it.contains("backup_interrupted_body") }
        assertTrue("中文文案要点明停的是「后台」：$line", line.contains("后台"))
        assertTrue(
            "中文文案要告诉用户前台仍会传：$line",
            line.contains("打开 App"),
        )
    }
}
