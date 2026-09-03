# MOB-49 取消本轮后 UI 永久卡死，无生产路径清除 cancellationRound（L1）

> 🟠 状态：进行中 · 当前节点：按 ARCH-01 已定语义接线取消扫描完成后的原子结束；下一步：先写 FlowRunner 生产接线 RED 测试 · 协同分支：`main` · 前置：无
> 级别：L1 · 阻塞：无

## 问题

真机验收 REBUILD-05 时发现：`CancellationRoundController` 提供了
`finishRound()` / `restoreRound()` / `discardRound()` 三个方法用于结束、恢复
或丢弃一次取消轮次，但全仓搜索显示这三个方法**只在 JVM 测试里被调用**
（`ARCH01CancellationRoundTest.kt`），生产代码路径（`FlowRunner`、
`AndroidFlowRuntime`、`MainActivity`、`BackupUiStateHolder`）没有任何一处
调用它们。

真机复现：点击「取消当前轮」后，`discovery-ledger.json` 的
`cancellationRound` 字段被设置为一个非 null 值；此后无论怎样操作 App
（继续/暂停/重开/切相册），只有 `PairingEpochController.ensureCurrentEpoch`
在配对 epoch 变化时才会把它清空——正常使用中配对 epoch 不会变化，于是首页
状态条永久停留在「当前轮已取消」文案（`FlowUiState.CancelledCurrentRound`），
用户没有任何操作能回到正常的 Pause/Continue/Idle 状态。

## 期望行为

取消本轮完成后，App 应提供某种用户可触发的方式（例如下一次成功的
discovery+wake 循环、或显式的"知道了"确认）把 `cancellationRound` 清空，
恢复到正常的备份状态机；不能让这个状态字段一旦写入就只能靠配对重置才能清除。

## 验收标准

- [ ] 明确"取消本轮"完成后 UI 应该在什么条件下自动或手动回到正常状态（需要
  产品判断：是否需要用户确认，还是下一轮成功传输后自动清除）。
- [ ] 生产代码补上调用 `finishRound()`（或等价逻辑）的路径，真机验证取消本轮
  后备份页可以恢复正常操作（不再永久显示"当前轮已取消"）。
- [ ] 新增/修改 JVM 测试覆盖该生产接线；反证：去掉接线后测试变红。
- [ ] 三星真机验证：Pause → Cancel Current Round → 之后新增测试媒体能被正常
  discovery、传输、确认，不需要清空本地状态文件。

## 范围

- 只准动：`apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/`
  中 `CancellationRoundController` 的生产接线点、相关 UI 状态投影、对应
  Android JVM 测试。
- 不准动：`CancellationRoundController` 内部的取消轮次语义本身（已由
  ARCH-05 锁定）、REBUILD-05 的 backfill 逻辑、旧 Worker/batch 机制。

## 阻塞与依赖

无。发现于 REBUILD-05 真机验收过程，与该卡根因（迟到回执处理）无关，
是取消本轮流程自身的生产接线缺口。

---

## 实施记录

- 2026-09-03：认领。ARCH-01 §8 已明确取消扫描完成后原子结束 `CancellationRound`；本卡不新增用户确认，也不等待下一次成功传输。先以 `FlowRunner` 的生产接线测试证明取消后 UI 回到 `PausedByUser`；MOB-50 继续负责独立的 `uploadCursor` 复位。

## 备注

来源：2026-09-02 REBUILD-05 三星真机验收记录。当时手机上已有一条历史
`CANCELLED_BY_USER_ROUND` 记录（REBUILD-06 测试遗留），据此触发本次发现。
本卡验收/复现时须使用独立测试相册，不许操作验收人真实照片库数据；如需清空
`cancellationRound` 之外的测试环境状态，须先记录当前值再改，且只能改传输
状态字段，不能删除已确认（`CONFIRMED`）的账本记录。
