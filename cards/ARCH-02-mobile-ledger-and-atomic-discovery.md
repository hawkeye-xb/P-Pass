# ARCH-02 手机账本与发现页原子提交（L2）

> ✅ 状态：代码完成（已释放 ARCH-03）
> 级别：L2 · 前置：ARCH-01 设计与 Case Matrix 已收口；无产品待拍板

## 问题

现有备份把扫描、水位、候选与上传批次绑在旧 WorkManager 管线中。崩溃或重复
触发时，无法证明“媒体候选已持久化”和“发现游标已前移”是同一件事：先推进游标
会漏照片，先插候选又可能重复。

## 期望行为

建立 ARCH-01 的手机本地账本最小内核：`TransferItem`、`DiscoveryCursor`、
`ScopeRevision`、`CancellationRound` 等持久事实，以及“候选页写入 + 游标前移”
的单一原子提交。发现器每次最多提交 500 项；发现阶段不读完整文件、不算 hash、
不访问 Desktop。

本卡覆盖 Case Matrix：**D-01、D-02、D-03、D-04**。

## 验收标准

- [ ] 先写 `ARCH01DiscoveryLedgerTest`（或等价的纯账本合同测试），逐项覆盖
      D-01~D-04；执行
      `cd apps/android && ./gradlew :app:testDebugUnitTest --tests '*ARCH01DiscoveryLedgerTest'`
      → `BUILD SUCCESSFUL`，且 D-01~D-04 均有可读的测试名。
- [ ] D-01：提交 500 项时，待传项与 DiscoveryCursor 同时可见；不允许只写其一。
- [ ] D-02：在提交前注入崩溃 → 队列与游标都不变；重启重试仍可发现同一页。
- [ ] D-03：提交后立即崩溃再触发 → 同一媒体版本不产生重复 TransferItem。
- [ ] D-04：CancellationRound 活动中发现的候选直接终态为
      `CANCELLED_BY_USER_ROUND`，游标仍可前移，且不得进入可传队列。
- [ ] 反证：将“写候选”和“推游标”拆成两次提交，或移除稳定身份去重 → 对应
      D-02 / D-03 测试必须变红。
- [ ] 全量 Android 单测通过，并报告本次生成 XML 的测试总数与 0 failures。

## 范围

- 只准动：`apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/` 下新增的
  ARCH-01 账本/发现 domain 与 storage 模块；对应 JVM 单测。
- 不准动：旧 `BackupWorker.kt` 管线、WorkManager 调度、UI、Rust/desktop、传输协议。
- 账本的逻辑字段与原子边界由 ARCH-01 固定；具体存储实现必须以 D-01~D-03 的
  原子性与崩溃恢复要求选择，不得反过来改产品语义。

## 阻塞与依赖

2026-08-31 self-review 已确认本卡覆盖 D-01~D-04、未引入新产品语义；无阻塞。

---

## 实施记录

- 2026-08-31：先建立 `ARCH01DiscoveryLedgerTest`，D-01~D-04 因账本符号尚不存在而按预期编译失败；随后实现最小持久账本与发现页单文件原子替换。
- 账本持久化 `TransferItem`、`DiscoveryCursor`、`ScopeRevision`、`CancellationRound`，并为后续消费者保留 `UploadCursor`、consumer gate 与 fetch lease 边界；单页最多 500 项，稳定 `(sourceRef, sourceVersion)` 身份去重。
- 验证：定向 D-01~D-04 4/4 通过；全量 Android JVM 单测 XML 为 351 tests / 0 failures / 0 errors。
- 反证已实际执行后恢复：临时把游标先于页面替换落盘，D-02 在崩溃后游标断言失败；临时移除稳定身份去重，D-03 的 500 条目断言失败。
- 2026-08-31：验收人已确认 GitHub `CI Android #94`（commit `755108d`）为绿色成功。

## 备注

来源：ARCH-01 §2~§4 与 Case Matrix P0 发现水位与本地入队。后续 ARCH-03 只能消费
本卡持久化的账本事实，不能从 WorkManager 状态推断业务状态。
