// MOB-76: 「仅 Wi-Fi 时备份」开启 + 蜂窝网络 = 任何触发路径都不得发起交付。
// 09-12 OPPO 真机（v0.5.1）：限制开着、5G 下传输照常发起。根因（卡面取证）：
// FlowRunner 事件后 wake 共 6 处硬编码 constraintsSatisfied = true——任何一张
// 完成回执/失败重排/重试/取消恢复收尾都会无视 Wi-Fi 闸门把下一个队头推上
// 蜂窝。本组用例锁「事件后 wake 读实时闸门」这条不变量。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.proto.FlowCompletionReceipt
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB76WifiGateTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-mob76-$case").toFile()

    private fun candidate(id: Long) = DiscoveryCandidate(
        sourceRef = "content://media/external/images/media/$id",
        sourceVersion = "generation-7",
        bucketId = 42L,
    )

    private class FakeDiscovery(private val page: DiscoveryPage) : FlowDiscoveryPort {
        override fun discover(cursor: DiscoveryCursor, scope: ScopeRevision): DiscoveryPage = page
    }

    private class FakeDelivery : DeliveryPort {
        val starts = mutableListOf<Long>()
        override fun start(item: TransferItem, resumePartial: Boolean, lease: FetchLease) {
            starts += item.queueSequence
        }
        override fun stop(queueSequence: Long): PartialDisposition = PartialDisposition.RETAINED
    }

    // 卡面验收 1（改前必红）：限制开启（provider=false）时，第 1 张的完成
    // 回执不得把第 2 张推上网络；网络恢复（provider=true）后的下一次唤醒
    // 才继续。
    @Test
    fun completion_receipt_on_cellular_does_not_start_the_next_head() {
        val dir = tempDir("receipt-gate")
        val ledger = DiscoveryLedgerStore(dir)
        val delivery = FakeDelivery()
        var onWifi = true
        val runner = FlowRunner(
            ledger,
            FakeDiscovery(DiscoveryPage(listOf(candidate(18), candidate(19)), DiscoveryCursor(7L, 19L))),
            delivery,
            constraintsProvider = { onWifi },
        )
        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)
        assertEquals(listOf(1L), delivery.starts)

        // 传输期间网络落到蜂窝（wifiOnly 开）：回执仍要持久化，但不得外呼。
        onWifi = false
        runner.acceptCompletionReceipt(CompletionReceipt(queueSequence = 1L, receiptId = "desktop-1"))
        val waiting = ledger.load()
        assertEquals("the receipt itself must still persist", DeliveryState.CONFIRMED,
            waiting.items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals("cellular must not start the next head", listOf(1L), delivery.starts)
        assertEquals(ConsumerStatus.WAITING_FOR_CONSTRAINTS, waiting.consumerStatus)

        // Wi-Fi 回来：既有唤醒路径继续，第二张正常开跑。
        onWifi = true
        runner.run(constraintsSatisfied = true)
        assertEquals(listOf(1L, 2L), delivery.starts)
        dir.deleteRecursively()
    }

    // 卡面验收 2（入口覆盖）：失败终态重排 + 用户重试在蜂窝下同样不得外呼。
    @Test
    fun failure_requeue_and_user_retry_respect_the_live_gate() {
        val dir = tempDir("retry-gate")
        val ledger = DiscoveryLedgerStore(dir)
        val delivery = FakeDelivery()
        var onWifi = true
        val runner = FlowRunner(
            ledger,
            FakeDiscovery(DiscoveryPage(listOf(candidate(18)), DiscoveryCursor(7L, 18L))),
            delivery,
            constraintsProvider = { onWifi },
        )
        runner.requestDiscovery()
        runner.run(constraintsSatisfied = true)
        assertEquals(listOf(1L), delivery.starts)

        // 真实时序： Wi-Fi 下前两次瞬断（wake 重新租约继续重试），第三次
        // 失败前网络切到蜂窝——终态必须照常入账，重排不得外呼。
        runner.recordPermanentFailure() // attempt 1 on Wi-Fi -> re-queued + re-leased
        runner.recordPermanentFailure() // attempt 2 on Wi-Fi -> re-queued + re-leased
        onWifi = false
        runner.recordPermanentFailure() // attempt 3 -> terminal, gate closed
        assertEquals(DeliveryState.FAILED_NEEDS_USER,
            ledger.load().items.single { it.queueSequence == 1L }.deliveryState)
        // 用户在蜂窝下点「再试一次」：重排为 QUEUED，但零外呼。
        val startsBeforeRetry = delivery.starts.size
        runner.retryFailedDeliveries()
        val retried = ledger.load()
        assertEquals(DeliveryState.QUEUED, retried.items.single { it.queueSequence == 1L }.deliveryState)
        assertEquals("retry on cellular must not dial out",
            startsBeforeRetry, delivery.starts.size)
        assertEquals(ConsumerStatus.WAITING_FOR_CONSTRAINTS, retried.consumerStatus)

        onWifi = true
        runner.retryFailedDeliveries()
        assertEquals(startsBeforeRetry + 1, delivery.starts.size)
        dir.deleteRecursively()
    }

    // 卡面反证：把闸门判据从「实时状态」退回「常量 true/触发时快照」，本
    // 用例必红——直接扫源码，杜绝第二处硬编码复活（教训来源：本次 8 处
    // true 就是历史上逐个「顺手 wake(true)」攒出来的）。
    @Test
    fun no_production_wake_may_hardcode_the_gate() {
        var dir = File(checkNotNull(System.getProperty("user.dir")) { "user.dir unavailable" })
        while (!File(dir, "apps/android").isDirectory) {
            dir = checkNotNull(dir.parentFile) { "apps/android not found" }
        }
        val runner = File(
            dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/FlowRunner.kt",
        ).readText()
        assertFalse("event wakes must read the live gate, not a constant",
            runner.contains("wake(constraintsSatisfied = true)"))
        assertFalse("internal runs must read the live gate, not a constant",
            runner.contains("run(constraintsSatisfied = true)"))
        assertTrue("FlowRunner must hold the live-gate port",
            runner.contains("constraintsProvider()"))

        val runtime = File(
            dir, "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidFlowRuntime.kt",
        ).readText()
        assertFalse("framework wake entrypoints must default to the live gate",
            runtime.contains("constraintsSatisfied: Boolean = true"))
        assertTrue("wake defaults must compute the live constraint",
            runtime.contains("flowConstraintsSatisfied("))
    }
}
