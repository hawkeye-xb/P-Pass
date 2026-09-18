package com.hawkeyexb.ppass.backup.flow

import java.io.File
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * MOB-88 门禁：账本只能由单写者写。
 *
 * 取代 `MOB56CallbackLockGuardTest`（那道门检查的是「每个 `runner.*` 调用
 * 必须在 `synchronized(flowTriggerLock)` 词法范围内」——守的是约定，而且有
 * 盲区：它只看 `runner.*`，挡不住 `PairingEpochController` / 审计外发 /
 * `load()` 里的补写这三条同样绕过锁的路径）。
 *
 * 现在不变量换成了结构性的：**状态变更只出现在 reducer 里，落盘只发生在
 * 写者线程上**，绕过者当场抛异常而不是静默覆盖。
 */
class MOB88SingleWriterTest {
    @get:Rule
    val folder = TemporaryFolder()

    private fun runtimeSource(): String =
        File("src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidFlowRuntime.kt").readText()

    // ── 门禁一：那把靠自觉去拿的锁必须彻底消失 ──────────────
    @Test
    fun the_trigger_lock_no_longer_exists_in_production_sources() {
        val offenders = File("src/main/java/com/hawkeyexb/ppass")
            .walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { file ->
                file.readLines().any { line ->
                    "synchronized(flowTriggerLock)" in line || "val flowTriggerLock" in line
                }
            }
            .map { it.name }
            .toList()
        assertTrue(
            "flowTriggerLock must be gone — 单写者之后不该再有「记得加锁」这回事：$offenders",
            offenders.isEmpty(),
        )
    }

    // ── 门禁二：状态变更只许出现在 reducer 里 ────────────────
    @Test
    fun every_state_mutation_in_the_runtime_lives_inside_the_reducer() {
        val source = blankCommentsAndStrings(runtimeSource())
        val reduceStart = source.indexOf("private fun AndroidFlowRuntime.reduce(")
        assertTrue("reducer 不见了——这道门禁的前提就没了", reduceStart >= 0)
        val reduceEnd = endOfFunction(source, reduceStart)

        // 会改状态的调用。`ledger.load()` 是读，不在其列。
        val mutation = Regex(
            """\brunner\.[A-Za-z_][A-Za-z0-9_]*\s*\(""" +
                """|\bledger\.update\s*\{""" +
                """|\bledger\.(?:acknowledgeAuditEvents|migrateMissingCompletedAt|commitDiscoveryPage|commitScopeBackfill|startCancellationRound)\s*\(""" +
                """|\bPairingEpochController\s*\(""",
        )
        val hits = mutation.findAll(source).toList()
        val outside = hits.filterNot { it.range.first in reduceStart..reduceEnd }
            .map { "  行 ${lineOf(source, it.range.first)}: ${it.value.trim()}" }

        // 反空转：命名一变（`runner` → `flowRunner`）正则就会扫不到东西，
        // 上面的断言会在空集上无条件通过。基线是 2026-09-18 的 18 处。
        assertTrue(
            "expected at least 15 state-mutating call sites, found ${hits.size} — 扫描模式已失效，这道门禁是空的",
            hits.size >= 15,
        )
        assertTrue(
            "账本状态变更出现在 reducer 之外（单写者之后只允许 reducer 改状态）：\n" + outside.joinToString("\n"),
            outside.isEmpty(),
        )
    }

    // ── 行为一：绕过写者线程落盘，当场抛，不静默 ─────────────
    @Test
    fun writing_the_ledger_off_the_writer_thread_fails_loudly() {
        val writer = FlowWriter.start("test-writer")
        try {
            val ledger = DiscoveryLedgerStore(
                repository = JsonFileFlowLedgerRepository(folder.newFolder()),
                writeGuard = SingleThreadLedgerWrites(writer.thread),
            )
            try {
                ledger.update { it.copy(consumerGate = ConsumerGate.PAUSED_BY_USER) }
                fail("写者线程之外的落盘必须抛异常——静默覆盖正是 MOB-88 要消灭的东西")
            } catch (expected: IllegalStateException) {
                assertTrue(
                    "异常要说清是谁在越界：${expected.message}",
                    expected.message.orEmpty().contains("off the single-writer thread"),
                )
            }
            // 同一次写入换到写者线程上就该成功。
            writer.bind { action -> if (action is FlowAction.AcknowledgeAuditEvents) ledger.update { it } }
            writer.dispatchAndAwait(FlowAction.AcknowledgeAuditEvents(setOf("noop")))
        } finally {
            writer.shutdown()
        }
    }

    // ── 行为二：并发触发不再能撞出双发 ───────────────────────
    //
    // 对照 `ARCH01StrictConsumerTest.concurrent_wake_without_external_
    // synchronization_is_unsafe`：那条用例证明**不加外部同步**地并发
    // wake() 是不安全的（双 start 或 persist 写冲突）。这条证明同样的
    // 两个线程改成投给写者之后，同一个 queueSequence 只会被 start 一次。
    @Test
    fun concurrent_triggers_through_the_writer_never_double_start() {
        repeat(20) { round ->
            val writer = FlowWriter.start("test-writer-$round")
            try {
                val dir = folder.newFolder()
                val ledger = DiscoveryLedgerStore(
                    repository = JsonFileFlowLedgerRepository(dir),
                    writeGuard = SingleThreadLedgerWrites(writer.thread),
                )
                val started = java.util.Collections.synchronizedList(mutableListOf<Long>())
                val delivery = object : DeliveryPort {
                    override fun start(item: TransferItem, resumePartial: Boolean, lease: FetchLease) {
                        // 起飞里 sleep 一下放大竞态窗口，和 ARCH-01 那条
                        // RED 用例同样的手法。
                        Thread.sleep(5)
                        started += item.queueSequence
                    }

                    override fun stop(queueSequence: Long) = PartialDisposition.DISCARDED
                }
                val consumer = StrictConsumer(ledger, delivery)
                writer.bind { action -> if (action is FlowAction.Wake) consumer.wake(action.constraintsSatisfied) }
                // 先放一个候选进去（在写者线程上，门禁要求）。
                writer.dispatchAndAwait(FlowAction.AcknowledgeAuditEvents(emptySet()))
                seedOneCandidate(writer, ledger)

                val barrier = CyclicBarrier(2)
                val threads = (1..2).map {
                    Thread {
                        barrier.await()
                        writer.dispatch(FlowAction.Wake(constraintsSatisfied = true))
                    }
                }
                threads.forEach { it.start() }
                threads.forEach { it.join() }
                // 等队列排空
                writer.dispatchAndAwait(FlowAction.AcknowledgeAuditEvents(emptySet()))
                Thread.sleep(30)
                writer.dispatchAndAwait(FlowAction.AcknowledgeAuditEvents(emptySet()))

                assertEquals(
                    "同一个 queueSequence 被 start 了多次（第 $round 轮）：$started",
                    started.distinct().size,
                    started.size,
                )
            } finally {
                writer.shutdown()
            }
        }
    }

    // ── 行为三：action 顺序执行，且全部落在同一条线程上 ──────
    @Test
    fun actions_run_one_at_a_time_on_a_single_thread() {
        val writer = FlowWriter.start("test-writer-serial")
        try {
            val threads = java.util.Collections.synchronizedSet(mutableSetOf<String>())
            val concurrent = AtomicInteger(0)
            val maxConcurrent = AtomicInteger(0)
            val done = AtomicInteger(0)
            writer.bind {
                threads += Thread.currentThread().name
                val now = concurrent.incrementAndGet()
                maxConcurrent.updateAndGet { maxOf(it, now) }
                Thread.sleep(1)
                concurrent.decrementAndGet()
                done.incrementAndGet()
            }
            val barrier = CyclicBarrier(4)
            val senders = (1..4).map {
                Thread {
                    barrier.await()
                    repeat(10) { writer.dispatch(FlowAction.Pause) }
                }
            }
            senders.forEach { it.start() }
            senders.forEach { it.join() }
            writer.dispatchAndAwait(FlowAction.Pause)

            assertEquals("所有 action 都该跑完", 41, done.get())
            assertEquals("action 不允许并发执行", 1, maxConcurrent.get())
            assertEquals("action 必须全部落在同一条写者线程上：$threads", 1, threads.size)
        } finally {
            writer.shutdown()
        }
    }

    /** 塞一个待传候选。写入门禁要求这一步也在写者线程上做。 */
    private fun seedOneCandidate(writer: FlowWriter, ledger: DiscoveryLedgerStore) {
        val candidate = DiscoveryCandidate(
            sourceRef = "content://seed/1",
            sourceVersion = "1:1:1",
            bucketId = 1L,
            fileName = "seed.jpg",
            mediaType = "image/jpeg",
            captureAtMs = 1L,
        )
        writer.runOnWriter {
            ledger.commitDiscoveryPage(listOf(candidate), DiscoveryCursor(1L, 1L), discoveryRequested = false)
        }
    }

    private fun endOfFunction(source: String, start: Int): Int {
        var depth = 0
        var seenOpen = false
        for (i in start until source.length) {
            when (source[i]) {
                '{' -> { depth++; seenOpen = true }
                '}' -> {
                    depth--
                    if (seenOpen && depth == 0) return i
                }
            }
        }
        return source.length
    }

    private fun lineOf(source: String, index: Int): Int =
        source.take(index).count { it == '\n' } + 1

    /** 注释与字符串整段置空：位置不变，里面的花括号不再干扰配平。 */
    private fun blankCommentsAndStrings(source: String): String {
        val out = StringBuilder(source)
        var i = 0
        fun blankUntil(end: Int) {
            for (j in i until minOf(end, source.length)) if (out[j] != '\n') out[j] = ' '
        }
        while (i < source.length) {
            when {
                source.startsWith("//", i) -> {
                    val end = source.indexOf('\n', i).let { if (it < 0) source.length else it }
                    blankUntil(end); i = end
                }
                source.startsWith("/*", i) -> {
                    val end = source.indexOf("*/", i).let { if (it < 0) source.length else it + 2 }
                    blankUntil(end); i = end
                }
                source[i] == '"' -> {
                    var j = i + 1
                    while (j < source.length && source[j] != '"' && source[j] != '\n') {
                        if (source[j] == '\\') j += 1
                        j += 1
                    }
                    val end = minOf(j + 1, source.length)
                    blankUntil(end); i = end
                }
                else -> i += 1
            }
        }
        return out.toString()
    }
}
