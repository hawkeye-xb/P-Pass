# MOB-10 「仅充电时备份」在插着线但系统判未充电时静默失效　级别 L2【UX 判断 + 真机】

## ✅ 已完成（2026-08-19）：用户拍板「把仅充电删除」，改用「电量不低」

用户原话："因为我们能耗很低，如果不好实现，我们把仅充电删除？？"

**最终方案**：`requiresCharging` 整个删掉（连同设置页开关和
`BackupSettingsState.chargeOnly` 字段），后台档改为恒定
`setRequiresBatteryNotLow(true)`。理由：
- `batteryNotLow` 判的是「电量不低」，**不受充电状态影响**，才是"别在
  快没电时折腾"的真实意图；"必须正在充电"只是它的一个坏代理。
- 局域网 P2P 传照片几十秒的事，能耗不是瓶颈，不值得为它牺牲可靠性。
- 用户在场档不设这条（人在操作，用户自己说了算）。

**验收读数**（真机 SM-S9210，**拔掉电源、`status:3` 放电中**——改之前
必被 `CONSTRAINT_CHARGING` 掐死的最严苛场景）：

```
job 约束: Requires: charging=false batteryNotLow=true deviceIdle=false
拍照 10:20:31
10:20:35.769 I PPassBackup: auto backup: offered=5 pushed=5 ingested=5
10:20:35.797 I WM-WorkerWrapper: Worker result SUCCESS
→ 4.7 秒，且把此前被 charging 挡下的积压照片一并补传
```

- `:app:testDebugUnitTest --rerun-tasks` **181/181 绿**（新增回归锁
  `charging_constraint_is_gone_for_good` + 旧 json 兼容断言）。
- **反证**：把 `setRequiresCharging` 加回来 → 该测试立刻红。
- 升级路径：旧版存过的 `{"chargeOnly":...}` 由 `ignoreUnknownKeys`
  忽略，`wifiOnly` 原样读出（有显式测试，防止悄悄把用户关掉的
  「仅 WiFi」打开）。

原始排查记录见下。


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

## ⚠️ 追加证据（2026-08-18 当天晚些时候）：这不是边缘情况，是这台机的常态

用户换成**真墙充**之后，实测：

```
15:43:44  status:2 (CHARGING)      ac:true   level:79    ← 插上，开始充
15:43:54  status:2                 current_avg:623       ← 充电中
15:44:24  status:4 (NOT_CHARGING)  level:80              ← 充了 40 秒就停
15:47:56  status:4                 ac:true               ← 之后一直未充电
adb shell settings get global protect_battery → 2        ← 三星「保护电池」开着
```

即：**三星「保护电池」把充电限制在上限（这台机表现为 80%），到达上限
后系统状态就是 NOT_CHARGING**。所以只要用户电量在上限附近——这正是
一台天天插着充的手机的常态——「仅充电时备份」就等于「永不备份」，
插不插电、插墙充还是数据线，都一样。

这把本卡从"UX 可见性问题"提升为**默认策略在真实设备上失效**：
`chargeOnly = true` 是产品默认值（`BackupSettings.kt`），而开着保护
电池的三星机（以及任何有充电上限功能的设备：小米、OPPO、部分
Pixel/iOS 同类功能）在满电时永远不满足这个约束。MOB-08 的三个根因
修完之后，这一条会成为「后台自动同步仍然不工作」的下一个原因。

因此选项 2（放宽约束）不再是"可选项"，需要用户优先拍板。备选思路：
`requiresCharging` 改为「插着电源即可」而不是「正在充电」——
`BatteryManager.EXTRA_PLUGGED != 0` 能区分这两者，WorkManager 的
`setRequiresCharging` 做不到，需要自己在 doWork 里判定或换约束组合。

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
