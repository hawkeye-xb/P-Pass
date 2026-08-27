# MOB-35 中断待确认时，连「用户在前台」的同步也被冻住　级别 L1

> ✅ 状态：代码已合并（commit 8bbe178），2026-08-27 验收人认定归档
> 级别：L1 · 阻塞：无（2026-08-25 用户已给判断与理由）

## 问题

`MOB-28` 的语义是：监听被主动掐掉（force-stop / OEM 清理）后**不静默恢复**，
挂提示等用户点。用户原话（2026-08-19）：「不要做静默恢复，就是要提醒。」
「必须点了才恢复。你都提示了，就别自作主张。」

这条本身没错，但实现把**两件不同的事**用一个 `return` 一起挡了
（`MainActivity.kt:181`）：

```kotlin
LaunchedEffect(backupInterrupted) {
    ...
    if (backupInterrupted) return@LaunchedEffect   // ← 一个 return 挡了两件事
    scheduleAutoBackup(context)        // 重挂后台监听 —— 该被挡
    triggerUserPresentBackup(context)  // 前台补捞   —— 不该被挡
}
```

于是 force-stop 之后，**即使用户把 App 打开摆在眼前，也一张都不传**，界面只
显示「有未同步的照片」，直到他找到并点下恢复按钮。

### 真机实测（2026-08-25）

```
步骤1  force-stop                → 我们的 job 0 个        （合理）
步骤2  停止期间塞照片             → 不上传                  （合理）
步骤3  重开 App（前台、已配对）    → WorkManager 只有 +3h57m 的 5h 兜底
步骤4  轮询 90 秒                → 一张都没传             （不合理）
```

## 用户定调（2026-08-25）

> 「按道理，我强行停止，包括后台监听也停止了，是合理的。重新启动之后，我依旧
> 没有启动后台是合理的，但是前台情况下，都无法上传，是不是不合理呢？」

给出的状态模型：

| 状态 | 该怎样 |
|---|---|
| App 前台、未授权后台 | **前台同步** |
| 前台与后台同时可用 | 都能走，但主要走前台更合理 |
| 被 OS 回收、前台作废、后台没启动 | 不同步（合理） |
| 被 OS 回收、后台已启动 | 后台同步 |

核心：**前台 = 人在场 = 该传。** 用户打开 App 本身就是意思表示，而且他看得见
进度——不存在「自作主张」的问题。`MOB-28` 要防的是「背着用户悄悄把后台监听装
回去」，不是「人在看着也不许传」。

## 期望行为

- `backupInterrupted` 为真时：**继续挡** `scheduleAutoBackup`（不重挂后台监听），
  **放行** `triggerUserPresentBackup`（前台补捞照常跑）。
- 中断提示的文案跟着改：它说的是「**后台自动备份已停**，点一下恢复」，
  而不是「什么都没在传」——前台明明在传，文案不能自相矛盾。

## 验收标准

- [ ] 单测：`backupInterrupted = true` + 前台启动 → `CATCHUP_WORK_NAME` 的 work
  **被入队**
- [ ] 单测：同一条件下 `MediaWatchJob` **仍未**重挂（`MOB-28` 的红线不许破）
- [ ] 反证：把放行改回一起挡 → 第一条变红
- [ ] 单测：文案 key 变更后 en/zh 对称测试仍绿
- [ ] 真机：force-stop → 停止期间拍照 → 重开 App 放前台不动 → **照片自动传上去**，
  同时提示仍在（提示说的是后台，不是全部）

## 范围

- 只准动：`MainActivity.kt` 那个 `LaunchedEffect` 的门控、中断提示文案与
  `assets/i18n`（含 Android 捆绑副本，否则 `DiagTextTest` 漂移守卫会红）
- 不准动：`BackupHealth.kt` 的 `decideRecovery` 判据（开机时刻那套逻辑是对的）；
  `resumeAfterInterruption` 作为唯一重挂入口这条红线

## 阻塞与依赖

无。

---

## 备注

排查过程里被证明**不是** bug 的两条，一并记下来免得下次重查：

- **上滑从最近任务划掉 → 照片照常自动同步。** 真机实测 17:19 那轮
  `ingested=3` 就是划掉之后拍的三张，自动上去的。`am kill` 下端到端 2 秒。
- **只有 force-stop（设置里的「强行停止」）会停。** 它取消我们包名下所有 job
  并把包标记 `stopped=true`，这是 Android 的语义，应用无法自行复活——本卡不
  试图改这一点，只改「重开之后前台该不该传」。

## 实施记录（2026-08-25）

**改动三处**：

1. `MainActivity.kt` 的 `LaunchedEffect(backupInterrupted)` —— 一个
   `if (backupInterrupted) return@LaunchedEffect` 拆成
   `if (!backupInterrupted) scheduleAutoBackup(context)` + 无条件的
   `triggerUserPresentBackup(context)`。后台监听仍受门控（MOB-28 红线不动），
   前台补捞放行。
2. 文案（`res/values-zh` + `res/values`）—— 点明停的是**后台自动备份**、
   且**打开 App 时照样会传**。原文案「后台备份被停掉了，这段时间没有在跑」
   在前台会传之后就自相矛盾了。
3. `WatchRecoveryTest.opening_the_app_does_not_silently_recover` —— 断言从
   「形状」改成「不变量」。它原来断言的是
   `contains("if (backupInterrupted) return@LaunchedEffect")` 这个具体写法，
   现在断言的是「重挂必须受中断标志门控」 +「块内不许整块早退」。
   **守的东西没变，只是不再钉死实现形状。**

**新增测试** `ForegroundSyncNotFrozenTest`（4 例）：前台补捞不受门控 /
后台重挂仍受门控 / `resumeAfterInterruption` 仍是唯一重挂入口 /
文案点明停的是后台且前台仍会传。

**测试输出**：
- Android 全量 `--rerun-tasks`：**37 个测试类 / 267 tests / 0 failures**
  （从 test-results XML 数，时间戳 18:17:25 确认本次生成）
- `assembleDebug` 绿

**反证（真跑）**：把 `MainActivity.kt` 改回旧写法（`if (backupInterrupted)
return@LaunchedEffect`）→ `ForegroundSyncNotFrozenTest` **4 例中 2 条红**：
`foreground_catchup_is_not_gated_by_the_interruption_flag` 与
`background_rearm_is_still_gated`。改回后全绿。

**真机验收还欠（验收人自己跑）**：force-stop → 停止期间拍照 → 重开 App
放前台不动 → **照片自动传上去**，同时中断提示仍在（提示说的是后台，不是全部）。

### 补记（同日）：第一版漏了两处「顺带重挂」，MOB-28 红线一度被破

只拆 `MainActivity` 那个 `return` 是**不够的**。前台补捞一放行，那趟 work 会跑到
`BackupWorker.doWork` 的 `finally`，那里有一句幂等的 `ensureMediaWatch(ctx)`
（MOB-27 留的「每 5h 至少自检一次监听在不在」）。后果：用户 force-stop、提示还
挂着、一次「恢复」都没点，**后台监听自己回来了**。同款第二处是
`rescheduleAutoBackup`（改备份设置那条路径）。

**上面那 4 条单测抓不到它** —— 它们断言的是那个 `LaunchedEffect` 块，而破线发生
在下游 work 的 `finally` 里。

修法：新增 `mayRearmWatchIncidentally(context)`（读
`BackupHealthPrefs.interruptedUnacknowledged`），两处「顺带」重挂都过它；
`scheduleAutoBackup` 不设门 —— 它是 `resumeAfterInterruption` 走的显式入口，
MOB-28 定的唯一入口必须无条件生效。

新增第 5 条测试 `every_incidental_rearm_path_is_gated`，判据是**全文级**的：
`ensureMediaWatch(` 的每一处调用要么带门控、要么在 `scheduleAutoBackup` 函数体内。
反证真跑：去掉 `finally` 那处门 → 红，且报出
「第 369 行的 ensureMediaWatch 没有门控」。

最终计数：Android 全量 **37 类 / 268 tests / 0 failures**（XML 18:21:49），
`assembleDebug` 绿。

**教训（MOB-28 卡面早写过，这次轮到我踩）：闸门必须立在每一条能重挂的路径上，
缺一处就等于没有。** 块级断言守不住跨函数的不变量——判据得跟不变量同一个作用域。
