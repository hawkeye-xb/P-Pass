# REBUILD-02 Desktop Native Fetch 与单项完成凭据（L2）

> ⬜ 状态：未开工 · 前置：REBUILD-00
> 级别：L2 · 阻塞：无

## 问题

Desktop daemon 当前接收的是旧 manifest/push/commit 批次；没有新 Flow 所需的“对单项 hash 发起 native fetch → 校验/materialize → 返回 durable completion receipt”入口。

## 期望行为

Desktop 对当前配对手机的单项 lease 发起原生 iroh-blobs fetch/resume；仅在完整接收、校验并可靠保存后回写携带 item/epoch/hash 的完成凭据。

## 验收标准

- [ ] 当前 pairing epoch、lease、hash 三者均匹配才允许 fetch/finalise。
- [ ] native fetch/resume 是唯一传输，不复用 manifest/push/commit。
- [ ] 完成凭据只在 durable materialize 后发出；失败/取消不确认。
- [ ] daemon/transport 构建通过；端到端手机验收留 REBUILD-04。

## 范围

- 只准动：transport/daemon 的新 fetch + receipt adapter、必要 proto/IPC。
- 不准动：旧 batch backup API 语义、Android Worker、UI、旧数据清理。

## 阻塞与依赖

REBUILD-00。可与 REBUILD-01 并行。
