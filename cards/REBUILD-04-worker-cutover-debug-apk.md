# REBUILD-04 Worker 切换、最小状态呈现与首包验收（L2）

> 🟡 状态：待真机验收 · 协同分支：`main` · 前置：REBUILD-03
> 级别：L2 · 阻塞：三星测试相册首验
> 当前节点：三星首包已通过 Flow 原生 fetch/receipt 入库 · 下一步：Pause → 杀 App → Continue → Cancel

## 问题

用户需要验暂停重构，但旧 Worker/UI 仍按 WorkManager batch 状态推导，无法展示或控制新账本的真实状态。

## 期望行为

生产 `BackupWorker` 仅作为新 Flow 的 framework wake adapter；UI 从新账本投影 Pause / Waiting / Transferring / Cancelled。构建可安装 debug APK，在三星测试相册上完成第一轮 Pause / Continue / Cancel 验收。

## 验收标准

- [x] Worker 不再执行旧 scan/hash/manifest/push/commit 主路径。
- [x] UI 可区分用户 Pause 与条件等待；Continue 只恢复队头；Cancel Current Round 不影响 confirmed。
- [x] `assembleDebug` 成功；只用测试相册安装验证。
- [ ] 三星真机：传输中 Pause → 杀 App 重开仍 Pause → Continue 队头续传 → Cancel 不传剩余项。

## 范围

- 只准动：Worker 新入口、最小 UI 状态/命令、debug 构建与三星验收脚本。
- 不准动：低频对账提示、旧 backlog 清理、无关 UI 优化。

## 阻塞与依赖

REBUILD-03；代码已完成。这是首次需要三星设备的卡。

## 验收记录

- `BackupWorker` 已降为 Flow wake adapter；旧 batch 生产路径与对应机制测试按
  REBUILD-00 分类冻结，不为它们保留机制。
- UI action/status 已投影 Flow ledger：`PAUSED_BY_USER`、constraints waiting、
  transferring 与 cancelled round 可区分；Continue/Cancel 都走同一 strict consumer。
- 验证：Android JVM 250 tests / 0 failures / 4 skipped、REBUILD-04 focused 3/3、
  `assembleDebug` 成功，APK 包含两个 native libs；`just ci` 与 `cargo deny` advisories 通过。
- **待三星测试相册**：传输中 Pause → 杀 App 重开仍 Pause → Continue 原队头续传 →
  Cancel Current Round 不传剩余项。
- **2026-09-01 首包实测**：三星测试相册发现 26 项；Desktop durable index 为 25 项（1
  项内容去重），手机 ledger 26 项均 `CONFIRMED`。实测暴露并已修复三条生产断点：
  native provider 是独立 endpoint，Desktop 改为以已鉴权 control peer 持有 grant、以
  immutable ticket 的 provider endpoint fetch；completion receipt 回流 FlowRunner 自动推进
  下一 strict head；legacy watch reconciliation 失败只记诊断，不能杀掉 Flow 进程。
  `FAILED_NEEDS_USER` 现在在 UI 显示可重试状态，显式 Retry 会重开失败队头并重置该次预算。
- 本轮验证：`just ci`、`cargo deny check advisories`、daemon flow delivery 4/4、Android
  JVM **254 tests / 0 failures / 4 skipped**、debug APK；Desktop 和三星均已安装 **0.5.0**。
