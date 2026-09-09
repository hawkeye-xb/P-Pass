# MOB-58 取消轮无常驻反馈/汇总入口 + 传输进度条混用终身口径（L1）

> 🟢 状态：真机验证通过（2026-09-09 三星），待关卡
> 当前节点：全部功能真机验证通过 · 协同分支：`main` · 阻塞：无
> 级别：**L1**（ARCH-01 §8/X-05 明确要求的用户显式操作从未接入生产，缺口在 REBUILD-05 就记录过，一直没人接）· 阻塞：无

## 问题（2026-09-07 三星真机第三次反馈，用户原话：「这个问题提了三次」）

真机点击「取消当前轮」表面上「没有反应」，用户还得点「继续」才能让它
「终止」，取消掉的照片也没有任何入口能重新传输。

根因（源码 + 卡片证据核实，不是猜的）——**两个独立缺口**：

### 缺口 1：取消瞬间没有可感知的 UI 反馈

`FlowRunner.cancelCurrentRound()` 内部先 `pause()`（把 `consumerGate` 设成
`PAUSED_BY_USER`），再调用 `cancellation.startPausedRound()` 标记取消项，
最后同一原子提交里 `cancellation.finishRound()` 立刻清空
`cancellationRound` 标记（这是 MOB-49 的既定设计：取消扫描完成后不留
"当前轮已取消"这个过渡态，直接回到用户暂停）。首页在 500ms 轮询里几乎
不可能捕捉到这个转瞬即逝的中间态，看起来就是"点了跟没点一样，跟点暂停
长得一模一样"。

首页显示的"待备份 K"张数 = 手机相册总数 N − 已确认数 M，取消只是把队列项
标记为"放弃"，不改变 N/M，这个数字本来就不会因为取消而变化——用户看到的
"挂着这个状态"实际是"暂停"状态本身一直都在，不是取消卡住了。

### 缺口 2：Restore/Discard 从未接入生产（ARCH-01 §8 X-05 被砍）

`ARCH-01` 设计文档 X-05 明确要求"验收 Restore/Discard 入口与结果"；
`CancellationRoundController` 也确实提供了 `restoreRound()`/
`discardRound()` 两个方法。但 `REBUILD-05` 验收时就发现并记录
（"已开 MOB-49"处的备注）——这两个方法**只在 JVM 测试里被调用过**，
`FlowRunner`/`AndroidFlowRuntime`/`MainActivity`/`BackupUiStateHolder`
全链路没有一处生产调用。`MOB-49` 落地时把范围明确收窄成"本卡不新增用户
确认，也不等待下一次成功传输"，只做了缺口 1（清空取消标记），X-05 的
Restore/Discard 缺口留在原地一直没人接，用户三次反馈的正是这个。

## 修复

**缺口 1**：不改变"取消=终态放弃"的既有语义（`CancellationRoundController`
内部状态机不动），加一张显式的提示卡——只要还有"已取消但未决定"的批次，
首页就展示"已跳过 N 张照片"+ 两个动作按钮，反馈从"看不见的瞬时状态"变成
"持久可见、直到用户处理"。

**缺口 2**：把 `restoreRound()`/`discardRound()` 接通到生产：
- `FlowRunner.restoreCancelledRound(roundId)`：调用
  `cancellation.restoreRound()` 把该轮标记为 `CANCELLED_BY_USER_ROUND`
  的项改回 `QUEUED`，再调用 `continueFlow()`（不是裸 `wake()`——取消完成
  后网关仍是 `PAUSED_BY_USER`，必须先重开网关才能真正开始传）。
- `FlowRunner.discardCancelledRound(roundId)`：调用
  `cancellation.discardRound()` 关闭该轮的快捷恢复入口，不复活任何项。
- `AndroidFlowRuntime.kt` 新增 `restoreCancelledFlowRound`/
  `discardCancelledFlowRound`（同样套 `flowTriggerLock`，与其余入口一致，
  避免重蹈 MOB-56 的并发缺口）。
- `flowCancelledRoundNotice(snapshot)`（纯函数）：从账本已有的
  `cancellationRoundId` 标记推导"最近一轮取消、还有多少项待决定"，
  不新增账本字段；如果用户在没处理上一轮的情况下又取消了一次
  （前提是先 discard 掉旧轮），只报告最新一轮。
- `HomeScreen` 新增提示卡（琥珀底，两个下划线动作："重新传输"/"不用了"），
  接在原有的 MOB-28/MOB-37 提示卡同一位置族。

## 验收标准

- [x] `FlowRunner` 新增 `restoreCancelledRound`/`discardCancelledRound`，
      JVM 测试覆盖：restore 后项回到 `QUEUED` 并真正被消费者拾取
      （`TRANSFERRING`）；discard 后项保持 `CANCELLED_BY_USER_ROUND`
      且不触发任何传输
- [x] `flowCancelledRoundNotice` 纯函数 5 个用例：无取消历史为 null、
      取消后计数正确、restore 后清空、discard 后清空（且不复活项）、
      两轮都未处理时只报告最新一轮
- [x] `HomeScreen` 接入提示卡 + 两个动作按钮，套用现有 `commandPending`
      守卫（避免连点排队，参见 MOB-57）
- [x] 反证：`restoreCancelledRound` 临时去掉 `continueFlow()` 调用，
      目标测试变红（网关仍是 `PAUSED_BY_USER` 时裸 `wake()` 直接返回，
      项目永远进不了 `TRANSFERRING`）；恢复后再次全绿
- [x] 全量 Android JVM 295/0/4（新增 7 个用例）、`just ci` 全绿

## 范围

- 只准动：`FlowRunner`、`AndroidFlowRuntime`、`FlowUiProjection`、
  `BackupUiStateHolder`、`HomeScreen`、`HomeNotices` 中与本卡直接相关的
  接线点，以及对应 JVM/字符串资源。
- 不准动：`CancellationRoundController` 内部状态机语义（ARCH-05 已锁定，
  X-01~X-04 不动）、`StrictConsumer`/`DiscoveryLedger` 的账本结构（不新增
  字段，只读已有的 `cancellationRoundId`）。

## 修正记录（2026-09-07，同日二次真机反馈）

首版实现本身有两个真实缺陷，用户当场复测就发现了：

### 修正 1：重复取消会丢失早期批次

`flowCancelledRoundNotice` 首版只看\"最新一轮\"的 `cancellationRoundId`，
连续点两次\"取消当前轮\"（第二次针对新一批照片）会让提示卡的 `roundId`
被覆盖，第一批取消的照片从此在 UI 上找不到、也点不到——`restoreRound`
需要精确的 `roundId` 才能调用，界面只保留了最新一个。改为**汇总所有
仍处于 `CANCELLED_BY_USER_ROUND` 的项**，不再挂在单个 `roundId` 上；
`FlowRunner.restoreAllCancelledRounds()` 一次性收集账本里全部不重复的
`cancellationRoundId` 并逐个调用 `restoreRound`，一个动作恢复全部历史
批次。

### 修正 2：去掉"不用了"这个死路按钮

用户原话：\"你就不能直接思考一下吗……如果你有一个长期的入口，你只提示
它从哪里能够恢复就可以了……你这个逻辑就没法闭环了。\"——`discardRound()`
一旦调用，账本上再没有任何字段能找回这批照片，UI 也没有历史页/设置页
入口去承接\"discard 之后想反悔\"的场景。既然做不出完整闭环，就不该有这
个按钮。改为**只保留一个常驻的\"重新传输\"入口**：复用 `NoticeCard`
统一样式（跟 MOB-37 重传提示同款），只要账本里还有未恢复的取消项就一直
显示，不会消失，`CancellationRoundController.discardRound()` 方法本身
保留（内部状态机不动，ARCH-05 语义不受影响），只是生产代码不再调用它。

### 修正 3：进度条改为本轮独立计数（用户当场追加的第二个问题）

原进度条直接用 `BackupUiState.Sending.done/total`，这组数字来自
`flowAggregateOf` 的**终身**统计（`confirmed`/`pending`），传完 15 张后
再新选一批共 50 张的相册，进度条会从\"15/15\"附近起跳，而不是新任务该有
的\"0/35\"。首页顶部的\"M/N 已回家\"大字沿用终身口径不变（这是既有裁决，
不受影响）；进度条改为独立的 `RoundProgress`（`advanceRoundProgress`
纯函数）：由 `BackupUiStateHolder` 每 500ms tick 记住上一次的 `pending`，
`pending` 下降就把差值计入 `done`（不看 `confirmed` 绝对值，避免终身
计数污染）；`pending` 上升（中途加相册）只增大 `total`，不清空已挣的
`done`；`pending` 归零（本轮真正传完）才把基线清零，下一轮从 0 开始。

## 验收标准（补充）

- [x] `flowCancelledRoundNotice` 汇总全部未恢复轮次，不再只认最新一个
      （`MOB59CancelledRoundNoticeTest.two_unresolved_cancelled_rounds_are_both_counted_in_the_notice`）
- [x] `FlowRunner.restoreAllCancelledRounds()` 一次操作恢复多个历史轮次
      （`REBUILD03FlowRunnerTest.restoring_recovers_every_distinct_cancelled_round_not_just_the_latest`）
- [x] 移除 Discard 按钮/触发函数，`CancellationRoundController.discardRound()`
      方法本身不删（保留供未来真正做历史页入口时复用）
- [x] `advanceRoundProgress` 纯函数 4 个用例覆盖：首次观测基线为 0、单项
      完成推进 done、中途加相册只增 total 不清 done、本轮清空后下一轮
      归零起算
- [x] 反证两处：`flowCancelledRoundNotice` 临时改回\"只认最新轮\"确认
      变红；`advanceRoundProgress` 临时去掉推进逻辑确认变红；均已恢复
- [x] 全量 Android JVM 298/0/4（净增 3：删 4 加 7），`just ci` 全绿



来源：`REBUILD-05`（2026-09-02）验收记录已提前预警这个缺口存在，当时按
"只做当前卡"铁律记录证据但未处理；`MOB-49` 落地时又一次明确排除了这部分
范围（"本卡不新增用户确认"）。用户 2026-09-07 反馈是第三次撞到同一个根因，
按 AGENTS.md 协同纪律，本应在缺口被发现的第一时间开卡跟踪，本卡是补记。

---

## 实施记录

- 2026-09-07：认领。源码 + 历史卡片交叉核实两个缺口的根因（不是新发现，
  是 REBUILD-05/ARCH-01 早就写明但被 MOB-49 的范围收窄留下的空白）。
  RED：`REBUILD03FlowRunnerTest` 新增 restore/discard 两个用例、
  `MOB58CancelledRoundNoticeTest` 新增 5 个纯函数用例，实现前均因方法
  不存在编译失败（合理的 RED 起点）。GREEN：`FlowRunner` 接线两个方法、
  `flowCancelledRoundNotice` 纯函数、`AndroidFlowRuntime` 两个触发函数、
  `BackupUiStateHolder` 状态与两个 action、`HomeScreen` 提示卡。反证：
  临时删除 `restoreCancelledRound` 内的 `continueFlow()` 调用，目标测试
  按预期变红；恢复后全绿。全量 Android JVM 295/0/4（+7），`just ci` 全绿。
