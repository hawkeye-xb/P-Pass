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

    @Test
    fun the_repair_path_also_runs_one_reconciliation() {
        // 断开期间桌面那边什么都可能发生过（照片被 Finder 删掉、库被挪走），
        // 重新授权是最该核对一次的时刻——也是真机验收这条链最快的触发点，
        // 不必等 5 小时兜底。
        val runtime = code("app/src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidFlowRuntime.kt")
        val repair = sliceBetween(runtime, "fun requestFlowWakeAfterRepair(", "internal fun pauseFlow")
        assertTrue("重新授权后要唤醒", repair.contains("runFlowWake("))
        assertTrue("重新授权后要对账", repair.contains("runFlowReconcile("))
        // 裸 thread {} 里抛出的异常只走默认处理器，调用方什么也看不到——真机上
        // 表现就是「配对完成了却毫无动静」，跟根本没调过一模一样（2026-09-20
        // 真机验收正是卡在这个形状上，查了半天分不清「没调」和「调了但炸了」）。
        assertTrue("配对后这条路必须自己兜住异常并留痕", repair.contains("Log.e(\"PPassFlow\""))
    }

    @Test
    fun reconciliation_has_a_production_caller_at_all() {
        // MOB-87 缺陷 #2 的门禁。修这张卡之前，`reconcilePage` 全仓引用只有
        // 三处：定义本身 + ARCH01 测试两处，**生产零调用方**。于是
        // `remotePresence` 恒为默认 UNKNOWN、`disposition` 从没被写过——
        // 代码注释自己写着 `reuploadNoticeCount > 0 is permanently false`。
        //
        // 只要这条链上任何一环被拆掉，对账就又变回「写好了没人叫」，而那种
        // 坏法**不会有任何测试自然变红**——所以这里明写。
        val runtime = code("app/src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidFlowRuntime.kt")
        assertTrue(
            "必须有一个生产入口真的去问桌面",
            runtime.contains("RemotePresenceProbe(") && runtime.contains("planPage()"),
        )
        // MOB-87 真机教训：这条链全程无日志时，「没跑」「跑了但桌面不可达」
        // 「跑了但 runtime 没建起来」在 logcat 上完全同形，只能靠 run-as 读
        // 账本反推。每个提前退出的分支都必须留一句。
        val reconcile = sliceBetween(runtime, "suspend fun runFlowReconcile(", "\n}")
        listOf("not paired", "no Flow runtime available", "Desktop unreachable").forEach { mark ->
            assertTrue("对账的提前退出分支必须留痕：$mark", reconcile.contains(mark))
        }
        assertTrue(
            "对账结果必须回到写者线程落账（生产账本是 SingleThreadLedgerWrites 强制的）",
            runtime.contains("FlowAction.ApplyReconciliation("),
        )

        val worker = code("app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt")
        assertTrue(
            "5 小时周期兜底那一轮必须带上对账——它是桌面长期离线后唯一的补救时机",
            worker.contains("runFlowReconcile(applicationContext)"),
        )
        // doWork 是 suspend，必须**等**对账跑完。用 fire-and-forget 版的话
        // Result.success() 当场落地、WorkManager 放掉 wakelock，那个还在等
        // 桌面网络往返的协程随时被掐——2026-09-20 合入后真机上就是这么坏的。
        assertTrue(
            "worker 里不许用 fire-and-forget 版",
            !worker.contains("requestFlowReconcile("),
        )
        val periodic = sliceBetween(worker, "PeriodicWorkRequestBuilder<BackupWorker>", ".build()")
        assertTrue("只有周期兜底那条挂对账标", periodic.contains("KEY_RECONCILE_REMOTE to true"))
        val oneShot = sliceBetween(worker, "internal fun backupWorkRequest(", ".build()")
        assertTrue(
            "内容监听/回前台补捞/手动备份是一拍一个，挂上去等于每拍一张就朝桌面发一页查询",
            !oneShot.contains("KEY_RECONCILE_REMOTE"),
        )
    }

    @Test
    fun unpairing_no_longer_deletes_the_durable_ledger() {
        // MOB-87 缺陷 #7：删账本等于每次断开都宣布"我什么都没传过"，重连后
        // 整库重新提供一遍（实测 95 张照片 4 次重连 → 桌面 603 行），而且让
        // 对账无从谈起——没有 CONFIRMED 项就没有"桌面上还在吗"可问。
        //
        // 本卡推翻 MOB-62 卡面「旧 remote Flow ledger 删除」那一条：删账本是
        // 它的手段不是目的。保留的是**数据**，关掉的是**执行**。
        val runtime = code("app/src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidFlowRuntime.kt")
        val clear = sliceBetween(runtime, "fun clearFlowRuntime(", "\n}")
        assertTrue(
            "断开不许再删 flow-state/ 下的账本",
            !clear.contains("deleteRecursively"),
        )
        // MOB-62 要的那部分必须原样还在。
        assertTrue("旧 runtime 仍要从 map 移除", clear.contains("flowRuntimes.remove("))
        // 同上：runtime 构造是「重新配对后账本有没有迁移」的唯一分水岭，
        // 它两侧必须能在 logcat 上看出走到哪一步了。
        val build = sliceBetween(runtime, "buildRuntime: bootstrap start", "buildRuntime: bootstrap done")
        assertTrue("引导三连必须夹在两条日志之间", build.contains("EnsurePairingEpoch"))
        assertTrue("写者线程仍要显式关", clear.contains("stale.shutdown()"))
        // MOB-91：改成 revoke——停在飞的传输，但**不关仓库**。关了之后同一
        // 进程内再也 open 不回来（真机实测永久阻塞），整个 Flow 瘫痪到进程
        // 重启，那正是「必须杀掉 App 重开」的真根因。详见
        // MOB62RuntimeInitializationTest.the_native_provider_is_opened_once...
        assertTrue("解除配对要停掉在飞的传输", clear.contains("nativeProvider.revoke("))
        assertFalse("但不许关仓库", clear.contains(".close()"))
    }
}
