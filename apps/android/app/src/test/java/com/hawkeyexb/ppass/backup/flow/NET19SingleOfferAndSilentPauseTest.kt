// NET-19：交付路径两项纪律的断言锁（NET-06 验收挂账的两项，做完回勾）。
//
// 1) **重试不互踩**：一次完整的交付里 `offer` 恰好调用 1 次。行为上现状
//    已满足（`desktop.offer` 全文件唯一调用点、在等待循环外），本用例把
//    「只此一次」从注释承诺升级为可执行断言——谁日后在重试路径里再调
//    offer，此用例变红。
// 2) **暂停不观察（NET-06 原则 1：意图先行，不等回声）**：暂停路径
//    （`NativeFlowDeliveryPort.stop`）零 `status()` 查询、零二次 offer，
//    且**不等待**对端回声——桌面通知（`flow.cancel`，命令而非观察）
//    挂死 30s 时 `stop()` 仍须立即返回。
//
// 形状说明：`NativeFlowDeliveryPort` 的 `desktopFor` 是现成测试缝
// （AuditOutboxDispatcher.transportFor 同款），行为测试直接驱动真
// `start()`/`stop()`，fake `FlowReceiptClient` 逐方法计数。`start()`
// 的前置段需要 ContentResolver（hashSource 只在 contentHash 缺失时才
// 读流——fixture 预置 hash 即不触达）；JVM 里 `android.util.Log` 是
// 抛 Stub! 的桩，故对含日志的行用仓内 NET-24 同款源码断言兜底。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.proto.FlowCompletionReceipt
import com.hawkeyexb.ppass.proto.FlowFetchRequest
import com.hawkeyexb.ppass.proto.FlowStatusReply
import com.hawkeyexb.ppass.proto.FlowTupleRef
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.Pairing
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NET19SingleOfferAndSilentPauseTest {

    // ── fixtures ─────────────────────────────────────────────────────────

    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-net19-$case").toFile()

    private fun seededStoreWithHash(dir: File, hash: String): DiscoveryLedgerStore =
        DiscoveryLedgerStore(dir).also { store ->
            store.commitDiscoveryPage(
                listOf(
                    DiscoveryCandidate(
                        sourceRef = "content://media/external/images/media/1",
                        sourceVersion = "generation-7",
                        bucketId = 42L,
                    ),
                ),
                DiscoveryCursor(lastGeneration = 7L, lastMediaId = 1L),
            )
            // contentHash 预置：start() 的 hashSource 只在缺失时读 MediaStore 流，
            // JVM 里没有也不该有真内容可读。pairingEpoch 同步对齐 fake 的
            // advertised epoch——三方（item/snapshot/pairing）不一致会被
            // start() 的 epoch 前置检查或 NET-22 refresh 路径拦下。
            store.update { snapshot ->
                snapshot.copy(
                    pairingEpoch = PairingEpoch(EPOCH),
                    items = snapshot.items.map { it.copy(contentHash = hash, pairingEpoch = PairingEpoch(EPOCH)) },
                )
            }
        }

    private class FakeNativeProvider : NativeIrohBlobsProvider {
        val events = mutableListOf<String>()
        override fun register(hash: String, source: Any): String = "ticket:$hash"
        override fun stopActiveFetch(queueSequence: Long) { events += "stop:$queueSequence" }
        override fun releaseRetention(hash: String) { events += "release:$hash" }
        override fun revoke(hash: String) { events += "revoke:$hash" }
        // 本地信号 = 无租约：等待循环据此走 CheckStatusNow（NET-14 判别表），
        // 让 fake 的 status 计数可控地动起来。
        override fun transferStatus(): String = "{\"state\":\"no_lease\"}"
    }

    /** 逐方法计数的假对端；`cancelHangMs` 用来检验「暂停不等回声」。 */
    private class FakeDaemonProbe(
        private val epoch: String,
        private val offerReply: FlowStatusReply,
        private val statusReplies: List<FlowStatusReply>,
        private val cancelHangMs: Long = 0L,
    ) : FlowReceiptClient {
        val counts = ConcurrentHashMap<String, AtomicInteger>()
        private fun bump(method: String) = counts.computeIfAbsent(method) { AtomicInteger() }.incrementAndGet()
        fun count(method: String): Int = counts[method]?.get() ?: 0

        override suspend fun currentPairingEpoch(): String? {
            bump("currentPairingEpoch")
            return epoch
        }

        override suspend fun offer(request: FlowFetchRequest): FlowStatusReply {
            bump("offer")
            return offerReply
        }

        override suspend fun status(tuple: FlowTupleRef): FlowStatusReply {
            val n = bump("status")
            // 计数用尽后挂住（delay 可被 scope.cancel 打断）：保证观察窗内
            // 不会再冒出计划外的 status，计数断言才干净。
            return statusReplies.getOrElse(n - 1) { delay(60_000); error("unreachable") }
        }

        override suspend fun fetch(request: FlowFetchRequest): FlowCompletionReceipt {
            bump("fetch")
            error("the async delivery path must never call fetch()")
        }

        override suspend fun cancel(request: FlowFetchRequest) {
            bump("cancel")
            if (cancelHangMs > 0) delay(cancelHangMs)
        }

        fun awaitCount(method: String, atLeast: Int, timeoutMs: Long = 5_000) {
            val deadline = System.currentTimeMillis() + timeoutMs
            while (count(method) < atLeast) {
                if (System.currentTimeMillis() > deadline) {
                    throw AssertionError("$method 调用次数未达 $atLeast（实际 ${count(method)}）")
                }
                Thread.sleep(20)
            }
        }
    }

    private fun receiptFor(hash: String) = FlowCompletionReceipt(
        queueSequence = 1L,
        receiptId = "desktop-1",
        pairingEpoch = EPOCH,
        leaseToken = "lease-1",
        contentHash = hash,
    )

    private fun pairing(): Pairing = Pairing(
        daemonNodeId = "a".repeat(64),
        daemonAddrToken = "addr-" + "b".repeat(64) + "%rel?",
        storageDeviceName = "Desktop",
        pairingEpoch = EPOCH,
    )

    // ── 行为测试 1：一次完整交付，offer 恰好 1 次 ─────────────────────────

    @Test
    fun a_full_delivery_calls_offer_exactly_once() {
        val dir = tempDir("single-offer")
        val hash = "c".repeat(64)
        val ledger = seededStoreWithHash(dir, hash)
        val head = ledger.load().items.first()
        val lease = FetchLease(queueSequence = head.queueSequence, leaseToken = "lease-1")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val fake = FakeDaemonProbe(
            epoch = EPOCH,
            // NET-24 路径：offer 应答直接携带终态 → 当场收账、结束本轮。
            // 这正是「一次 offer 就完整走完」的最小真实形状；等待循环
            // 「不再调 offer」由源码断言单独锁（见下）。
            offerReply = FlowStatusReply(state = "completed", receipt = receiptFor(hash), taskRunning = false),
            statusReplies = emptyList(),
        )
        val receipts = CopyOnWriteArrayList<CompletionReceipt>()
        val port = NativeFlowDeliveryPort(
            ledger = ledger,
            bridge = IrohBlobsProviderBridge(FakeNativeProvider()) { "fd:$it" },
            resolver = object : android.content.ContentResolver(null) {},
            pairing = { pairing() },
            identityKey = { ByteArray(32) },
            client = DaemonClient(),
            onMissingSource = { },
            onPermanentFailure = { },
            onReceipt = { receipts += it },
            onPairingEpochRefreshed = { },
            scope = scope,
            desktopFor = { fake },
        )

        port.start(item = head, resumePartial = false, lease = lease)
        fake.awaitCount("offer", 1)
        // 等结账落定（receipts 由 acceptReceipt 同步写入，轮询到超时为止）。
        val deadline = System.currentTimeMillis() + 5_000
        while (receipts.isEmpty() && System.currentTimeMillis() < deadline) Thread.sleep(20)
        scope.cancel()

        assertEquals("NET-19①: offer 必须恰好调用 1 次", 1, fake.count("offer"))
        assertEquals("完成路径不得用 fetch() 一把赌", 0, fake.count("fetch"))
        assertEquals("结账的收据必须是 offer 应答里那份", "desktop-1", receipts.single().receiptId)
        dir.deleteRecursively()
    }

    // ── 行为测试 2：暂停零查询 + 不等回声 ────────────────────────────────

    @Test
    fun pause_asks_nothing_of_the_peer_and_never_waits_for_an_echo() {
        val dir = tempDir("silent-pause")
        val hash = "d".repeat(64)
        val ledger = seededStoreWithHash(dir, hash)
        val head = ledger.load().items.first()
        val lease = FetchLease(queueSequence = head.queueSequence, leaseToken = "lease-1")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val fake = FakeDaemonProbe(
            epoch = EPOCH,
            // active：进入等待循环（NET-06 异步主路径）。
            offerReply = FlowStatusReply(state = "active", taskRunning = true),
            // 第一次 status 回来保持 active（任务进入 backoff delay）；
            // 之后的 status 挂 60s——观察窗内计数不会自己动，断言才干净。
            statusReplies = listOf(FlowStatusReply(state = "active", taskRunning = true)),
            // 桌面通知挂死 30s：若暂停实现「等回声」，stop() 会跟着卡 30s。
            cancelHangMs = 30_000,
        )
        val port = NativeFlowDeliveryPort(
            ledger = ledger,
            bridge = IrohBlobsProviderBridge(FakeNativeProvider()) { "fd:$it" },
            resolver = object : android.content.ContentResolver(null) {},
            pairing = { pairing() },
            identityKey = { ByteArray(32) },
            client = DaemonClient(),
            onMissingSource = { },
            onPermanentFailure = { },
            onReceipt = { },
            onPairingEpochRefreshed = { },
            scope = scope,
            desktopFor = { fake },
        )

        port.start(item = head, resumePartial = false, lease = lease)
        fake.awaitCount("status", 1) // 任务已正常进入等待循环

        val statusBefore = fake.count("status")
        val t0 = System.nanoTime()
        val disposition = port.stop(head.queueSequence)
        val stopMs = (System.nanoTime() - t0) / 1_000_000

        assertTrue(
            "NET-19②: 暂停是对本地拉取的控制动作（bridge.pause），不得经对端查询",
            statusBefore == fake.count("status"),
        )
        assertEquals("NET-19②: 暂停路径不得重发 offer", 1, fake.count("offer"))
        assertTrue(
            "NET-06 原则 1: 暂停不得同步等待任何对端调用（含桌面通知的返回值）；" +
                "cancel 被挂死 30s 时本断言即计时器——stop() 必须在 2 秒内返回",
            stopMs < 2_000,
        )
        assertEquals("暂停=保留 partial（与取消的落账相反）", PartialDisposition.RETAINED, disposition)
        // cancel 此刻可能已被 launch 派发（bump 先于挂起），不能断言"还没发"；
        // 「不等回声」由上面的 stopMs 计时断言锁定，「最终发出」由 awaitCount 锁定。

        // 通知是尽力而为：异步派发、最终发出（挂死不影响它被发起）。
        fake.awaitCount("cancel", 1)
        Thread.sleep(300)
        assertEquals("NET-19②: 暂停之后不得有任何新的观察类查询", statusBefore, fake.count("status"))
        assertEquals("暂停不得重发 offer", 1, fake.count("offer"))
        scope.cancel()
        dir.deleteRecursively()
    }

    // ── 源码断言（锁 android.util.Log 在 JVM 不可执行的剩余不变量）──────

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return dir
    }

    private fun codeOf(file: File): String =
        file.readText()
            .replace(Regex("/\\*[\\s\\S]*?\\*/"), "")
            .lines()
            .filterNot { it.trimStart().startsWith("//") }
            .joinToString("\n")

    private fun portSource(): String = codeOf(
        File(
            repoRoot(),
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/NativeFlowDeliveryPort.kt",
        ),
    )

    private fun memberBody(code: String, signature: Regex): String {
        val start = signature.find(code) ?: error("找不到成员：$signature——结构变了，请重新表述本断言")
        var depth = 0
        var i = code.indexOf('{', start.range.first)
        if (i < 0) error("成员没有函数体：$signature")
        val bodyStart = i
        while (i < code.length) {
            when (code[i]) {
                '{' -> depth += 1
                '}' -> {
                    depth -= 1
                    if (depth == 0) return code.substring(bodyStart, i + 1)
                }
            }
            i += 1
        }
        error("大括号不配平：$signature")
    }

    @Test
    fun offer_has_exactly_one_call_site_in_the_whole_port() {
        val code = portSource()
        val callSites = Regex("""desktop\.offer\(""").findAll(code).count()
        assertEquals(
            "NET-19①: 等待循环里再调 offer = 网络抖动时产生两个竞争 grant（旧事故形状）。" +
                "offer 调用点必须全文件唯一（行为锁见 a_full_delivery_calls_offer_exactly_once）",
            1,
            callSites,
        )
        // 且这唯一一处必须位于 start() 体内、等待循环（pushChannel）建立之前——
        // NET-24 消费 offer 应答的前提。
        val startBody = memberBody(code, Regex("override fun start\\("))
        val loopStart = Regex("""val pushChannel""").find(startBody) ?: error("等待循环结构变了")
        val offerInBody = Regex("""desktop\.offer\(""").find(startBody)
            ?: error("offer 调用点不在 start() 体内——移动位置需同步重审本断言")
        assertEquals("start() 体内 offer 只准有一处调用", 1, Regex("""desktop\.offer\(""").findAll(startBody).count())
        assertTrue(
            "offer 必须早于推送订阅/等待循环建立（NET-24 顺序不变量的另一半）",
            offerInBody.range.first < loopStart.range.first,
        )
    }

    @Test
    fun stop_path_queries_nothing_and_its_notification_is_fire_and_forget() {
        val code = portSource()
        val stopBody = memberBody(code, Regex("override fun stop\\("))
        for (forbidden in listOf("status(", "offer(", "fetch(", "currentPairingEpoch(")) {
            assertTrue(
                "NET-19②/NET-06 原则 1: 暂停路径不得发起观察类查询 `$forbidden`" +
                    "（行为锁见 pause_asks_nothing_of_the_peer_and_never_waits_for_an_echo）",
                !stopBody.contains(forbidden),
            )
        }
        // 桌面通知必须包在 scope.launch 里（发出不等回声）；launch 块外
        // 出现任何 `.cancel(` = 同步等回声，即红。
        val launchAnchor = Regex("""scope\.launch""").find(stopBody)
            ?: error("NET-19②: 暂停的桌面通知必须是尽力而为的异步派发（scope.launch 包裹）")
        val launchOpen = stopBody.indexOf('{', launchAnchor.range.last)
        var depth = 0
        var j = launchOpen
        while (j < stopBody.length) {
            when (stopBody[j]) {
                '{' -> depth += 1
                '}' -> { depth -= 1; if (depth == 0) break }
            }
            j += 1
        }
        val launchBlock = launchOpen..j
        for (m in Regex("""\.cancel\(""").findAll(stopBody)) {
            assertTrue(
                "NET-06 原则 1: stop() 里的 `.cancel(` 必须整体位于 scope.launch 块内——" +
                    "块外调用 = 暂停同步等待对端回声",
                m.range.first in launchBlock,
            )
        }
    }

    companion object {
        private const val EPOCH = "epoch-1"
    }
}
