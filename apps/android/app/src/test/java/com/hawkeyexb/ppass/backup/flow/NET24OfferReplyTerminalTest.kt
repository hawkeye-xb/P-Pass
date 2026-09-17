// NET-24：`flow.offer` 的应答携带终态时，交付流程必须当场收下，
// 不许再去等那条已经错过的 `flow.delivered` 推送。
//
// 背景（真机 2026-09-16，三星 SM-S9210）：NET-20 的内容去重命中时，daemon
// 在 offer 的处理过程中**同步**完成并 emit `flow.delivered`；而手机是
// offer 之后才 `subscribeTimeline`，daemon 的事件总线又是 broadcast
// （无订阅者时 send 直接丢弃）。于是推送必丢，手机只能耗满
// `LOCAL_IDLE_STALL_THRESHOLD_MS`（30 秒）的本地兜底才靠 `flow.status()`
// 把早已完成的状态捞回来——11 张照片约 3 分钟。
//
// 为什么用源码断言而不是行为测试：`NativeFlowDeliveryPort.start()` 依赖
// ContentResolver / Uri.parse / Blake3 原生库 / 原生 blobs bridge，起一套
// 能跑通它的测试环境的成本远大于它锁住的东西；而这条要锁的恰恰是一个
// **顺序不变量**（应答先于订阅被消费），源码断言直接表达它。本仓已有
// 同款惯例（ForegroundSyncNotFrozenTest / OneBackupPipelineTest）。
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class NET24OfferReplyTerminalTest {

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return dir
    }

    private fun codeOf(file: File): String =
        file.readText()
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .lines()
            .filterNot { it.trimStart().startsWith("//") }
            .joinToString("\n")

    private fun portSource(): String = codeOf(
        File(
            repoRoot(),
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/" +
                "NativeFlowDeliveryPort.kt",
        )
    )

    @Test
    fun offer_declares_a_status_reply_instead_of_returning_nothing() {
        val code = portSource()
        assertTrue(
            "NET-24: FlowReceiptClient.offer 必须返回 FlowStatusReply——" +
                "回 Unit 就等于把 daemon 手里已有的终态丢掉",
            Regex("""suspend fun offer\(request: FlowFetchRequest\): FlowStatusReply""")
                .containsMatchIn(code),
        )
    }

    @Test
    fun the_offer_reply_is_consumed_before_any_push_subscription_exists() {
        val code = portSource()
        val replyCaptured = Regex("""val offerReply = desktop\.offer\(request\)""")
            .find(code)
            ?: error(
                "NET-24: offer 的返回值必须被接住（val offerReply = desktop.offer(...)）；" +
                    "丢弃返回值 = 回到 30 秒兜底那条老路"
            )
        val replyConsumed = Regex("""flowStatusPollOutcome\(offerReply\)""").find(code)
            ?: error(
                "NET-24: 接住了还得用——offerReply 必须过 flowStatusPollOutcome " +
                    "（与轮询路径同一个判别函数，不另发明状态机）"
            )
        val subscribe = Regex("""client\.subscribeTimeline""").find(code)
            ?: error("subscribeTimeline 不见了——本测试的前提已失效，请重新表述")

        assertTrue(
            "NET-24 的顺序不变量：offer 应答必须在建立推送订阅**之前**就被判别。" +
                "反过来就是本卡的 bug——订阅还没上线，推送已经被广播总线丢弃了。",
            replyConsumed.range.first < subscribe.range.first,
        )
        assertTrue(
            "offerReply 的接收必须早于它的消费",
            replyCaptured.range.first < replyConsumed.range.first,
        )
    }

    @Test
    fun a_terminal_offer_reply_ends_the_attempt_without_entering_the_wait_loop() {
        val code = portSource()
        // 夹出 offer 应答判别那一段（从接住返回值到进入等待循环之前），
        // 只在这一段里断言，避免误匹配等待循环内部同名的分支。
        val start = code.indexOf("val offerReply = desktop.offer(request)")
        val end = code.indexOf("val pushChannel")
        assertTrue("源码结构变了：找不到 offer 应答判别段", start in 0 until end)
        val block = code.substring(start, end)

        assertTrue(
            "NET-24: 应答为 Completed 时必须直接 acceptReceipt 并结束本轮，" +
                "不许落进等待循环",
            Regex("""is FlowStatusPollOutcome\.Completed ->[\s\S]*?acceptReceipt\(""")
                .containsMatchIn(block) &&
                Regex("""is FlowStatusPollOutcome\.Completed ->[\s\S]*?return@launch""")
                    .containsMatchIn(block),
        )
        assertTrue(
            "NET-24: 应答为 Cancelled 时必须放弃本轮，不许继续等一个不会来的完成",
            Regex("""FlowStatusPollOutcome\.Cancelled ->[\s\S]*?return@launch""")
                .containsMatchIn(block),
        )
        assertTrue(
            "NET-24: 只有 active（KeepPolling）才准继续走等待循环",
            Regex("""FlowStatusPollOutcome\.KeepPolling ->""").containsMatchIn(block),
        )
    }
}
