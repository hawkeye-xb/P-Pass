// #1119：断开清单取消全部相关后台任务——用 WorkManager 的测试工具（同步执行器）真排上九条 unique work，
// 跑生产里同一个 applyDisconnectManifest，再查每一条 unique work 的状态。
// 反证：把清单里任何一行 STOP 改回 KEEP、或少列一个任务名 → 对应那条仍是 ENQUEUED，断言失败。
//
// 在设备上跑（connectedDebugAndroidTest）；lane 里只编译（compileDebugAndroidTestKotlin）。
package com.hawkeyexb.ppass.backup

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.Configuration
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.testing.WorkManagerTestInitHelper
import androidx.work.Constraints
import androidx.work.NetworkType
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DisconnectCancelsWorkDeviceTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val names = listOf(
        BACKUP_WORK_NAME, CATCHUP_WORK_NAME, PROCESS_CATCHUP_WORK_NAME, MANUAL_BACKUP_WORK_NAME,
        CONSTRAINT_WAKE_WORK_NAME, MEDIA_WATCH_BACKUP_WORK_NAME,
        UNREACHABLE_PROBE_LADDER_WORK_NAME, BUDGET_RESET_WAKE_WORK_NAME, RESUME_SENTINEL_WORK_NAME,
    )

    @Before
    fun initWorkManager() {
        WorkManagerTestInitHelper.initializeTestWorkManager(context, Configuration.Builder().build())
    }

    @Test
    fun manual_disconnect_cancels_all_nine_unique_works_and_empties_the_caches() {
        val wm = WorkManager.getInstance(context)
        // 带一个永远不满足的约束，保证它们留在 ENQUEUED（不会被测试执行器立刻跑掉）。
        val never = Constraints.Builder().setRequiredNetworkType(NetworkType.UNMETERED).setRequiresCharging(true).build()
        names.forEach { name ->
            wm.enqueueUniqueWork(name, ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<BackupWorker>().setConstraints(never).build()).result.get()
            assertEquals(name, WorkInfo.State.ENQUEUED, wm.getWorkInfosForUniqueWork(name).get().single().state)
        }
        val root = File(context.cacheDir, "disconnect-test").apply { deleteRecursively(); mkdirs() }
        val files = File(root, "files").apply { mkdirs() }
        val cache = File(root, "cache").apply { mkdirs() }
        File(cache, "video-0123456789abcdef.mp4").writeText("x")
        File(cache, "video-0123456789abcdef.mp4.part").writeText("x")
        File(cache, "share").mkdirs()
        File(cache, "share/asset-1").writeText("x")

        applyDisconnectManifest(
            files, cache,
            object : DisconnectRuntime {
                override fun stopFlowRuntime() = Unit
                override fun cancelUniqueWork(name: String) { wm.cancelUniqueWork(name).result.get() }
                override fun cancelMediaWatch() = Unit
                override fun clearPreviewCache() = Unit
            },
        )

        for (name in names) {
            val infos = wm.getWorkInfosForUniqueWork(name).get()
            assertTrue("$name 断开后必须已取消，实际 ${infos.map { it.state }}", infos.all { it.state == WorkInfo.State.CANCELLED })
        }
        assertEquals("原图缓存必须清空", emptyList<String>(), cache.list().orEmpty().toList())
        root.deleteRecursively()
    }
}
