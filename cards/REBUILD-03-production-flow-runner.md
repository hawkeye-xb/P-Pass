# REBUILD-03 新 Backup Flow Runner 与触发接管（L2）

> ✅ 状态：已完成 · 协同分支：`rebuild/rebuild-03-flow-runner` · 前置：REBUILD-01、REBUILD-02
> 级别：L2 · 阻塞：无
> 当前节点：新 Flow runner 与 production discovery triggers 已验证 · 下一步：REBUILD-04 Worker wake adapter / UI / 三星验收

## 问题

ARCH-01 的账本、发现器、严格消费者、取消和对账组件未被真实入口调用；旧 Worker 仍自行扫描、hash、批次 push/commit。

## 期望行为

在 `backup/flow` 建立新的生产 runner：触发只请求发现，发现原子入账，消费者严格处理队头，调用 native delivery adapter，完成凭据写账本。Pause/Continue/Cancel/条件等待全部由新账本状态驱动。

## 验收标准

- [x] 新 runner 不调用 BackupRunner、ConfirmedStore、ReuploadQueue 或旧批次 manifest/push。
- [x] 触发、发现、消费、完成凭据、Pause/Continue/Cancel 走同一新 Flow。
- [x] 旧 Worker 尚未删除，但不得再承载新功能。
- [x] debug APK 可构建。

## 范围

- 只准动：`backup/flow`、新 Flow ports/adapters、触发接入。
- 不准动：旧 UI 文案、低频对账 UI、无关 P2/P3。

## 阻塞与依赖

REBUILD-01、REBUILD-02。均已完成。

## 验收记录

- `FlowRunner` 将 trigger discovery request、原子页面入账、严格队头、native ticket
  delivery 与 completion receipt 串为同一账本路径；Pause / Continue / constraints /
  Cancel 均经该 consumer，不走 legacy batch API。
- Android process wake 与 MediaWatch 只额外请求 Flow discovery；旧 Worker 保留到
  REBUILD-04 作为 framework wake adapter 时再切换，不在本卡重做 UI 或真机验收。
- 验证：REBUILD03 Flow tests 3、flow/bridge/boundary focused tests 7；Android JVM
  392 tests / 0 failures / 4 skipped，`assembleDebug` 成功；`just ci` + `cargo deny`
  advisories 通过。
