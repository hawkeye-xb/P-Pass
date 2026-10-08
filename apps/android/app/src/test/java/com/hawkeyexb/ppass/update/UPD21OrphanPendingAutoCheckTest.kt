// UPD-21: 落盘待办在、WorkManager 记录已被剪（终态满 1 天 + 进程重启即剪）⇒
// 自动检查不许永久跳过：清掉孤儿待办、照常检查；记录还活着则照旧跳过。
package com.hawkeyexb.ppass.update

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class UPD21OrphanPendingAutoCheckTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val pending = PendingUpdate(version = "0.9.6", url = "https://x/a.apk")
    private val now = 10L * AUTO_CHECK_INTERVAL_MS

    private fun prefsWithPending(): UpdatePrefs =
        UpdatePrefs(tmp.newFolder()).apply { markPending(pending) }

    @Test
    fun orphanPendingIsClearedAndAutoCheckRuns() = runTest {
        val prefs = prefsWithPending()
        var checks = 0
        val orphaned = mutableListOf<String>()
        val ran = runAutoCheck(
            prefs = prefs,
            now = { now },
            isIdle = { true },
            readWorkSignal = { WorkSignal.None }, // 记录被剪 ⇒ 查不到 WorkInfo
            check = { checks++ },
            onOrphanCleared = { orphaned += it },
        )
        assertTrue("记录被剪后自动检查必须照常发起", ran)
        assertEquals(1, checks)
        assertNull("孤儿待办必须清掉，否则下次仍被它挡住", prefs.pendingUpdate())
        assertEquals(listOf("0.9.6"), orphaned)
        assertEquals(now, prefs.lastCheckAt())
    }

    @Test
    fun liveWorkRecordStillSkipsAndKeepsPending() = runTest {
        for (signal in listOf(
            WorkSignal.Enqueued, WorkSignal.Running, WorkSignal.Succeeded, WorkSignal.Failed,
        )) {
            val prefs = prefsWithPending()
            var checks = 0
            val ran = runAutoCheck(
                prefs = prefs,
                now = { now },
                isIdle = { true },
                readWorkSignal = { signal },
                check = { checks++ },
            )
            assertFalse("$signal: 更新线还活着，不许再查", ran)
            assertEquals(0, checks)
            assertEquals(pending, prefs.pendingUpdate())
        }
    }

    @Test
    fun throttleGateStillAppliesBeforeTouchingPending() = runTest {
        val prefs = prefsWithPending().apply { markChecked(now - 1) }
        var read = false
        val ran = runAutoCheck(
            prefs = prefs,
            now = { now },
            isIdle = { true },
            readWorkSignal = { read = true; WorkSignal.None },
            check = {},
        )
        assertFalse(ran)
        assertFalse("6h 门内不该读 work 记录", read)
        assertEquals(pending, prefs.pendingUpdate())
    }

    @Test
    fun nonIdleNeverClearsPending() = runTest {
        val prefs = prefsWithPending()
        val ran = runAutoCheck(
            prefs = prefs,
            now = { now },
            isIdle = { false },
            readWorkSignal = { WorkSignal.None },
            check = {},
        )
        assertFalse(ran)
        assertEquals(pending, prefs.pendingUpdate())
    }
}
