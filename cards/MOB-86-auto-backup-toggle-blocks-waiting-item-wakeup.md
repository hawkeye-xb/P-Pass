# MOB-86 关闭「后台备份」总开关后，等待中的排队项失去全部唤醒路径（L1）

> ⬜ 状态：未开工 · 真机复现于 2026-09-16 真机回归会话
> 级别：**L1**（用户可自行恢复但路径反直觉，非数据丢失）· 阻塞：无

## 问题

2026-09-16 三星 SM-S9210 真机回归，复现步骤（真实操作序列，非猜测）：

1. 打开「后台备份」总开关，关闭「仅 Wi-Fi 时备份」→ 出现一次备份失败通知
   （网络原因，与本卡无关）。
2. 重新打开「仅 Wi-Fi 时备份」→ UI 正确显示「将在连接 Wi-Fi 后进行」。
3. 选择已选相册，点击「开始备份」→ 等待 10 秒 → UI 正确显示「等待
   Wi-Fi」（`WaitingForConstraints` 投影正确，`consumerStatus =
   WAITING_FOR_CONSTRAINTS`，本身符合 MOB-76 预期）。
4. 关闭「后台备份」总开关，再关闭「仅 Wi-Fi 时备份」→ UI 仍显示「正在
   等待备份条件满足」，**没有发起传输**——此时网络条件（关闭 Wi-Fi 限制
   后应可用蜂窝）已经满足，理论上应该续传，但没有任何反应。
5. 切后台/切前台、强退 App 重新打开 → 仍然停在「等待备份条件满足」。
6. 重新打开「后台备份」总开关 → **立即**开始传输，此前排队的项正常续传。

## 根因（源码已核实，非猜测）

`apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt`：

```kotlin
private fun enqueueFlowWake(..., automatic: Boolean = true) {
    if (automatic && !AutoBackupPrefs(context.filesDir).enabled()) return   // 卫兵①
    ...
}
fun scheduleAutoBackup(context: Context) {
    if (!AutoBackupPrefs(context.filesDir).enabled()) return   // 卫兵②
    ...
}
```

「后台备份」总开关关闭后：

- `MainActivity.kt` 关闭 Wi-Fi 限制时调用的 `rescheduleAutoBackup(context)`
  直接被卫兵②拦截，什么都不做；
- 用户重开 App 触发的 `ON_RESUME → foregroundCatchup()` 内部调用的
  `triggerUserPresentBackup` 走 `automatic=false`，本身不受卫兵①拦截，
  但 `foregroundCatchup` 外层有 `AutoBackupPrefs(context.filesDir).enabled()`
  这层判断（见 `MainActivity.kt:230`），总开关关闭时整个函数体直接跳过，
  同样不会触发；
- 唯一能重新唤醒这个卡在 `WAITING_FOR_CONSTRAINTS` 状态的排队项的路径，
  是用户重新打开总开关（`enableAutoBackup(context)` 内部调用了
  `scheduleAutoBackup`，此时卫兵②不再拦截）。

即：**手动发起的传输一旦进入 `WAITING_FOR_CONSTRAINTS` 等待态，用户如果
关闭「后台备份」总开关，之后即使解除了让它等待的原始条件（如关闭 Wi-Fi
限制），也没有任何路径能重新唤醒它——总开关的卫兵把"业务约束是否满足"
和"总开关是否打开"这两件不同的事焊在了一起，唯一出路是重新打开总开关，
这个因果关系对用户完全不直观。**

## 期望行为

「后台备份」总开关管的应该是**未来的自动触发**（周期性/内容监听触发的
生产者），不应该影响**已经进入等待态、由用户手动发起的这一轮**能否在
约束满足后继续。用户关闭总开关后，如果解除了导致等待的具体约束（如
关闭 Wi-Fi 限制），已经排队的这一轮应该能继续，而不需要用户额外发现
「必须重新打开后台备份总开关」这个非直观出路。

## 验收标准

- [ ] RED 先行：构造「用户手动发起传输 → 进入 WAITING_FOR_CONSTRAINTS →
      关闭总开关 → 解除约束（如关闭 Wi-Fi 限制）」场景，断言排队项应该
      被重新唤醒；改前必须真红（当前行为是永久卡住，不会自动恢复）。
- [ ] GREEN：找到不依赖总开关状态、能重新评估约束并唤醒已排队等待项的
      路径（候选：约束变更事件本身应该无条件触发一次「重新评估当前
      等待中的 Flow」，不经过 `AutoBackupPrefs.enabled()` 这层判断——
      需要先确认这条路径改动会不会影响 MOB-33 已经堵死的「总开关关闭
      时不产生新的自动触发」这条不变量，两者不能对撞）。
- [ ] 反证：把修复后的路径重新接回总开关卫兵，上面的 RED 用例必须
      再次变红——证明测试真的在断言"排队项能不依赖总开关被唤醒"。
- [ ] 真机：重复上述真实操作序列，关闭总开关+解除约束后排队项应自动
      续传，不需要用户重新打开总开关。

## 范围

- 只准动：约束变更（Wi-Fi 限制开关切换）触发唤醒的调用路径——需要找到
  一个不经过 `AutoBackupPrefs(context.filesDir).enabled()` 卫兵、但仍
  尊重 MOB-33 互斥门的唤醒方式。
- 不准动：`AutoBackupPrefs` 本身管理「未来自动触发」的语义不变；MOB-33
  的 `backupInFlight` 互斥门不动；`enableAutoBackup`/`disableAutoBackup`
  的既有行为（未来自动生产者的启停）不变。

## 阻塞与依赖

无。与 MOB-71（关闭 Wi-Fi 限制后暂停不复活等待文案）、MOB-76（Wi-Fi
限制开启时零传输）相邻但不同——MOB-71/76 管的是约束本身的闸门是否正确
执行，本卡管的是「总开关状态」意外地阻断了本应生效的约束重新评估。

---

## 实施记录

- 2026-09-16：真机回归会话中复现（见「问题」节完整操作序列），源码
  考古定位到 `BackupWorker.kt` 的两处 `AutoBackupPrefs(...).enabled()`
  卫兵（`enqueueFlowWake` 与 `scheduleAutoBackup`）共同导致约束变更后
  的重新唤醒路径全部失效，唯一恢复路径是重新打开总开关。已开卡记录，
  尚未实施修复。
