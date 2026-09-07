# MOB-58 取消当前轮无可见反馈 + 无重传入口，X-05 从未接入生产（L1）

> 🟢 状态：代码已合并，本地验证通过 · 当前节点：等真机复核 ·
> 下一步：真机确认取消有反馈、Restore/Discard 两个动作都生效 ·
> 协同分支：`main`
> 级别：**L1**（ARCH-01 §8/X-05 明确要求的用户显式操作从未接入生产，
> 缺口在 REBUILD-05 就记录过，一直没人接）· 阻塞：无

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

## 备注

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
