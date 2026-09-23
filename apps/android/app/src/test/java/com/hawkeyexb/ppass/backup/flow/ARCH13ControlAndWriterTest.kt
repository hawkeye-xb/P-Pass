// ARCH-13 (#417)：暂停 / FGS 受阻事实的持久化，与单写者门禁（MOB-88 的继任者）。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.order.InMemoryOrderStore
import com.hawkeyexb.ppass.backup.order.NewOrder
import com.hawkeyexb.ppass.backup.order.OrderState
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ARCH13ControlAndWriterTest {
    private fun dir() = Files.createTempDirectory("ppass-arch13-control").toFile()

    // C-02：暂停是长期命令——杀 App 重开（新实例读盘）仍是暂停。
    @Test
    fun `pause survives a process restart`() {
        val d = dir()
        FlowControlStore(d).setPaused(true)
        assertTrue(FlowControlStore(d).paused())
        FlowControlStore(d).setPaused(false)
        assertFalse(FlowControlStore(d).paused())
    }

    // C-08 / #414：受阻事实持久化；进前台清除；能说清原因的（额度耗尽）不被随后的「被拒」覆盖。
    @Test
    fun `the foreground-blocked fact persists, keeps the explained reason, and clears on foreground`() {
        val d = dir()
        FlowControlStore(d).recordFgsBlock(FgsBlockReason.BUDGET_EXHAUSTED)
        FlowControlStore(d).recordFgsBlock(FgsBlockReason.START_REFUSED)
        assertEquals(FgsBlockReason.BUDGET_EXHAUSTED, FlowControlStore(d).fgsBlock())
        FlowControlStore(d).clearFgsBlock()
        assertNull(FlowControlStore(d).fgsBlock())
    }

    @Test
    fun `a corrupt control file reads as the safe default instead of crashing`() {
        val d = dir()
        java.io.File(d, FlowControlStore.FILE_NAME).writeText("{not json")
        assertFalse(FlowControlStore(d).paused())
        assertNull(FlowControlStore(d).fgsBlock())
    }

    // MOB-88 的不变量换了形式仍成立：绕过写者线程的写入当场抛，而不是静默竞争。
    // 反证：WriterGuardedOrderStore 的 write{} 不调 guard.assertAllowed() → 这条不再抛，红。
    @Test
    fun `order writes off the single writer thread throw on the spot`() {
        val writer = FlowWriter.start("test-writer")
        try {
            val store = WriterGuardedOrderStore(InMemoryOrderStore(), SingleThreadWrites(writer.thread))
            try {
                store.insert(NewOrder(1, "v", 7, "h", OrderState.QUEUED, "e1"))
                fail("a write from the test thread must be refused")
            } catch (expected: IllegalStateException) {
                assertTrue(expected.message!!.contains("single-writer"))
            }
            val inserted = kotlinx.coroutines.runBlocking(writer.dispatcher) {
                store.insert(NewOrder(1, "v", 7, "h", OrderState.QUEUED, "e1"))
            }
            assertEquals(inserted, store.get(inserted.id)) // 读不受限
        } finally {
            writer.shutdown()
        }
    }

    @Test
    fun `wait reasons - background switch and battery only gate automatic triggers, wifi gates everything`() {
        assertEquals(WaitReason.DISABLED, waitReasonOf(Conditions(autoBackupEnabled = false), userPresent = false))
        assertNull(waitReasonOf(Conditions(autoBackupEnabled = false), userPresent = true))
        assertEquals(WaitReason.BATTERY, waitReasonOf(Conditions(batteryLow = true), userPresent = false))
        assertNull(waitReasonOf(Conditions(batteryLow = true), userPresent = true))
        assertEquals(WaitReason.WIFI, waitReasonOf(Conditions(wifiOnly = true, onUnmetered = false), userPresent = true))
        assertEquals(WaitReason.FGS_BLOCKED, waitReasonOf(Conditions(fgsBlocked = true), userPresent = true))
        assertEquals(WaitReason.NOT_PAIRED, waitReasonOf(Conditions(paired = false), userPresent = true))
    }
}
