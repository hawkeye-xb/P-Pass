# MOB-10 「仅充电时备份」在插着线但系统判未充电时静默失效　级别 L2【UX 判断 + 真机】

**来源**：MOB-08 排查过程中实测撞到（2026-08-18）。不属于 MOB-08 范围，
按 `docs/AGENT_PROTOCOL.md` §C.2 另开。

## 现象

三星 SM-S9210 插着电脑 USB 线时：

```
USB powered: true      ← 用户视角「我插着电呢」
status: 4              ← BATTERY_STATUS_NOT_CHARGING
level: 79              ← 一整天没变，current_avg ≈ 0
```

`BackupWorker` 的 `requiresCharging` 约束在 WorkManager 侧走
`BatteryChargingTracker`，它认的是「真的在充电」而不是「插着线」，于是
自动备份**永远不会跑**。而 JobScheduler 侧的 `CHARGING` 约束更宽松
（插电即算满足），会照常放行 job，job 起来后立刻被 WorkManager 停掉：

```
WM-Processor: Moving WorkSpec (…) to the foreground
WM-ConstraintTracker: BatteryChargingTracker: initial state = false
WM-WorkerWrapper: Work [BackupWorker] was cancelled
androidx.work.impl.WorkerStoppedException
```

用户侧的可见状态是：手机插着线、「仅充电时备份」开关是开的、界面一切
正常，**照片就是不同步，且没有任何提示说明为什么**。MOB-08 的上一轮
排查本身就被这个前提骗过一次（卡里写着"排查时手机确实在插电，理论上
应该能跑"）——连排查的人都会误判，用户更没机会想明白。

## 目标

让「当前不满足自动备份条件」这件事对用户可见，用户能据此行动。不改变
默认约束策略（是否放宽 charging 要求是另一个产品决策，见下）。

## 待定的产品决策（实施前需要用户拍板，不要自行选）

1. **只做可见性**：首页/设置显示「当前不满足自动备份条件：未在充电」，
   附一句人话解释（插数据线可能不算充电，建议插充电器）。改动最小，
   不动行为。
2. **可见性 + 放宽约束**：把 `requiresCharging` 换成
   `requiresBatteryNotLow`，或电量高于某阈值时不要求充电。行为变了，
   耗电特性也变了，需要产品侧确认。
3. 两者都做。

建议先做 1（纯增量、不改行为、可独立验收），2 单独评估。

## 范围（按选项 1 计）

只准动：
- `apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt`
  （或设置页对应文件）——条件不满足时的提示 UI
- 读取充电/网络状态的小工具函数（新增文件或放在 `backup/` 下）
- 对应单测（纯判定函数必须可 JVM 测）

## 不准动

- `BackupWorker.kt` 的约束策略（选项 2 才涉及，本卡默认不做）。
- MOB-08 正在改的触发/重挂逻辑。

## 可执行验收

- 单测：判定函数在（充电=false, 网络=unmetered）等各组合下返回预期的
  「不满足原因」，含**反证**（把某个条件判据改成恒真 → 测试必须变红）。
- 真机：`adb shell dumpsys battery set status 4` 模拟未充电 → App 首页
  出现提示；`set status 2` → 提示消失；测完 `dumpsys battery reset`。
- 文案必须说人话，不能是「CHARGING constraint unsatisfied」。

## 证据要求

单测输出 + 反证红 + 真机两态截图。

## 收尾

Android 单测全绿 + PROGRESS.md 一行 + NEXT.md 状态更新 + 本卡移入
`done/`。
