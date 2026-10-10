// #719: 同一时刻只有一条更新线；被顶替的旧下载不许碰新线的东西。
//
// 本质：两个 Worker 共用同一个文件、界面状态没绑到具体请求。标准做法：
//  1. 产物按身份分目录（内容寻址）——不同版本的 Worker 物理上碰不到对方的文件；
//  2. 被停的 Worker 按 WorkManager 约定尽快停手（downloadApk 的 isStopped）；
//  3. 待办绑定请求 id，界面只认这个 id 的信号；同一份更新重复提交 = 幂等。
package com.hawkeyexb.ppass.update

import androidx.work.WorkInfo
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UPD719UpdateLineOwnershipTest {

    private val dir = File(System.getProperty("java.io.tmpdir"), "upd719-${System.nanoTime()}")
    private val v1 = downloadIdentityOf("0.9.11", "https://example.invalid/v1.apk", "aa".repeat(32))
    private val v2 = downloadIdentityOf("0.9.12", "https://example.invalid/v2.apk", "bb".repeat(32))

    @After
    fun cleanup() {
        dir.deleteRecursively()
    }

    private class FakeConn(
        private val code: Int,
        private val body: () -> InputStream = { ByteArrayInputStream(ByteArray(0)) },
        private val length: Long = -1,
    ) : HttpURLConnection(URL("https://example.invalid/ppass.apk")) {
        override fun connect() {}
        override fun getResponseCode(): Int = code
        override fun getHeaderField(name: String): String? = null
        override fun getInputStream(): InputStream {
            if (code >= 400) throw java.io.FileNotFoundException(url.toString())
            return body()
        }
        override fun getContentLengthLong(): Long = length
        override fun disconnect() {}
        override fun usingProxy() = false
    }

    // ── 1. 产物按身份分目录 ──

    @Test
    fun differentUpdatesNeverShareAFile() {
        val a = updateArtifactsOf(dir, v1)
        val b = updateArtifactsOf(dir, v2)
        assertTrue(a.dir != b.dir && a.apk != b.apk && a.marker != b.marker)
        assertEquals("同一份更新永远落在同一处（残包可续）", a.dir, updateArtifactsOf(dir, v1).dir)
        assertEquals(updateRootDir(dir), a.dir.parentFile)
    }

    /**
     * 现场：v1 的 Worker 被 REPLACE 后还在跑，最终放弃并做失败清理；此时 v2 正在写自己的残包。
     * 反证：让 [artifactKeyOf] 对所有身份返回同一个值（= 改回共用一个文件），本测试红。
     */
    @Test
    fun replacedWorkersFailureCleanupNeverTouchesTheNewLine() {
        val v2Artifacts = updateArtifactsOf(dir, v2).also { it.dir.mkdirs() }
        v2Artifacts.apk.writeBytes(ByteArray(1500) { 9 }) // v2 正在写的残包

        // v1 的旧 Worker 这一跑以 404 放弃：按规矩删「它自己的」产物。
        val v1Artifacts = updateArtifactsOf(dir, v1).also { it.dir.mkdirs() }
        val settled = settleDownload(
            downloadApk("https://example.invalid/v1.apk", v1Artifacts.apk, open = { FakeConn(404) }),
            v1Artifacts.apk, v1Artifacts.marker, runAttemptCount = 0, verify = { ApkVerifier.Result.Ok },
        )

        assertEquals(DownloadSettlement.Failed(UpdateFailureKind.Server), settled)
        assertEquals("v2 的残包一个字节都不许少", 1500L, v2Artifacts.apk.length())
    }

    // ── 2. 被停的 Worker 停手、不动产物 ──

    @Test
    fun stoppedWorkerStopsWritingAndLeavesArtifactsAlone() {
        val artifacts = updateArtifactsOf(dir, v2).also { it.dir.mkdirs() }
        var stopped = false
        val body = object : InputStream() {
            var served = 0
            override fun read(): Int = throw UnsupportedOperationException()
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (served >= 2) return -1
                served++
                stopped = true // 第一块读完后 Worker 被停（取消 / 被新下载顶替）
                val n = minOf(len, 1000)
                java.util.Arrays.fill(b, off, off + n, 5)
                return n
            }
        }
        val result = downloadApk(
            "https://example.invalid/v2.apk", artifacts.apk,
            open = { FakeConn(200, { body }, 4000) },
            isStopped = { stopped },
        )
        assertTrue("被停之后不再写盘: $result", result is ApkDownloadResult.Stopped)
        assertEquals(0L, artifacts.apk.length())
        assertEquals(
            "停手不是失败：不重试、不清理、不写完成标记",
            DownloadSettlement.Stopped,
            settleDownload(result, artifacts.apk, artifacts.marker, 0) { ApkVerifier.Result.Ok },
        )
        assertTrue(artifacts.apk.exists())
        assertFalse(artifacts.marker.exists())
    }

    @Test
    fun alreadyStoppedWorkerDoesNotEvenConnect() {
        var opened = 0
        val result = downloadApk(
            "https://example.invalid/v2.apk", File(dir, "x.apk"),
            open = { opened++; FakeConn(200) },
            isStopped = { true },
        )
        assertTrue(result is ApkDownloadResult.Stopped)
        assertEquals(0, opened)
    }

    // ── 3. 待办绑定请求 id ──

    private fun pending(version: String, url: String, sha: String, workId: UUID?) =
        PendingUpdate(version = version, url = url, sha256 = sha, workId = workId?.toString())

    /**
     * 现场：入队 v2 用 REPLACE，v1 的请求变成 CANCELLED。若界面还按「同名请求列表的第一个」
     * 读信号，v1 的 CANCELLED 会被当成「这条线作废」清掉 v2 的待办。
     * 反证：把 [lineSignalOf] 改回不看 id（直接 signalOf(info)），本测试红。
     */
    @Test
    fun aReplacedRequestsCancellationIsNotThisLinesSignal() {
        val v1Id = UUID.randomUUID()
        val v2Id = UUID.randomUUID()
        val line = pending("0.9.12", "https://example.invalid/v2.apk", "bb".repeat(32), v2Id)

        val foreignCancelled = WorkInfo(v1Id, WorkInfo.State.CANCELLED, emptySet())
        assertNull("被顶替的旧请求的 CANCELLED 与这条线无关", lineSignalOf(foreignCancelled, line))

        val ownRunning = WorkInfo(v2Id, WorkInfo.State.RUNNING, emptySet())
        assertEquals(WorkSignal.Running, lineSignalOf(ownRunning, line))
        val ownCancelled = WorkInfo(v2Id, WorkInfo.State.CANCELLED, emptySet())
        assertEquals("自己的请求被取消才算这条线作废", WorkSignal.Cancelled, lineSignalOf(ownCancelled, line))
        assertEquals(WorkSignal.None, lineSignalOf(null, line))
    }

    @Test
    fun sameUpdateAlreadyInFlightIsANoOp() {
        val info = UpdateInfo(version = "0.9.12", notes = "", url = "https://example.invalid/v2.apk", sha256 = "bb".repeat(32), signature = "")
        val line = pending(info.version, info.url, info.sha256, UUID.randomUUID())
        assertTrue(downloadAlreadyInFlight(line, info, WorkSignal.Running))
        assertTrue(downloadAlreadyInFlight(line, info, WorkSignal.Enqueued))
        // 失败 / 成功 / 没记录：允许重新发起
        assertFalse(downloadAlreadyInFlight(line, info, WorkSignal.Failed))
        assertFalse(downloadAlreadyInFlight(line, info, WorkSignal.None))
        // 不同的更新（版本 / 包变了）：顶替
        assertFalse(downloadAlreadyInFlight(line, info.copy(version = "0.9.13"), WorkSignal.Running))
        assertFalse(downloadAlreadyInFlight(line, info.copy(sha256 = "cc".repeat(32)), WorkSignal.Running))
        assertFalse(downloadAlreadyInFlight(null, info, WorkSignal.Running))
    }

    /** #719 之前写下的待办没有请求 id：读不出 id ⇒ 没有能驱动它的请求 ⇒ 按孤儿清理（UPD-21）。 */
    @Test
    fun legacyPendingWithoutWorkIdIsAnOrphan() {
        val legacy = pending("0.9.11", "https://example.invalid/v1.apk", "aa".repeat(32), null)
        assertNull(legacy.workUuid())
        assertNull(legacy.copy(workId = "not-a-uuid").workUuid())
        val signal = legacy.workUuid()?.let { WorkSignal.Running } ?: WorkSignal.None
        assertEquals(PendingAutoCheckAction.ClearStaleThenCheck, pendingAutoCheckAction(legacy, signal))

        val id = UUID.randomUUID()
        assertEquals(id, legacy.copy(workId = id.toString()).workUuid())
    }

    @Test
    fun discardRemovesEveryUpdateLine() {
        updateArtifactsOf(dir, v1).apply { dir.mkdirs(); apk.writeText("x") }
        updateArtifactsOf(dir, v2).apply { dir.mkdirs(); marker.writeText("ok") }
        discardUpdateArtifacts(dir)
        assertFalse(updateRootDir(dir).exists())
    }
}
