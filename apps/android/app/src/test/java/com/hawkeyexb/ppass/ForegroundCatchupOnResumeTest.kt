// MOB-38（2026-08-26 真机 0.4.0-test.5）：回到前台就补捞一次。
//
// 验收人原话：「在前台，一张照片很久也没有同步。……就是，从我们 app 切换到
// 相机，这样就不算前台了吗？我记得咱们针对不同的 app 状态有过讨论的啊。」
//
// 答案是：算前台，但我们没在「回到前台」这个时机补捞。补捞原来只挂在
// `LaunchedEffect(backupInterrupted)` 上——键只有一个，composition 存活期间
// 只跑一次；Activity 走 STOPPED → RESUMED 不会让它重跑。
//
// 讽刺的是同一个文件里**已经有**四处 ON_RESUME 刷新（电池白名单 DOG-02、
// 通知权限、失联天数 SENT-01、部分授权态 MOB-02）外加两处 start/stop
// （心跳 PRES-01、时间线订阅 SYNC-06）——唯独备份补捞漏了。
package com.hawkeyexb.ppass

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ForegroundCatchupOnResumeTest {

    /** 剥注释行：正向 contains 会被「把那行注释掉」骗过，反向禁令会被注释里
     *  引用的旧写法误判（本仓既有惯例，见 backup/OneBackupPipelineTest）。 */
    private fun code(): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/MainActivity.kt")
            .readText().lines()
            .filterNot {
                val t = it.trimStart()
                t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
            }
            .joinToString("\n")
    }

    private fun sliceBetween(s: String, from: String, to: String): String {
        assertTrue("源码锚点已消失，断言失效：$from", s.contains(from))
        val tail = s.substringAfter(from)
        assertTrue("源码结束锚点已消失，断言失效：$to", tail.contains(to))
        return tail.substringBefore(to)
    }

    /** ON_RESUME 分支的块内源码。右边界用 ON_STOP——它紧跟其后。 */
    private fun onResumeBlock(): String =
        sliceBetween(code(), "Lifecycle.Event.ON_RESUME ->", "Lifecycle.Event.ON_STOP")

    @Test
    fun coming_back_to_the_foreground_triggers_a_catchup() {
        // 这是本卡的本体判据。**故意不断言「LaunchedEffect 里有那行」**——
        // 那正是这个 bug 的形状（只在首次进入组合时跑一次）。
        assertTrue(
            "回到前台必须补捞一次——补捞要挂在 ON_RESUME 上，不能只挂一次性的 LaunchedEffect",
            onResumeBlock().contains("foregroundCatchup()"),
        )
    }

    @Test
    fun the_catchup_logic_exists_in_exactly_one_place() {
        // MOB-33/34/35/38 四个 bug 全是「漏接一处」。两处各写一遍门控的话，
        // 下次改其中一条就又会漏——所以门控必须只有一份。
        val s = code()
        assertTrue("必须提成一个共用的补捞函数", s.contains("val foregroundCatchup ="))
        // 门控（配对、暂停、中断）只允许出现在那个函数体内。
        val fn = sliceBetween(s, "val foregroundCatchup =", "LaunchedEffect(backupInterrupted)")
        assertTrue("配对判定在函数体内", fn.contains("pairings.load()"))
        assertTrue("暂停判定在函数体内", fn.contains("paused()"))
        assertTrue(
            "后台重挂仍受中断标志门控（MOB-28 红线）",
            fn.contains("if (!backupInterrupted) scheduleAutoBackup"),
        )
        assertTrue("前台补捞无条件跑（MOB-35 定调）", fn.contains("triggerUserPresentBackup"))

        // ON_RESUME 分支里**不许**再写一遍门控——那就是「两处各写一遍」的
        // 复发形状。它只该调那个函数。
        val resume = onResumeBlock()
        assertFalse(
            "ON_RESUME 里不许重复写门控，只该调 foregroundCatchup()",
            resume.contains("paused()") || resume.contains("scheduleAutoBackup"),
        )
    }

    @Test
    fun the_one_shot_launched_effect_no_longer_carries_the_logic() {
        // 首次进入组合那条路径要保留（冷启动也得补一次），但它现在只该转调
        // 共用函数，而不是自己持有一份逻辑。
        val body = sliceBetween(
            code(), "LaunchedEffect(backupInterrupted) {", "}",
        )
        assertTrue("首次进入组合仍要补一次", body.contains("foregroundCatchup()"))
        assertFalse(
            "LaunchedEffect 里不许再持有门控逻辑",
            body.contains("paused()") || body.contains("scheduleAutoBackup"),
        )
    }

    @Test
    fun resume_sits_alongside_the_other_lifecycle_refreshes() {
        // 反面锚点：如果哪天有人把 ON_RESUME 那一整块删了/挪了，上面几条会
        // 因为锚点消失而红（sliceBetween 自带断言）。这条额外确认「那四处
        // 既有刷新还在」，避免有人为了加补捞而误删旁边的东西。
        val resume = onResumeBlock()
        assertTrue("电池白名单刷新还在", resume.contains("isIgnoringBatteryOptimizations"))
        assertTrue("部分授权态刷新还在", resume.contains("hasPartialMediaAccess"))
        assertTrue("前台心跳还在", resume.contains("heartbeat.start()"))
        assertTrue("时间线订阅还在", resume.contains("timeline.start()"))
    }
}
