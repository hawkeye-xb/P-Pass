# MOB-55 「取消当前轮」点击无可见反馈（待真机复现取证）（L2）

> ⬜ 状态：未开工 · 当前节点：等真机复现（logcat 环缓冲区已轮转，本次未
> 抓到当时日志）· 下一步：验收人下次真机测试时复现，立即 `adb logcat`
> + 账本快照取证 · 协同分支：`main`
> 级别：L2 · 阻塞：无

## 问题

2026-09-07 三星 SM-S9210 真机回归（全新配对）：验收人反馈「点击'取消当前
轮'——没有任何反应」，且之后点击「继续」不再触发备份（需要选择新相册才能
恢复动作）。

**取证现状**：logcat 环缓冲区在本 agent 排查时已轮转，未能抓到点击当下的
日志；账本文件里能看到 `cancellationRound: None`（已清空）+ 大量
`CANCELLED_BY_USER_ROUND` 项（26 条），说明取消动作**最终是生效的**——
但验收人观察到的是「点击瞬间没反应」，两者不矛盾（可能是 UI 反馈缺失，
不是功能没执行）。

候选根因（源码阅读，未验证，禁止直接采信）：

1. `BackupUiStateHolder.cancelCurrentRound()`（`BackupUiStateHolder.kt:95`）
   前置条件是 `flowUiStateOf(...) == FlowUiState.PausedByUser`——如果验收
   人点击「取消」的那一刻状态还不是纯 `PausedByUser`（例如暂停命令的
   IO 还没落盘、或点击发生在按钮短暂重渲染的窗口内），条件不满足会**静默
   跳过**，不做任何事、不报错、不提示——这与「没有任何反应」的描述一致。
2. `cancelCurrentFlowRound()` → `FlowRunner.cancelCurrentRound()` 内部
   `pause()` + `startPausedRound()` + `finishRound()` 三步在同一次调用内
   完成，UI 只在最后 `refreshFlowState()` 时读一次最终状态——如果三步之间
   有异常（比如 `startPausedRound` 的 `require()` 断言失败），
   `withContext(Dispatchers.IO) { ... }` 块会抛异常，`refreshFlowState()`
   永远不会执行到，状态条也不会跳「已取消」，而 `scope.launch` 若无
   全局异常处理会静默吞掉这个异常（需要核实 `CoroutineScope` 的
   `SupervisorJob` 异常传播行为）。

## 期望行为

- 点击「取消当前轮」必须有确定性反馈：要么立即进入取消中/已取消状态，
  要么在前置条件不满足时给出可见提示（不能是静默 no-op）。
- 若第 2 条候选根因属实（内部断言异常被吞），需要让异常至少可诊断
  （日志 + 不崩溃的降级展示），不能让 UI 停在不确定态。

## 验收标准

- [ ] 真机复现取证（本卡开工前置）：下次测试时在点击「取消当前轮」前
      开一个 `adb logcat` 尾随窗口，点击后立即导出，附回本卡；同时导出
      点击前后的账本快照（`adb shell run-as com.hawkeyexb.ppass cat
      files/flow-state/<daemonNodeId>/discovery-ledger.json`）对比
      `cancellationRound`/`consumerGate`/`fetchLease` 字段变化。
- [ ] 根因定性写回卡：是候选 1（前置条件不满足静默跳过）、候选 2（内部
      异常被吞）、还是纯 UI 反馈缺失（功能正确但没有中间态渲染）。
- [ ] RED→GREEN：按定性根因写复现用例，禁止无根因的「加个提示就好」式
      修复。
- [ ] Android JVM 全量绿（报计数）+ `just ci`。
- [ ] 真机：点击「取消当前轮」有确定性反馈，且之后「继续」按钮能立即
      正常触发新一轮备份（不需要切换相册才能恢复）。

## 范围

- 待证据定性后再列。默认候选：`BackupUiStateHolder.kt`（cancelCurrentRound
  前置条件与异常处理）、`CancellationRoundController.kt`（内部 require
  断言）、`ui/HomeScreen.kt`（取消中间态渲染）。
- 不准动：`CancellationRoundController` 的取消轮次核心语义（已由 ARCH-05
  锁定）。

## 阻塞与依赖

无前置，无下游。与 MOB-49（取消轮永久卡死，已合并代码待真机验收）系同
一功能面，但本卡是独立观察到的新现象（点击反馈问题，不是状态清除问题），
不合并处理。

---

## 实施记录

（待真机复现取证）
