// UX-13（2026-08-26 真机）：验收人原话「暂停之后，没有重新开始的按钮？」
//
// 缺陷本体：英雄区那个按钮只在进行中渲染，一暂停就整个消失，首页再没有
// 续传入口——而 UX-01 的语义是「进行中再点 = 暂停……再点一次 = 续传」，
// 管线支持续传，界面上没有那个「再点一次」可点。
//
// 本文件钉四条不变量：
//   ① 「被用户暂停」与「本来就没事干」是**两个不同的状态**（不是靠 Idle 猜）；
//   ② 被暂停时英雄区出「继续」，点它走的是**同一条管线**；
//   ③ 空闲且无待办时按钮**不显示**（不许回退成常驻按钮）；
//   ④ 判据不依赖那条 CANCELLED 记录——取消拿不到 outputData，无戳记录在
//      「按戳取最大」的选取里恒被当上古记录（本卡最容易踩的坑）。
package com.hawkeyexb.ppass

import com.hawkeyexb.ppass.backup.pausedAfterOf
import com.hawkeyexb.ppass.ui.BackupUiState
import com.hawkeyexb.ppass.ui.HeroAction
import com.hawkeyexb.ppass.ui.heroActionOf
import com.hawkeyexb.ppass.ui.isBackupRunning
import com.hawkeyexb.ppass.ui.StatusLine
import com.hawkeyexb.ppass.ui.statusLineOf
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ResumeAfterPauseTest {

    /** 源码断言的前处理：剥注释行（OnePipelineOnePauseTest 同款）——正向
     *  contains 会被「把那行注释掉」骗过，反向禁令会被注释里引用的旧写法
     *  误判。 */
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

    private fun sliceBetween(s: String, from: String, to: String): String {
        assertTrue("源码锚点已消失，断言失效：$from", s.contains(from))
        val tail = s.substringAfter(from)
        assertTrue("源码结束锚点已消失，断言失效：$to", tail.contains(to))
        return tail.substringBefore(to)
    }

    // ── ① 「被暂停」是独立的态，不是 Idle 的一种猜法 ──

    @Test
    fun a_user_pause_is_a_state_of_its_own_not_just_idle() {
        // 用户按了暂停（1_000），之后没有任何一轮跑完（最新完成戳 500）。
        assertTrue(
            "Working → 用户暂停之后必须能判出「被暂停」",
            pausedAfterOf(pausedAt = 1_000L, newestFinishedAt = 500L, anyRunning = false),
        )
        // 「本来就没事干」：从没按过暂停 → 同样的空闲，判据必须给出不同答案。
        assertFalse(
            "没按过暂停的空闲不许被当成「被暂停」",
            pausedAfterOf(pausedAt = 0L, newestFinishedAt = 500L, anyRunning = false),
        )
        // 两种空闲落到两个不同的界面状态——这就是「不是靠 Idle 猜」。
        assertEquals(HeroAction.Resume, heroActionOf(BackupUiState.Paused, pairingLost = false))
        assertNull(heroActionOf(BackupUiState.Idle, pairingLost = false))
    }

    @Test
    fun bytes_still_flying_is_not_paused_yet() {
        // MOB-33 红线：点完暂停而 work 还在跑的那几帧，界面必须继续说进行中
        // （不许当场假装停了）。
        assertFalse(
            "有 work 在跑就不是暂停态",
            pausedAfterOf(pausedAt = 1_000L, newestFinishedAt = 0L, anyRunning = true),
        )
    }

    @Test
    fun a_run_that_finished_after_the_pause_expires_it() {
        // 暂停之后又跑完了一轮（带戳）→ 这次暂停已被覆盖，界面回到正常空闲。
        assertFalse(
            "暂停之后有跑完的运行，暂停就过期了",
            pausedAfterOf(pausedAt = 1_000L, newestFinishedAt = 2_000L, anyRunning = false),
        )
    }

    // ── ④ 不依赖那条 CANCELLED 记录（本卡的坑） ──

    @Test
    fun the_verdict_survives_an_unstamped_cancelled_record() {
        // WorkManager 取消时拿不到 outputData → CANCELLED 没有 KEY_FINISHED_AT
        // 戳。若判据是「最近一条终态是 CANCELLED」，只要盘上还有一条带戳的
        // 历史成功记录，那条 CANCELLED 就永远选不中、暂停永远判不出来。
        // 这里的判据只看时刻：一条戳都没有（0）也照样判得出。
        assertTrue(
            "无戳的 CANCELLED 不该妨碍判出「刚被暂停」",
            pausedAfterOf(pausedAt = 1_000L, newestFinishedAt = 0L, anyRunning = false),
        )
        // 而且历史成功记录（戳更早）也不许把它盖掉。
        assertTrue(
            "暂停之前的历史成功记录不许盖掉这次暂停",
            pausedAfterOf(pausedAt = 1_000L, newestFinishedAt = 999L, anyRunning = false),
        )
    }

    @Test
    fun the_paused_state_is_actually_wired_into_uiStateOf() {
        // 纯判据成立不等于界面用上了。WorkInfo 的构造函数是 @RestrictTo
        // （JVM 单测造不出来），所以这条只能钉**接线**：uiStateOf 必须按
        // pausedAfterOf 返回 Paused，且 holder 必须把 pausedAt 传进去。
        // 这也是本卡「反证」的着力点：把这段合成删掉退回统一 Idle → 本条红。
        val holder = codeOf("backup/BackupUiStateHolder.kt")
        val pick = sliceBetween(holder, "val finished = infos.filter", "return when {")
        assertTrue(
            "uiStateOf 必须用 pausedAfterOf 合成出被暂停态",
            pick.contains("pausedAfterOf(") && pick.contains("BackupUiState.Paused"),
        )
        assertTrue(
            "holder 必须把用户按下暂停的时刻传给 uiStateOf",
            holder.contains("uiStateOf(infos, pausedAt)"),
        )
        assertTrue(
            "按下暂停的时刻必须落盘（杀 App 重开后「继续」还要在原地）",
            holder.contains("pausePrefs.setPausedAt("),
        )
    }

    // ── ② 被暂停 → 「继续」，且走同一条管线 ──

    @Test
    fun paused_renders_resume_in_the_same_place_and_reuses_the_one_pipeline() {
        assertEquals(
            "被暂停时英雄区必须是「继续」",
            HeroAction.Resume,
            heroActionOf(BackupUiState.Paused, pairingLost = false),
        )
        assertEquals(
            "进行中仍然是「暂停」（现状不许改）",
            HeroAction.Pause,
            heroActionOf(BackupUiState.Sending(1, 9), pairingLost = false),
        )
        // 「点它走 triggerManualBackup」：backupNow 只在**进行中**那一下走
        // 取消分支，Paused 不算在跑 → 落到唯一那条 triggerManualBackup。
        assertFalse(
            "被暂停不算在跑，否则「继续」会被当成又一次暂停",
            isBackupRunning(BackupUiState.Paused),
        )
        val backupNow = sliceBetween(
            codeOf("backup/BackupUiStateHolder.kt"),
            "fun backupNow()",
            "triggerManualBackup(context)",
        )
        assertTrue(
            "点击的裁决必须与按钮文案的裁决共用 isBackupRunning",
            backupNow.contains("isBackupRunning(_state.value)"),
        )
        // MOB-19 红线：界面侧不许自己再开一条备份路径。
        val home = codeOf("ui/HomeScreen.kt")
        assertFalse(
            "HomeScreen 不许自己触发备份——只能回调 onBackupNow",
            home.contains("triggerManualBackup"),
        )
        val at = home.indexOf("val heroAction = heroActionOf(")
        assertTrue("源码锚点已消失：val heroAction = heroActionOf(", at >= 0)
        val button = home.substring(at, minOf(at + 700, home.length))
        assertTrue(
            "「继续」必须用 backup_resume 文案",
            button.contains("HeroAction.Resume") && button.contains("R.string.backup_resume"),
        )
        assertTrue(
            "「暂停」文案不动",
            button.contains("HeroAction.Pause") && button.contains("R.string.backup_pause"),
        )
        assertEquals(
            "两个分支必须是同一个 onClick（同一条管线，不许第二个回调）",
            1,
            Regex("onClick = ").findAll(button).count(),
        )
        assertTrue("那唯一的 onClick 必须是 onBackupNow", button.contains("onClick = onBackupNow"))
    }

    // ── ③ 空闲且无待办时按钮不显示 ──

    @Test
    fun no_button_when_idle_with_nothing_to_do() {
        assertNull("空闲不显示按钮", heroActionOf(BackupUiState.Idle, pairingLost = false))
        assertNull(
            "都存好了不显示按钮",
            heroActionOf(BackupUiState.AllSafe(0, 0), pairingLost = false),
        )
        assertNull(
            "没有可备份的相册不显示按钮",
            heroActionOf(BackupUiState.NoAlbums, pairingLost = false),
        )
        assertNull(
            "出错了出路在红卡的「再试一次」，英雄区不出按钮",
            heroActionOf(BackupUiState.Trouble("boom"), pairingLost = false),
        )
        assertNull(
            "配对失效时收起——出路在红卡的重新扫码",
            heroActionOf(BackupUiState.Sending(1, 9), pairingLost = true),
        )
        assertNull(
            "配对失效时连「继续」也收起",
            heroActionOf(BackupUiState.Paused, pairingLost = true),
        )
    }

    @Test
    fun paused_keeps_telling_the_truth_about_the_backlog() {
        // 新状态不许破 T-080 的缺陷 (a)：K > 0 时永不说「照片都存好了」。
        assertEquals(
            StatusLine.Pending(7L),
            statusLineOf(BackupUiState.Paused, pendingK = 7L),
        )
        assertEquals(StatusLine.Ready, statusLineOf(BackupUiState.Paused, pendingK = 0L))
    }
}
