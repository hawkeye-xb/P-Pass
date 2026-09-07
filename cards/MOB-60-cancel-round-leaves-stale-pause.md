# MOB-60 取消当前轮完成后仍显示暂停/继续（该回到 Idle）（L1）

> ✅ 状态：代码已合并，本地验证通过（JVM 298/0/4、`just ci` 全绿）·
> 等真机复核 · 下一步：真机确认取消完成后首页不再展示暂停/继续/取消，
> 直接落到空闲态（有已跳过项时叠加 MOB-59 常驻提示卡）· 协同分支：`main`
> 级别：**L1**（MOB-58/59 刚做完常驻提示与恢复入口，紧接着复测就发现同一
> 根因的下一层缺陷）· 阻塞：无

## 问题（2026-09-07 用户复测 MOB-58/59 后追问）

用户原话：「我取消完成之后的状态为什么是暂停呢？」「都取消完成了，你还
继续什么呢？继续传空气吗？」

点击「取消当前轮」后，账本里本轮所有可取消项（`QUEUED`/
`FAILED_NEEDS_USER`）已经被正确标记为 `CANCELLED_BY_USER_ROUND`，但首页
仍然展示「暂停」+「继续」+「取消当前轮」三个按钮——继续会重新打开网关，
但此时已经没有任何 `QUEUED`/`TRANSFERRING` 项可传，点了也是空转。

## 根因

`pause()` 是取消前的**安全前置动作**：把 `consumerGate` 设为
`PAUSED_BY_USER`，目的只是让消费者停在一个可安全切断的中间点，供
`cancellation.startPausedRound()` 在其上标记取消项。取消扫描完成
（`finishRound()`）之后，`consumerGate` 从未被归位——`FlowRunner
.cancelCurrentRound()` 把这个"取消前的安全中间态"直接当成了"取消完成后
的终态"保留了下来。

`FlowUiProjection.flowUiStateOf` 的判断顺序是
`cancellationRound != null -> Cancelled` → `consumerGate ==
PAUSED_BY_USER -> PausedByUser` → ... → `Idle`。取消完成后
`cancellationRound` 已清空，但 `consumerGate` 仍是 `PAUSED_BY_USER`，
于是命中第二条分支，首页停在"暂停"，而不是最后一条兜底的 `Idle`。

这不是"暂停"或"取消"两个词的语义错——暂停本身作为取消前的安全前置状态
没有问题；错的是取消完成后没有把闸门一并归位，导致本该走到的 `Idle`
分支永远走不到。

## 期望行为

取消当前轮执行完毕后：本轮已没有 `QUEUED`/`TRANSFERRING` 项，事实上跟
"用户还没开始传"或"上一轮全部传完"完全等价，应当直接复用已有的
`flowUiStateOf`/`backupUiStateOf` 判断链路落到 `Idle`（或如果同时有
`FAILED_NEEDS_USER` 项，落到已有的 `NeedsUserAttention`）——不需要新增
UI 状态、不需要新增判断分支。副作用：
- `HomeScreen` 里"取消当前轮"按钮只在 `state is BackupUiState.Paused`
  时渲染，`Idle` 下自动不显示，不用额外收口。
- MOB-59 的"已跳过 N 张 / 重新传输"常驻提示卡不受影响（判据是账本里
  是否还有 `CANCELLED_BY_USER_ROUND` 项，跟 `consumerGate` 无关）。

## 验收标准

- [x] `FlowRunner.cancelCurrentRound()` 在 `cancellation.finishRound()`
      之后调用 `continueFlow(constraintsSatisfied = true)`，把安全前置
      的暂停闸门归位（复用 `continueFlow`/`restoreAllCancelledRounds`
      已用的同一条归位路径，不新增归位逻辑）
- [x] `REBUILD03FlowRunnerTest
      .pause_continue_constraints_and_cancel_route_through_the_same_ledger_consumer`：
      取消完成后 `consumerGate == OPEN`、`flowUiStateOf(...) == Idle`
      （原断言"取消后仍是 PausedByUser"是本卡要修的错误行为，已改写）
- [x] `REBUILD04WorkerCutoverTest
      .continue_reopens_only_the_durable_head_and_cancel_returns_to_user_pause`：
      同一改写——取消完成后 `flowUiStateOf(...) == Idle`
- [x] 全量 Android JVM 298/0/4（改写 2 个既有断言，无新增/删除用例）、
      `just ci` 全绿

## 范围

- 只准动：`FlowRunner.cancelCurrentRound()` 的归位调用，以及随之改写
  的两个既有 JVM 断言。
- 不准动：`CancellationRoundController` 内部状态机（ARCH-05 已锁定）、
  `StrictConsumer`/`DiscoveryLedger` 账本结构、MOB-59 的
  `flowCancelledRoundNotice`/`restoreAllCancelledRounds`（本卡不改常驻
  提示卡与恢复入口，只改取消完成后的闸门归位）。

## 阻塞与依赖

无。与 MOB-51（暂停粘性）、MOB-52（OPPO 后台）互不相关；MOB-58/59 已
合并的常驻提示卡/恢复入口逻辑不受本卡影响。

---

## 实施记录

- 2026-09-07：认领。用户连续追问逼出根因：`cancelCurrentRound()` 把
  "取消前安全暂停"误当作"取消完成后的终态"保留，导致
  `flowUiStateOf` 永远命中 `PausedByUser` 分支，走不到已有的 `Idle`
  兜底。GREEN：在 `finishRound()` 后追加
  `continueFlow(constraintsSatisfied = true)`，复用已有归位路径，不
  新增状态、不新增判断分支——`HomeScreen` 的"取消当前轮"按钮渲染条件
  本来就是 `state is BackupUiState.Paused`，闸门一归位它自动消失。
  改写 `REBUILD03FlowRunnerTest`/`REBUILD04WorkerCutoverTest` 两处原本
  断言"取消后仍是 PausedByUser"的用例（这两条断言编码的正是本卡要修的
  错误行为）。全量 Android JVM 298/0/4（净变化：0 新增/0 删除，2 处
  断言改写）、`just ci` 全绿（fmt/clippy/nextest/arch-check/queue-sync）。
  未做：真机复核（无测试机可用于本次会话）。
