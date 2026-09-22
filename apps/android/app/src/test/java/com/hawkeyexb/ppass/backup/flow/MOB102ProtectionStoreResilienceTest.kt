// MOB-102: #353 的修复自己会崩——「记录配额耗尽」这一步杀死了进程。
// 真机（三星 SM-S9210 / Android 15，配额压到 8 秒）两次 FATAL：
//   java.lang.IllegalStateException: cannot persist transfer protection state
//     at TransferProtectionStore.record(FlowTransferForegroundService.kt:94)
//     at ...startProtectedForeground(:167)  ← ppass-flow-wake 线程
//     at FlowTransferForegroundService.onStartCommand(:252) ← main 线程
//
// 两个根因，这里各钉一组用例：
//   一、`check()` 把一次可降级的诊断写入失败升级成 fatal。load() 那一半
//      早就定了口径「读不出来 = UNKNOWN = 三态里安全的那端」，写入侧必须
//      对称。
//   二、固定的 `.tmp` 名在并发下互相踩：先到的把 tmp 移走，后到的
//      renameTo 返回 false。真机 logcat 同一毫秒上有 ppass-flow-wake 与
//      main 两个线程同时走 Flow 唤醒。
//
// 为什么 MOB-101 的 7 例漏了：它们单线程、tempdir 干净、renameTo 必成功。
// 所以这里**真的起两个线程**，并**真的让写入失败**（目标路径占成目录 /
// 目录去掉写权限），不用 mock 糊。
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CyclicBarrier
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB102ProtectionStoreResilienceTest {

    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-mob102-$case").toFile()

    private val fileName = "flow-transfer-protection.json"
    private val budgetExhaustedMessage = "Time limit already exhausted for foreground service type dataSync"

    /** rename 失败：把目标路径占成一个目录，renameTo 必返回 false。 */
    private fun dirWhereRenameFails(case: String): File {
        val dir = tempDir(case)
        assertTrue(File(dir, fileName).mkdirs())
        return dir
    }

    // 根因一：记录诊断不得有杀死进程的权力。
    @Test
    fun record_never_throws_when_the_rename_cannot_succeed() {
        val store = TransferProtectionStore(dirWhereRenameFails("rename"))
        val persisted = store.record(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED, 1L)
        assertFalse("写不进去就是没写进去，如实返回 false，但绝不许抛", persisted)
    }

    @Test
    fun record_never_throws_when_the_directory_cannot_be_written() {
        val dir = tempDir("readonly")
        try {
            assertTrue(dir.setWritable(false))
            val persisted = TransferProtectionStore(dir)
                .record(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED, 1L)
            assertFalse(persisted)
        } finally {
            dir.setWritable(true)
        }
    }

    // 根因一（真机那条栈）：这条路径存在的全部理由就是接住失败，
    // 记录环节自己抛出去 = 又一次崩溃。
    @Test
    fun a_bookkeeping_failure_never_escapes_start_protected_foreground() {
        val store = TransferProtectionStore(dirWhereRenameFails("escape"))
        var paused = 0

        val outcome = startProtectedForeground(
            store = store,
            now = 1L,
            haltTransfer = { paused += 1 },
        ) {
            throw ForegroundServiceStartNotAllowedException(budgetExhaustedMessage)
        }

        assertEquals(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED, outcome)
        assertEquals("记录失败不许把暂停也带走——暂停才是保命的那一步", 1, paused)
    }

    // 暂停本身失败同样不许升级成崩溃。
    @Test
    fun a_failing_halt_never_escapes_either() {
        val store = TransferProtectionStore(tempDir("halt"))
        val outcome = startProtectedForeground(
            store = store,
            now = 1L,
            haltTransfer = { throw RuntimeException("writer is gone") },
        ) {
            throw ForegroundServiceStartNotAllowedException(budgetExhaustedMessage)
        }
        assertEquals(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED, outcome)
    }

    // 写不进去就是不知道：陈旧的「生效」不许被当成当前事实。
    @Test
    fun a_failed_write_must_not_leave_the_verdict_saying_effective() {
        val dir = tempDir("stale")
        val store = TransferProtectionStore(dir)
        assertTrue(store.record(ForegroundStartOutcome.STARTED, 1L))
        assertEquals(TransferProtection.EFFECTIVE, transferProtectionOf(store.load()))

        try {
            assertTrue(dir.setWritable(false))
            assertFalse(store.record(ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED, 2L))
            assertEquals(
                "落盘失败之后，硬盘上那句陈旧的「生效」不是当前事实——必须退回「未知」",
                TransferProtection.UNKNOWN,
                transferProtectionOf(TransferProtectionStore(dir).load()),
            )
        } finally {
            dir.setWritable(true)
        }
    }

    // 根因二：两个线程同时记录。反证——把 .tmp 名字改回固定值，
    // 这条必须变红（persisted 里会出现 false / 文件被写成半截）。
    @Test
    fun concurrent_records_never_throw_and_always_persist() {
        val dir = tempDir("concurrent")
        val store = TransferProtectionStore(dir)
        val rounds = 300
        val failures = CopyOnWriteArrayList<Throwable>()
        val notPersisted = java.util.concurrent.atomic.AtomicInteger(0)
        val barrier = CyclicBarrier(2)

        val threads = listOf(
            ForegroundStartOutcome.SYSTEM_BUDGET_EXHAUSTED,
            ForegroundStartOutcome.START_REFUSED,
        ).mapIndexed { index, outcome ->
            Thread({
                runCatching { barrier.await() }
                repeat(rounds) { round ->
                    try {
                        if (!store.record(outcome, (index * rounds + round).toLong())) {
                            notPersisted.incrementAndGet()
                        }
                    } catch (failure: Throwable) {
                        failures += failure
                    }
                }
            }, "ppass-mob102-$index")
        }
        threads.forEach { it.start() }
        threads.forEach { it.join(30_000) }

        assertTrue("并发记录不许抛：$failures", failures.isEmpty())
        assertEquals(
            "固定的 .tmp 名在并发下互相踩——每次记录都必须真的落盘",
            0,
            notPersisted.get(),
        )

        // 文件必须是一份完整合法的 JSON，不能是两个写者交错出来的半截。
        val text = File(dir, fileName).readText()
        val parsed = Json.parseToJsonElement(text).jsonObject
        val last = parsed["lastOutcome"]?.jsonPrimitive?.content
        assertTrue(
            "落盘内容必须是一个完整的 outcome，实际：$text",
            ForegroundStartOutcome.values().any { it.name == last },
        )
        assertTrue("临时文件必须收干净", dir.listFiles()?.none { it.name.endsWith(".tmp") } ?: false)
    }

    /** 与 `android.app.ForegroundServiceStartNotAllowedException` 同名同祖先的替身（判据按类名）。 */
    private class ForegroundServiceStartNotAllowedException(message: String) : IllegalStateException(message)
}
