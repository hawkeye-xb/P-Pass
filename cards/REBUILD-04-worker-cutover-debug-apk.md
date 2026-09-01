# REBUILD-04 Worker 切换、最小状态呈现与首包验收（L2）

> ⬜ 状态：未开工 · 前置：REBUILD-03
> 级别：L2 · 阻塞：等待新 Flow runner

## 问题

用户需要验暂停重构，但旧 Worker/UI 仍按 WorkManager batch 状态推导，无法展示或控制新账本的真实状态。

## 期望行为

生产 `BackupWorker` 仅作为新 Flow 的 framework wake adapter；UI 从新账本投影 Pause / Waiting / Transferring / Cancelled。构建可安装 debug APK，在三星测试相册上完成第一轮 Pause / Continue / Cancel 验收。

## 验收标准

- [ ] Worker 不再执行旧 scan/hash/manifest/push/commit 主路径。
- [ ] UI 可区分用户 Pause 与条件等待；Continue 只恢复队头；Cancel Current Round 不影响 confirmed。
- [ ] `assembleDebug` 成功；只用测试相册安装验证。
- [ ] 三星真机：传输中 Pause → 杀 App 重开仍 Pause → Continue 队头续传 → Cancel 不传剩余项。

## 范围

- 只准动：Worker 新入口、最小 UI 状态/命令、debug 构建与三星验收脚本。
- 不准动：低频对账提示、旧 backlog 清理、无关 UI 优化。

## 阻塞与依赖

REBUILD-03；这是首次需要三星设备的卡。
