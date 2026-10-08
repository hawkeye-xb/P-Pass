// UPD-02: 更新状态机的三块纯逻辑锁——
//  - reduceWorkSignal：worker 信号 → UI 状态真值表（None/Cancelled 不出状态，
//    防「pending 已写、work 未可见」的竞态把进行中打回 Idle）；
//  - retryVerdictOf：失败该不该让 WorkManager 退避重试（有次数上限）；
//  - failureKindOf：下载结果 → 失败类（UI 文案按类分句）；
//  - pendingAutoCheckAction：待办在但 work 记录被剪 ⇒ 不许永久跳过自动检查（UPD-21）。
package com.hawkeyexb.ppass.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class UpdateWorkReduceTest {

    private val pending = PendingUpdate(version = "0.9.0", url = "https://x/a.apk")

    // ── reduceWorkSignal 真值表 ──

    @Test
    fun runningStatesAreDownloadingOrVerifying() {
        for (signal in listOf(WorkSignal.Enqueued, WorkSignal.Running)) {
            assertEquals(
                UpdateUiState.Downloading(30, 100, "0.9.0"),
                reduceWorkSignal(signal, 30, 100, false, null, pending),
            )
            assertEquals(
                UpdateUiState.Verifying("0.9.0"),
                reduceWorkSignal(signal, 100, 100, true, null, pending),
            )
        }
    }

    @Test
    fun succeededIsReadyToInstall() {
        assertEquals(
            UpdateUiState.ReadyToInstall("0.9.0"),
            reduceWorkSignal(WorkSignal.Succeeded, 100, 100, false, null, pending),
        )
    }

    @Test
    fun failedCarriesKindOrUnexpected() {
        assertEquals(
            UpdateUiState.Failed(UpdateFailureKind.Stalled, "0.9.0"),
            reduceWorkSignal(WorkSignal.Failed, 0, -1, false, UpdateFailureKind.Stalled, pending),
        )
        assertEquals(
            UpdateUiState.Failed(UpdateFailureKind.Unexpected, "0.9.0"),
            reduceWorkSignal(WorkSignal.Failed, 0, -1, false, null, pending),
        )
    }

    @Test
    fun noneAndCancelledReduceToNothing() {
        assertNull(reduceWorkSignal(WorkSignal.None, 0, -1, false, null, pending))
        assertNull(reduceWorkSignal(WorkSignal.Cancelled, 0, -1, false, null, pending))
    }

    // ── retryVerdictOf：重试判定与次数上限 ──

    @Test
    fun transientFailuresRetryWithinAttemptCap() {
        val stalled = ApkDownloadResult.Stalled(ApkDownloadResult.Phase.Body, 10, 30_000)
        val conn = ApkDownloadResult.ConnectionFailed(ApkDownloadResult.Phase.Connect, 0, "x")
        assertEquals(DownloadVerdict.Retry, retryVerdictOf(stalled, 0))
        assertEquals(DownloadVerdict.Retry, retryVerdictOf(stalled, 1))
        assertEquals(DownloadVerdict.GiveUp, retryVerdictOf(stalled, UpdateDownloadWorker.MAX_RUN_ATTEMPTS - 1))
        assertEquals(DownloadVerdict.Retry, retryVerdictOf(conn, 0))
        assertEquals(DownloadVerdict.GiveUp, retryVerdictOf(conn, UpdateDownloadWorker.MAX_RUN_ATTEMPTS - 1))
    }

    @Test
    fun httpStatusRetriesOnly5xxAnd429() {
        assertEquals(DownloadVerdict.Retry, retryVerdictOf(ApkDownloadResult.HttpStatus(503), 0))
        assertEquals(DownloadVerdict.Retry, retryVerdictOf(ApkDownloadResult.HttpStatus(429), 0))
        assertEquals(DownloadVerdict.GiveUp, retryVerdictOf(ApkDownloadResult.HttpStatus(404), 0))
        assertEquals(DownloadVerdict.GiveUp, retryVerdictOf(ApkDownloadResult.HttpStatus(403), 0))
        // 超过次数上限，5xx 也要如实给用户交代。
        assertEquals(
            DownloadVerdict.GiveUp,
            retryVerdictOf(ApkDownloadResult.HttpStatus(500), UpdateDownloadWorker.MAX_RUN_ATTEMPTS - 1),
        )
    }

    @Test
    fun permanentFailuresNeverRetry() {
        assertEquals(
            DownloadVerdict.GiveUp,
            retryVerdictOf(ApkDownloadResult.LocalWriteFailed(0, "disk full"), 0),
        )
        assertEquals(
            DownloadVerdict.GiveUp,
            retryVerdictOf(ApkDownloadResult.Unexpected(ApkDownloadResult.Phase.Connect, "boom"), 0),
        )
    }

    // ── failureKindOf：结果 → 失败类 ──

    @Test
    fun failureKindsMapOneToOne() {
        assertEquals(
            UpdateFailureKind.Stalled,
            failureKindOf(ApkDownloadResult.Stalled(ApkDownloadResult.Phase.Body, 1, 30_000)),
        )
        assertEquals(UpdateFailureKind.Server, failureKindOf(ApkDownloadResult.HttpStatus(500)))
        assertEquals(
            UpdateFailureKind.Network,
            failureKindOf(ApkDownloadResult.ConnectionFailed(ApkDownloadResult.Phase.Connect, 0, "x")),
        )
        assertEquals(UpdateFailureKind.Write, failureKindOf(ApkDownloadResult.LocalWriteFailed(0, "x")))
        assertEquals(
            UpdateFailureKind.Unexpected,
            failureKindOf(ApkDownloadResult.Unexpected(ApkDownloadResult.Phase.Body, "x")),
        )
        // Ok 不可达（worker 只在失败路径调用），防御性归 Unexpected。
        assertEquals(UpdateFailureKind.Unexpected, failureKindOf(ApkDownloadResult.Ok(1)))
    }

    // ── UPD-21: pendingAutoCheckAction 真值表 ──

    @Test
    fun noPendingChecksAsUsual() {
        for (signal in WorkSignal.values()) {
            assertEquals(PendingAutoCheckAction.Check, pendingAutoCheckAction(null, signal))
        }
    }

    @Test
    fun pendingWithPrunedWorkRecordIsClearedNotSkippedForever() {
        // WorkManager 剪掉终态记录后 getWorkInfosForUniqueWork 返回空 ⇒ None。
        assertEquals(
            PendingAutoCheckAction.ClearStaleThenCheck,
            pendingAutoCheckAction(pending, WorkSignal.None),
        )
        assertEquals(
            PendingAutoCheckAction.ClearStaleThenCheck,
            pendingAutoCheckAction(pending, WorkSignal.Cancelled),
        )
    }

    @Test
    fun pendingWithLiveWorkRecordSkips() {
        for (signal in listOf(
            WorkSignal.Enqueued, WorkSignal.Running, WorkSignal.Succeeded, WorkSignal.Failed,
        )) {
            assertEquals(PendingAutoCheckAction.Skip, pendingAutoCheckAction(pending, signal))
        }
    }
}
