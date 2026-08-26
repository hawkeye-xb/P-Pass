# UX-14 传一半自己「暂停」了——失败重试被渲染成被暂停　级别 L1

> 🟡 状态：代码已合并，等真机验收
> 级别：**L1**（界面说了一件没发生的事）· 阻塞：无

## 问题

验收人反馈（2026-08-26 真机 0.4.0-test.8）：

> 「怎么传一半自己暂停了，你查看下日志，是否是我误触了，按道理我没碰到。」

**没有误触。** logcat 时间线：

```
17:12:48.643  auto backup cancelled by system after 26094ms, stopReason=CANCELLED_BY_APP(1)
              ← 验收人主动按的暂停（回归步骤 #10）→ 落盘 pausedAt = 17:12:48
              ← 点「继续」（#11）→ 新一轮 5d8719b9 开跑，sending 54/198 …
17:16:48.545  auto backup failed, will retry
              IrohError { kind: Stream, message: "ConnectionLost(TimedOut)" }
17:18:31.896  auto backup: offered=228 pushed=68 ingested=214     ← 自愈（约 2 分钟后）
```

## 根因

UX-13 的暂停判据（`pausedAfterOf`）：

```
paused = !anyRunning && pausedAt > 0 && newestFinishedAt < pausedAt
```

「这次暂停有没有被后来的运行覆盖」是拿**最新的带戳完成记录**判的。而失败重试
走 `BackupWorker.kt:753` 的 `Result.retry()`——**WorkManager 的 retry 结构上
拿不到 `outputData`**，那一轮不可能盖 `KEY_FINISHED_AT`。

于是：续传那一轮确实**开跑过**，却没留下任何带戳的终态。判据眼里 17:12:48
那次暂停「还没被覆盖」→ 重新算出 `Paused` → 英雄区又冒出「继续」。

UX-13 卡面写过一句「时刻不需要清除时机就能自证过期：只要出现比它更新的完成
记录，这次暂停就已经被后来的运行覆盖了」。**那句话假设每一轮都会留下终态戳，
而 retry 这条路结构上留不下。** 被自己的前提坑了。

## 决策：判据里的锚点从「最新完成时刻」换成「最新开跑时刻」

「这次暂停过期了没有」的正确判据是**之后有没有一轮备份开跑过**——不是有没有
跑完。开跑就意味着这次暂停被消费掉了；那一轮后来是成功、失败还是被系统砍，
都由它自己的状态去表达（成功 → AllSafe/Pending，最终失败 → Trouble，
退避重试中 → 保持现状）。

`WorkInfo` 拿不到开跑时刻，所以由 worker 在 `doWork` 入口落盘一个 `startedAt`
（与 `PausePrefs` 同款 tmp+rename，同一个 per-remote 目录，断开配对一起清）。

**刻意不选的两个方案：**

- 「点继续时就把 `pausedAt` 清掉」——只覆盖用户手点续传这一条路径。自动通道
  在暂停之后开跑并失败，症状原样复发。
- 「让失败路径也盖戳」——`Result.retry()` 不接受 output，做不到。改成
  `Result.failure()` 就丢掉了退避重试（MOB-02 §五 的语义），代价太大。

## 要做的

1. 新增 `backup/RunStartStore.kt`（或并入 `PausePrefs.kt`）：`startedAt` 的
   落盘，tmp+rename，读失败返回 0。
2. `BackupWorker.doWork`：**抢到互斥门之后**写 `startedAt`（抢不到的空转轮
   不算开跑——那一轮什么也没干，写了会把别人的暂停误判成已覆盖）。
3. `pausedAfterOf` 增加参数 `lastStartedAt`，判据改成
   `newestFinishedAt < pausedAt && lastStartedAt < pausedAt`。
4. `BackupUiStateHolder` 把 `startedAt` 读进来喂给判据。

## 验收标准

- [x] 单测：暂停 → 一轮开跑但**没有任何带戳终态**（模拟 retry）→ **不是** Paused
- [x] 单测：暂停 → 什么都没开跑 → 仍然是 Paused（UX-13 的本体不许被改坏）
- [x] 单测：暂停后开跑那一轮**还在跑** → Working（MOB-33 红线，`!anyRunning`）
- [x] 单测：空转轮（`KEY_SKIPPED`）不算「开跑」，不许让暂停过期
- [x] **反证**：判据去掉 `lastStartedAt` 那一项 → 第一条变红
- [ ] 真机（**留给验收人**）：暂停 → 继续 → 传输中途拔网/关 daemon 制造一次
      `ConnectionLost` → 界面**不许**又显示「继续」

## 不准动

- MOB-02 §五 的短退避重试语义（`shouldRetryAfter` / `Result.retry()`）
- MOB-33 的「界面不许自己编状态」与 `!anyRunning` 这道门
- UX-13 的「记时刻而不是布尔」这条选择（本卡是给它补一个锚点，不是推翻它）

## 实施记录

**改了四处**（与卡面 1-4 对应）：

1. `backup/PausePrefs.kt` —— 并入 `RunStartPrefs`（`run_start.json`，
   tmp+rename，同 per-remote 目录）。没另开文件：它与 `PausePrefs` 是同一个
   判据的两个锚点，分开放会让下一个人只找到一半。
2. `BackupWorker.runBackup` —— 在 `stateDir` 算出来之后立刻落 `startedAt`。
   **位置是承重的**：在 `doWork` 的 CAS 抢门**之后**（空转那一轮走不到
   `runBackup`，什么也没干的一轮不算开跑），在扫描**之前**（失败重试留不下
   终态戳，开跑这个事实是唯一一定能落下的东西）。
3. `pausedAfterOf` 加参数 `lastStartedAt`（默认 0，保既有调用点）。
4. `BackupUiStateHolder` —— 构造 `RunStartPrefs`，每次重算现读并喂进
   `uiStateOf`（worker 写的是盘，界面这边没有别的通知路径）。

顺带把 `PausePrefs.kt` 文件头那句「只要出现比它更新的**完成记录**，这次暂停
就已经被覆盖了」改掉——那句话是本卡缺陷的源头，留着会误导下一个人。

**新测试** `FailedRetryIsNotPausedTest`（6 条），钉的是不变量：

- 真机那一幕的数值化（暂停 1000 / 开跑 1100 / 无新戳）→ 必须**不是** Paused
- 暂停之后什么都没跑 → 仍然是 Paused（UX-13 本体不许改坏）
- `anyRunning` 压过一切（MOB-33 红线）
- 两个锚点是「或」的关系，旧锚点不许失效
- 落盘位置：在 `runBackup` 里（不在 doWork 抢门分支）且在 `scanSince` 之前
- 接线：holder 读盘 + 传进 `uiStateOf` + 传进判据

**测试计数**（XML 时间戳 17:43:01）：**46 类 / 347 tests / 0 failures /
4 skipped**（基线 45 / 341 → +1 类 +6 测试）。`:app:assembleDebug`
BUILD SUCCESSFUL。

**反证真跑过**——判据去掉 `lastStartedAt < pausedAt` 那一项：

```
FailedRetryIsNotPausedTest > a_run_that_started_after_the_pause_expires_it_even_without_a_stamp FAILED
FailedRetryIsNotPausedTest > the_two_anchors_are_both_honoured FAILED
347 tests completed, 2 failed, 4 skipped
```

## ⚠️ 第五次同型误伤，记在这里

`ResumeAfterPauseTest.the_paused_state_is_actually_wired_into_uiStateOf` 原本
断言 `contains("uiStateOf(infos, pausedAt)")`——钉的是**参数列表的字面形状**。
本卡给判据加第二个锚点，调用变成 `uiStateOf(infos, pausedAt, lastStartedAt)`，
这条正当改动当场把它顶红。已改成「那次调用带上了 `pausedAt`，参数列表长什么
样随意」，并把实参打进断言消息里方便下次排查。

本仓这是**第五次**同一形状的误伤（前四次：`if (backupInterrupted)
return@LaunchedEffect`、`enqueueReuploads(store.load(), reuploads, lost)`、
`return Result.success()`、`if (bucketIds != null && bucketIds.isEmpty())`）。
**源码断言只许钉「什么必须成立」，不许钉「代码长什么样」。**
