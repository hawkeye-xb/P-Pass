# ARCH-07 远端对账事实与恢复裁决（L2）

> ✅ 状态：代码完成；低频探测、实际 daemon/proto 接线与 UI 提示另卡实施
> 级别：L2 · 前置：ARCH-02、ARCH-04、ARCH-06 · 协同分支：`main` · 基线：`faf31c7`
> 当前节点：P1 本地账本事实 / 恢复裁决已完成；下一步：按 Desktop 低频存在性探测边界拆后续卡。

## 问题

ARCH-04 的 `TransferItem` 只保存完成凭据 id，未保存 Desktop 已确认的内容身份；账本也没有 `remotePresence`、`sourcePresence` 或恢复裁决。因而即使 Desktop 后续报告已确认内容外部缺失，手机无法把“可从手机恢复”和“手机也已丢失”持久化为不同事实；更不能证明缺失观察不会悄悄重新入队并自动补传。

## 期望行为

为当前 `pairingEpoch` 的已确认项保存完成时的内容身份，并在对账结果进入账本时持久化三类事实：远端存在性、本地源存在性和恢复裁决。远端缺失且源仍可读时为 `NEEDS_DECISION`；两端都缺失时为 `UNRECOVERABLE`。两种情况都只更新事实，绝不自动入队、fetch、重试、删除手机原图或改变已确认完成事实。

本卡覆盖 Case Matrix：**R-01、R-02** 的本地状态合同；低频分页探测、实际 daemon/proto 接线与 UI 提示留给后续卡，不在本卡伪造传输行为。

## 验收标准

- [x] 新增 `ARCH01RemoteReconciliationTest`，先以失败合同覆盖 R-01/R-02；运行
      `cd apps/android && ./gradlew :app:testDebugUnitTest --tests '*ARCH01RemoteReconciliationTest'`
      → `BUILD SUCCESSFUL`。
- [x] 完成凭据与 `TransferItem` 持久关联内容身份；仅当前账本且当前 `pairingEpoch` 的 `CONFIRMED` 项可成为对账对象。
- [x] R-01：远端报告缺失且源探针报告存在 → 持久化
      `remotePresence=MISSING`、`sourcePresence=PRESENT`、`disposition=NEEDS_DECISION`；
      `deliveryState=CONFIRMED`、UploadCursor、fetch lease、失败次数和队列序号均不变，且不触发上传。
- [x] R-02：远端报告缺失且源探针报告缺失 → 持久化
      `remotePresence=MISSING`、`sourcePresence=MISSING`、`disposition=UNRECOVERABLE`；不得向用户/调用方宣称可恢复。
- [x] 远端仍存在时不得读取完整手机源或重新 hash；只记录存在性，不制造恢复提示。
- [x] 反证：把远端缺失改为 `QUEUED`/启动 fetch 时 R-01 必须变红；把 R-02 裁成 `NEEDS_DECISION` 时 R-02 必须变红。两条反证实际执行后还原。
- [x] 全量 Android JVM 单测通过，并报告本次生成 XML 的测试总数与 0 failures。

## 范围

- 只准动：ARCH-01 新账本的 `TransferItem` / 完成凭据内容身份、远端/源存在性与恢复裁决的纯状态迁移；对应 Android JVM 合同测试。
- 不准动：旧 `ConfirmedStore`、`ReuploadQueue`、`BackupRunner`、`BackupWorker`、WorkManager、UI、`DaemonClient`、proto、Rust/desktop、实际 native fetch adapter。
- 不准借旧批次校准的“缺失即重传”行为实现本卡；ARCH-01 P1 是独立账本，不与旧管线兼容拼接。

## 阻塞与依赖

ARCH-02 提供原子账本，ARCH-04 提供完成凭据，ARCH-06 提供 epoch 隔离。无外部阻塞。

后续卡须把低频分页的 Desktop 存在性查询及 Android 源探针接入本卡的状态迁移，并在独立 UI 卡呈现 `NEEDS_DECISION` / `UNRECOVERABLE`；这些接口与调度策略不在本卡定义。

---

## 实施记录

- 2026-09-01：从 ARCH-01 P1 边界拆出并认领。代码勘查确认 `DiscoveryLedger.kt` 的 `TransferItem` 只有 `completionReceiptId`，`CompletionReceipt` 只有 `receiptId`，当前没有已确认内容的可对账身份或远端存在性字段；旧 `ConfirmedStore` / `ReuploadQueue` 属冻结的批次校准管线，不能作为 P1 实现基础。
- 2026-09-01：R-01 RED 已确认：`ARCH01RemoteReconciliationTest` 因 `contentHash`、存在性字段和 `RemoteReconciliation` 均未实现而在 Kotlin 编译阶段失败；失败来源是本卡要求的新账本能力，不是环境或测试夹具错误。
- 2026-09-01：R-01 GREEN：`./gradlew :app:testDebugUnitTest --tests '*ARCH01RemoteReconciliationTest'` 通过（1/1）；完成凭据现在可持久携带内容身份，远端缺失且手机源仍在时仅写 `MISSING` / `PRESENT` / `NEEDS_DECISION`，队列与消费者状态不变。
- 2026-09-01：R-02 RED 后 GREEN：手机源缺失时先因未实现分支失败，补为 `UNRECOVERABLE` 后目标 3/3 通过。远端仍存在只写 `PRESENT`、清除恢复裁决，不接源探针或 hash。
- 2026-09-01：反证实际执行后还原：临时把远端缺失项改回 `QUEUED`，R-01/R-02 共 2 条失败；临时把源缺失裁成 `NEEDS_DECISION`，R-02 单条失败。全量 Android JVM 本次 XML 52 files / 377 tests / 0 failures / 0 errors / 4 skipped；`just ci` 全绿。

## 备注

来源：ARCH-01 §9 与 Case Matrix R-01/R-02。关键反证不是“能否再次传输”，而是外部缺失观察不得改写为自动补传意图；手机和 Desktop 都缺失时更不得制造可恢复的假话。
