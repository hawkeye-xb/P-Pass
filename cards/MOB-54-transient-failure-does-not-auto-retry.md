# MOB-54 可重试传输失败后卡死在 QUEUED，不会自动重试（L1）

> 🟢 状态：代码已合并，本地验证通过 · 当前节点：**2026-09-12 OPPO 真机复核
> 失败**——传约 10 张后停摆、剩 16 张无提示不自动续传，选第三个相册才唤醒；
> 下一步：取证当次停点的 delivery 失败码与队列态，再定位 · 协同分支：`main`
> 级别：L1 · 阻塞：无

## 问题

2026-09-07 三星 SM-S9210 真机回归（全新配对，onboarding 走完）：验收人反馈
「点击取消当前轮 → 选新相册触发以前未备份的照片 → 12 张全部传完，剩最后
1 张一直卡住传不完成」。

账本文件直接取证（`files/flow-state/<daemonNodeId>/discovery-ledger.json`）：
第 38 项（`rebuild05-race-big.jpg`）停在 `deliveryState=QUEUED`、
`attemptCount=1`（已经失败重试过一次），而 `consumerGate=OPEN`、
`consumerStatus=IDLE`、`fetchLease=null`——按状态机语义这是「空闲、随时可以
接单」，但没有人去接它。

根因（源码核实）：`FlowRunner.recordPermanentFailure()` 委托
`StrictConsumer.recordPermanentFailure()` 把非终态失败（`attemptCount < 3`）
重新置回 `QUEUED`，但和同一个类里的 `acceptCompletionReceipt()`（成功路径，
接收 receipt 后显式调用 `consumer.wake(constraintsSatisfied = true)`）不同，
失败路径没有对称地调用 `wake()`。于是一次可重试的传输失败会让队列永久停摆，
除非外部信号（重开 App 触发 `requestFlowWake`、切换相册触发
`requestFlowScopeBackfill`、5 小时周期性 WorkManager 兜底）恰好路过。

## 期望行为

非终态失败（还没打满 3 次重试上限）重新排队后，`StrictConsumer` 应立即
自己去接下一次尝试，不依赖任何外部触发信号——跟成功路径完全对称。

## 验收标准

- [x] RED 先行：`REBUILD03FlowRunnerTest.transient_failure_retries_
      automatically_without_an_external_trigger`——一次传输失败
      （`attemptCount` 1→terminal 阈值 3 之前）后断言 delivery port 立刻
      收到第二次 `start`；改前必须真红。
- [x] GREEN：`FlowRunner.recordPermanentFailure()` 在委托
      `consumer.recordPermanentFailure()` 之后追加
      `consumer.wake(constraintsSatisfied = true)`，与 `acceptCompletionReceipt`
      对称。
- [x] 反证：去掉新增的 `wake()` 调用，新用例立即变红，加回后复绿。
- [x] Android JVM 全量绿（报测试计数）+ `just ci`。
- [ ] 真机：新相册补传 + 取消轮组合场景下，队列不再有「最后一张卡住不动」
      的现象（本卡代码已推，等下一轮真机回归确认）。

## 范围

- 只准动：`backup/flow/FlowRunner.kt`（`recordPermanentFailure` 补
  `wake()`）、对应 JVM 测试（`REBUILD03FlowRunnerTest.kt`）、卡片/队列文档。
- 不准动：`StrictConsumer` 内部重试计数/终态判定语义（已由 ARCH-03 锁定）、
  UI 层。

## 阻塞与依赖

无前置，无下游。

---

## 实施记录

- 2026-09-07：三星真机全新配对回归（onboarding 完整走一遍）时验收人反馈
  「取消当前轮后选新相册补传，12/13 传完，最后 1 张一直卡住」。本 agent
  用 `adb run-as` 直接读账本文件取证，命中 `queueSequence=38` 停在
  `QUEUED/attemptCount=1`，与 `acceptCompletionReceipt` 的成功路径对比后
  定位到失败路径缺一次对称的 `wake()`。
- 2026-09-07 RED：新增用例，改前用例真红（断言在
  `REBUILD03FlowRunnerTest.kt:263`，`AssertionError`）。
- 2026-09-07 GREEN：`FlowRunner.recordPermanentFailure()` 追加
  `consumer.wake(constraintsSatisfied = true)`；断言随之从
  「重试后仍应 QUEUED」改为「重试后应已进入下一次 TRANSFERRING」（回填
  之前是中间态断言，反映真实的同步调用时序）。
- 2026-09-07 反证：临时去掉新增的 `wake()` 调用，新用例真红，恢复后复绿。
- 2026-09-07 测试基线：Android JVM 全量 **276 tests / 0 failures / 4
  skipped**（基线 275 + 本卡 1 条新用例；XML 时间戳为本次生成）；`just ci`
  全绿（含 arch-check、queue-sync）。
- 未做：真机复核（下一轮回归时验证，非阻塞——修复本身是纯状态机对称性
  补丁，已用生产代码路径 RED→GREEN→反证完整覆盖）。
- 2026-09-12 真机复核**失败**（OPPO / v0.5.1，走查记录
  `docs/evidence/2026-09-12-oppo-051-dogfood.md` 观察 5）：25 张相册直连
  直传，传约 10 张后停止，首页显示还剩 16 张待备份、无错误提示、不再
  自动续传；改选第三个相册（1 张）后剩余照片才重新开始传输。形态与卡面
  「临时失败后卡住、需外部触发才复活」一致，但停在 10 张那一次的底层
  失败码未取证（不能排除 NET-01 家族）——开工先对齐 daemon/flow 日志的
  时间线，不许凭症状直接认领旧根因。横幅已改「真机复核失败待定位」。

## 备注

- 与本卡相关联的另外两条真机反馈（同一次回归会话）：
  - 「点击暂停反应迟钝」——按架构分析，是 `refreshFlowState()` 500ms 轮询
    + IO 调用耗时叠加的**已知量级延迟**，不是功能性 bug，本卡不处理；
    若验收人认为延迟不可接受需要产品判断是否值得优化轮询间隔，另开卡。
  - 「点击取消当前轮没有任何反应」——已开 [MOB-55](MOB-55-cancel-current-round-tap-shows-no-feedback.md)
    单独追踪（证据不足以在本卡定论，logcat 环缓冲区已轮转丢失当时记录）。
