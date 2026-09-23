// MOB-87（2026-09-17 真机 NET-25 验收时捞出）：会话内重新扫码配对成功 →
// 什么都不发生。验收人等了约 9 秒（手机侧 `PPassFlow` 零行），把 App 划掉
// 重开，1.7 秒后传输就开始了。
//
// 这是 MOB-33/34/35/38 之后「漏接一处」的**第五例**。前四例的教训写在
// `foregroundCatchup` 的注释里：「提成函数不是为了少打字，是为了让『漏接
// 一处』变得不可能」。可补捞的两个触发点都接不住配对成功：
//
// - `LaunchedEffect(backupInterrupted)`：键里没有配对状态，composition
//   存活期间只跑一次；
// - `ON_RESUME`（MOB-38 补的）：会话内扫码时用户人一直在 App 里，Activity
//   没走过 STOPPED → RESUMED，这个分支根本不触发。
//
// 于是「配对成功」这个状态跃迁**两个都不在其中**。
//
// 门禁用源文本而不是行为测试：这一处是 Compose 里的一行调用，JVM 侧跑不起
// Activity；而它的失效方式恰恰是「有人重构时把那一行弄丢了」——源文本正好
// 能钉住。同形状先例见 ForegroundCatchupOnResumeTest（MOB-38）。
package com.hawkeyexb.ppass

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RepairWakesFlowTest {

    /** 剥注释行：正向 contains 会被「把那行注释掉」骗过。同 MOB-38 的惯例。 */
    private fun code(relative: String): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(dir, "apps/android/$relative").readText().lines()
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

    private fun mainActivity() = code("app/src/main/java/com/hawkeyexb/ppass/MainActivity.kt")

    @Test
    fun a_successful_pairing_wakes_flow_without_an_app_restart() {
        // 本卡本体判据。锚点选 `pairings.save(` 而不是分支名——保存新配对
        // 就是「配对成功」这个事实落地的那一刻，唤醒必须紧跟着它。
        val joined = sliceBetween(mainActivity(), "pairings.save(outcome.pairing)", "}")
        assertTrue(
            "配对成功必须当场叫醒 Flow——这是 MOB-87 的原症状：不接的话要杀 App 重开才动",
            joined.contains("requestFlowWakeAfterRepair("),
        )
    }

    // ARCH-13 (#417)：重新授权 = 一次带慢路径的触发（含问桌面「还在吗」），不再是 wake + 单独的对账函数。
    @Test
    fun the_repair_path_also_runs_one_reconciliation() {
        val runtime = code("app/src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidFlowRuntime.kt")
        val repair = sliceBetween(runtime, "fun requestFlowWakeAfterRepair(", "internal fun pauseFlow")
        assertTrue("重新授权后要唤醒，并带慢路径", repair.contains("TriggerReason.PAIRING_REPAIRED"))
        assertTrue("PAIRING_REPAIRED 必须跑慢路径（含桌面存在性检查）", com.hawkeyexb.ppass.backup.flow.TriggerReason.PAIRING_REPAIRED.slowPath)
    }

    @Test
    fun reconciliation_has_a_production_caller_at_all() {
        val runtime = code("app/src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidFlowRuntime.kt")
        assertTrue("必须有一个生产入口真的去问桌面", runtime.contains("RemotePresenceProbe("))
        val worker = code("app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt")
        val periodic = sliceBetween(worker, "PeriodicWorkRequestBuilder<BackupWorker>", ".build()")
        assertTrue("5 小时周期兜底那一轮必须跑慢路径", periodic.contains("TriggerReason.PERIODIC"))
        assertTrue(com.hawkeyexb.ppass.backup.flow.TriggerReason.PERIODIC.slowPath)
        assertFalse(
            "内容监听一拍一个，不许每拍一张就朝桌面发一页查询",
            com.hawkeyexb.ppass.backup.flow.TriggerReason.MEDIA_CHANGE.slowPath,
        )
    }

    @Test
    fun unpairing_no_longer_deletes_the_durable_ledger() {
        val runtime = code("app/src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidFlowRuntime.kt")
        val clear = sliceBetween(runtime, "fun clearFlowRuntime(", "\n}")
        assertTrue("断开不许删 order 表", !clear.contains("deleteRecursively") && !clear.contains("claimOwner"))
        assertTrue("旧运行时要显式关", clear.contains("stale?.shutdown()"))
        assertTrue("解除配对要停掉在飞的传输", clear.contains("sharedNativeProvider?.revoke("))
        assertFalse("但不许关仓库", clear.contains(".close()"))
    }
}
