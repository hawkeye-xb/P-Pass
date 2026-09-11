// MOB-67: the boundary between the Flow failure path (JVM-testable) and the
// Android system notification (real-device acceptance).
//
// ## 根因（本文件存在的前提）
//
// UX-02（2026-08-05, PR #36）本来有完整的失败通知：`ppass.backup.failed`
// 渠道、固定 id 2027、由 `NotifyOnFailurePrefs.enabled()` 闸控，全部住在
// BackupWorker 里。REBUILD-04 生产切换（a325208）把 Worker 降级为纯 wake
// adapter、删掉 1124 行时，整套通知设施随批次管线一起消失——新 Flow 的
// 永久失败路径（StrictConsumer 的 FAILED_NEEDS_USER 跃迁）从来没有接回
// 通知发送。所以 `NotifyOnFailurePrefs` 全仓只剩设置页自己读它。
//
// 本接口把断掉的线接回**唯一的终态跃迁点**（FlowRunner 在 attempt 3 把队头
// 落到 FAILED_NEEDS_USER 那一刻），而不是每张照片的普通哈希/网络错误。
// 瞬态重试（attempt 1/2）不发——那是自愈，不是「备份失败」。
//
// ## 顺序与异常（与 ReuploadNotice 的教训同构）
//
// 账本跃迁先落盘（`ledger.update` 是原子的 tmp+rename），通知是**补充渠道**
// 的 best-effort：发送异常被吞掉，Home 红卡（FAILED_NEEDS_USER 的 UI 投影）
// 不受影响。Android 13+ 未授予 POST_NOTIFICATIONS 时系统静默丢弃——可接受，
// 因为状态真相在盘上、App 内可见，这正是 MOB-37 对「通知天然一次性」缺陷
// 的裁决（通知退化成「提醒你去看」，不再是唯一载体）。
package com.hawkeyexb.ppass.backup

/** Implementation gate: only [enabled] may suppress, never the caller's ledger path. */
interface FailureNotifier {
    /** The user's "备份失败时通知我" preference (NotifyOnFailurePrefs). */
    fun enabled(): Boolean

    /**
     * Post one system notification for the terminal-failure transition.
     *
     * @param failedItems total items currently in FAILED_NEEDS_USER — the
     *   honest count the message shows, folded by the fixed notification id
     *   (a second failure replaces the first, never a second buzz).
     */
    fun postFailure(failedItems: Int)
}

/** JVM-side default: a FlowRunner built without an Android runtime stays silent. */
object NoopFailureNotifier : FailureNotifier {
    override fun enabled(): Boolean = false
    override fun postFailure(failedItems: Int) = Unit
}
