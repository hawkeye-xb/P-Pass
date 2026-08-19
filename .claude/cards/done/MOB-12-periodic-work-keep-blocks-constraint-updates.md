# MOB-12 周期任务用 KEEP 导致约束变更永远进不去　级别 L1

**发现于**：MOB-10 验收当天（2026-08-19）。用户报"连拍之后没有触发同步"，
排查日志时发现一条不该存在的 `stopReason=CONSTRAINT_CHARGING(6)`——
`requiresCharging` 明明已经删掉了。

## 根因

```kotlin
fun scheduleAutoBackup(context: Context) {
    enqueueAutoBackup(context, ExistingPeriodicWorkPolicy.KEEP)   // ← 这里
    scheduleContentTriggerBackup(context)                          // REPLACE
}
```

`ExistingPeriodicWorkPolicy.KEEP` 的语义是「已存在就完全不动」，**包括
不更新约束**。于是任何一次约束变更——改设置、或者版本升级改了默认
约束——都进不了已经排好的周期任务，它会一直带着**创建那天**的约束跑
下去。

真机现场（MOB-10 删掉 requiresCharging、重装 App 之后）：

```
job 66 (content trigger, 走 REPLACE): charging=false batteryNotLow=true  ← 新
job 67 (周期兜底,       走 KEEP):     charging=true  batteryNotLow=false ← 旧
```

于是周期任务继续每 6 小时报一次 `CONSTRAINT_CHARGING(6)`。用户侧的
表现是"改了设置好像没生效"，而且极难自查——设置页显示的是新值，
实际跑的是旧约束。

`rescheduleAutoBackup` 确实用 REPLACE，但它只在用户**手动改开关**时
调用；MOB-10 之后「仅充电」开关已经删除，用户再也没有触发它的路径。

## 修复

`KEEP` → `ExistingPeriodicWorkPolicy.UPDATE`（work-runtime 2.8+）。
UPDATE 更新约束但**保留下次执行时间**，不像 REPLACE 那样重置 6h 计时
——正是这里要的语义。

## 验证

- `:app:testDebugUnitTest --rerun-tasks` **182/182 绿**，新增回归锁
  `periodic_work_uses_update_so_constraints_propagate`。
- **反证**：退回 `KEEP` → 该测试立刻红。
- 真机：装新版 + 启动一次 App 后，两个 job 的约束都变成
  `charging=false batteryNotLow=true`（修复前周期任务停留在
  `charging=true batteryNotLow=false`）。

## 教训

约束/参数类的改动，光看 content trigger（REPLACE）验证是不够的——
**周期任务是独立通道，有自己的更新策略**。以后改约束必须两条通道都
dump 一遍。
