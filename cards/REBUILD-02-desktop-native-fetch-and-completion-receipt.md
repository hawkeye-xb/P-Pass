# REBUILD-02 Desktop Native Fetch 与单项完成凭据（L2）

> ✅ 状态：已完成 · 协同分支：`rebuild/rebuild-02-native-fetch` · 前置：REBUILD-00
> 级别：L2 · 阻塞：无
> 当前节点：Desktop native fetch/receipt adapter 已验证 · 下一步：REBUILD-03 接入新生产 Flow runner

## 问题

Desktop daemon 当前接收的是旧 manifest/push/commit 批次；没有新 Flow 所需的“对单项 hash 发起 native fetch → 校验/materialize → 返回 durable completion receipt”入口。

## 期望行为

Desktop 对当前配对手机的单项 lease 发起原生 iroh-blobs fetch/resume；仅在完整接收、校验并可靠保存后回写携带 item/epoch/hash 的完成凭据。

## 验收标准

- [x] 当前 pairing epoch、lease、hash 三者均匹配才允许 fetch/finalise。
- [x] native fetch/resume 是唯一传输，不复用 manifest/push/commit。
- [x] 完成凭据只在 durable materialize 后发出；失败/取消不确认。
- [x] daemon/transport 构建通过；端到端手机验收留 REBUILD-04。

## 范围

- 只准动：transport/daemon 的新 fetch + receipt adapter、必要 proto/IPC。
- 不准动：旧 batch backup API 语义、Android Worker、UI、旧数据清理。

## 阻塞与依赖

REBUILD-00。已与 REBUILD-01 并行完成。

## 验收记录

- 新 `flow.offer` / `flow.fetch` / `flow.cancel` 只使用 native `Blobs::fetch_from`；当前
  epoch、lease、hash 在 fetch 前与 materialize/finalise 前均重验。
- `flow_delivery` 持久化 grant、取消事实与 immutable completion receipt；仅 `Ingestor`
  durable materialize 成功后写回 receipt，`.ppf/flow-blobs` 保留可续传 partial。
- 验证：flow delivery 3、pairing flow 10、transport 22、proto 43、storage 22、desktop lib 16
  均通过；`just ci` all green。前端未改，worktree 无 `node_modules`，故未跑 vitest。
