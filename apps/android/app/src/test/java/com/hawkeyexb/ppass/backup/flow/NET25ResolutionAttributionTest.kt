// NET-25：一次交付最终是被哪条信号结账的，日志必须说得出来。
//
// 背景：NET-24 真机验收「每张 0.3 秒」看着很漂亮，却**不构成推送可用的
// 证据**——三条信号（offer 应答 / flow.delivered 推送 / status 兜底）解析
// 成功后走的是同一行 `receipt = outcome.receipt`，跑多少轮都分不出是谁结
// 的账。本测试把这三条判别行钉死，防止它们在后续重构里被顺手删掉，让
// NET-25 的取证能力再次消失于无形。
//
// 为什么用源码断言：与 NET24OfferReplyTerminalTest 同款理由——`start()`
// 依赖 ContentResolver / Uri.parse / Blake3 原生库 / 原生 blobs bridge，
// 起一套能跑通它的测试环境的成本远大于它锁住的东西；而这里要锁的就是
// "某个分支里有没有那一行"，源码断言直接表达它。
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NET25ResolutionAttributionTest {

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir") ?: error("user.dir unset"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return dir
    }

    private fun portSource(): String = File(
        repoRoot(),
        "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/" +
            "NativeFlowDeliveryPort.kt",
    ).readText()
        .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
        .lines()
        .filterNot { it.trimStart().startsWith("//") }
        .joinToString("\n")

    @Test
    fun every_terminal_path_states_which_signal_closed_it() {
        val code = portSource()
        for (label in listOf("offer_reply", "push", "status")) {
            assertTrue(
                "NET-25: 缺少 `Flow resolved by=$label` 判别行——少一条，" +
                    "这一轮到底是谁结的账就又说不清了",
                code.contains("Flow resolved by=$label"),
            )
        }
        assertEquals(
            "NET-25: 三条判别行必须各出现一次；重复 = 有分支被贴错标签",
            3,
            Regex("""Flow resolved by=""").findAll(code).count(),
        )
    }

    @Test
    fun each_label_sits_in_the_branch_it_claims_to_describe() {
        val code = portSource()
        fun at(pattern: String): Int =
            Regex(Regex.escape(pattern)).find(code)?.range?.first
                ?: error("NET-25: 源码结构变了，找不到 `$pattern`，请重新表述本测试")

        val offerReplyLabel = at("Flow resolved by=offer_reply")
        val waitLoopStarts = at("val pushChannel")
        val statusCall = at("desktop.status(tuple)")
        val pushLabel = at("Flow resolved by=push")
        val statusLabel = at("Flow resolved by=status")

        assertTrue(
            "NET-25: `by=offer_reply` 必须在 offer 应答判别段里——也就是等待" +
                "循环建立之前。落到循环里就不是这条路了。",
            offerReplyLabel < waitLoopStarts,
        )
        assertTrue(
            "NET-25: `by=push` 必须在等待循环内、且早于 status 兜底调用——" +
                "它标的是 flowWaitStep 那条只可能来自 FlowPushOutcome.Delivered " +
                "的 Resolved(Completed) 分支",
            pushLabel in (waitLoopStarts + 1) until statusCall,
        )
        assertTrue(
            "NET-25: `by=status` 必须在 `desktop.status(tuple)` 之后——" +
                "它标的是兜底那条控制面回答",
            statusLabel > statusCall,
        )
    }

    @Test
    fun the_push_label_is_not_smuggled_into_the_local_signal_branch() {
        val code = portSource()
        // flowWaitStep 里唯一产出 Resolved(Completed) 的分支必须仍然只有
        // FlowPushOutcome.Delivered——这是 `by=push` 这个标签成立的全部依据。
        // 哪天有人给本地事件也加一条 Resolved(Completed)，这个标签就会开始
        // 说谎，必须在这里当场变红。
        val waitStep = code.substringAfter("internal fun flowWaitStep(")
            .substringBefore("\ninternal fun nextStatusPollDelayMs")
        assertEquals(
            "NET-25: `flowWaitStep` 里产出 Resolved(...) 的分支不止一条了——" +
                "`by=push` 这个标签的前提（Resolved(Completed) 只可能来自推送）" +
                "已经不成立，要么改标签要么改判别函数，不能放着它说谎",
            1,
            Regex("""FlowWaitStep\.Resolved\(""").findAll(waitStep).count(),
        )
        assertTrue(
            "NET-25: 那唯一一条必须仍然挂在 FlowPushOutcome.Delivered 上",
            Regex("""is FlowPushOutcome\.Delivered -> return FlowWaitStep\.Resolved\(""")
                .containsMatchIn(waitStep),
        )
    }
}
