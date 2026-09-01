# REBUILD-03 新 Backup Flow Runner 与触发接管（L2）

> ⬜ 状态：未开工 · 前置：REBUILD-01、REBUILD-02
> 级别：L2 · 阻塞：等待 blobs bridge 与 Desktop receipt adapter

## 问题

ARCH-01 的账本、发现器、严格消费者、取消和对账组件未被真实入口调用；旧 Worker 仍自行扫描、hash、批次 push/commit。

## 期望行为

在 `backup/flow` 建立新的生产 runner：触发只请求发现，发现原子入账，消费者严格处理队头，调用 native delivery adapter，完成凭据写账本。Pause/Continue/Cancel/条件等待全部由新账本状态驱动。

## 验收标准

- [ ] 新 runner 不调用 BackupRunner、ConfirmedStore、ReuploadQueue 或旧批次 manifest/push。
- [ ] 触发、发现、消费、完成凭据、Pause/Continue/Cancel 走同一新 Flow。
- [ ] 旧 Worker 尚未删除，但不得再承载新功能。
- [ ] debug APK 可构建。

## 范围

- 只准动：`backup/flow`、新 Flow ports/adapters、触发接入。
- 不准动：旧 UI 文案、低频对账 UI、无关 P2/P3。

## 阻塞与依赖

REBUILD-01、REBUILD-02。
