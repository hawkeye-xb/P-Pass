# ARCH-09 P1 对账分页协调与源存在性裁决接线（L2）

> 🟠 状态：进行中（认领与拆卡已发布；尚未写生产代码）
> 级别：L2 · 前置：ARCH-07、ARCH-08 · 协同分支：`main` · 基线：`e7269a4`
> 当前节点：把已确认账本项接到 presence page 和 ARCH-07 裁决；下一步：先写 R-01/R-02 的协调器失败合同。

## 问题

ARCH-07 能保存远端/源存在性与恢复裁决，ARCH-08 能查询一个只读 Desktop hash 页，但两者尚未接通。若直接走旧 `BackupWorker` / `BackupRunner`，会重新进入旧批次校准与上传管线，违反 ARCH-01 的“观察缺失不等于自动补传”边界。

## 期望行为

新增 Android 本地协调器：从当前 `pairingEpoch` 的 `CONFIRMED` 且带 `contentHash` 的 `TransferItem` 按 `queueSequence` 选取最多 500 项；调用 `RemotePresenceProbe`。Desktop 存在的项只写 `remotePresence=PRESENT`，不得读取手机源。仅对 Desktop 缺失项，以 `sourceRef` 做一次不读内容的可打开探针：可打开 → `NEEDS_DECISION`，不可打开/缺失 → `UNRECOVERABLE`，并由 ARCH-07 的账本迁移持久化。整个协调器不入队、不 fetch、不 hash、不改 UploadCursor/lease/attemptCount。

本卡不负责 5 小时调度、重启恢复、用户提示、恢复上传、MediaStore 扫描或 WorkManager 接线。

## 验收标准

- [ ] 新增 JVM 合同测试，覆盖 R-01/R-02 的完整协调路径与远端存在路径。
- [ ] 只选当前 epoch、`CONFIRMED` 且有 `contentHash` 的项；按 queueSequence 升序，单页最多 500 项。
- [ ] Desktop 返回 present 的项不触碰 source probe，写 `PRESENT` / 无恢复裁决。
- [ ] Desktop 返回 missing 的项才探测 `sourceRef`；probe 仅尝试打开后立即关闭，不读/不 hash 内容。
- [ ] source 可用 → `NEEDS_DECISION`；不可用 → `UNRECOVERABLE`；所有路径均保持 `CONFIRMED`、UploadCursor、lease、attemptCount 与 queueSequence。
- [ ] 反证：让 present 项也读源，或让 missing 项改为 `QUEUED`/触发 fetch，测试必须变红。
- [ ] Android 全量 JVM 与 `just ci` 通过，报告本次 XML 测试统计。

## 范围

- 只准动：ARCH-01 新账本的确认项页选择、独立 source-presence port/Android resolver adapter、ARCH-08 probe 调用、ARCH-07 状态迁移接线与对应 JVM 合同测试。
- 不准动：旧 `BackupWorker` / `BackupRunner` / `ConfirmedStore` / `ReuploadQueue`、WorkManager、UI、协议/Rust、native fetch 或任何自动补传。

## 阻塞与依赖

ARCH-07 的账本裁决与 ARCH-08 的 presence query 已完成。无外部阻塞。

后续卡才为本协调器接低频调度与用户可见的 `NEEDS_DECISION` / `UNRECOVERABLE` 提示。

---

## 实施记录

- 2026-09-01：从 ARCH-01 §9 与 R-01/R-02 拆出。既有 `BackupWorker` 的 `openInputStream(...).use {}` 是旧批次候选的可读探针，不能接入本卡；协调器改以独立 source-presence port 表达同样的“一次打开立即关闭、不读内容”事实，避免复用旧上传管线。

## 备注

协调器只消费已经保存的 `contentHash` 与 `sourceRef`，不重新扫描或计算 hash。`RemotePresenceProbe` 自身固定 ≤500 页，上游选择必须同样限制，防止以“分页”名义静默截断账本事实。
