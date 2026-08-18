# MOB-08 三星真机后台自动同步不生效——content trigger 从未触发 + 周期任务报 JobCancellationException　级别 L3【真机排障，需要连着 adb 的三星设备】

## 当前状态（2026-08-18）：✅ 已完成，用户真实快门验收通过

三根因定位并修复，**用户在卸载重装的干净环境下用真实相机拍照验收
通过**，见下面《用户真机验收结果》。

## 背景

用户实机反馈："现在三星手机，后台不主动同步内容吗？"——2026-08-18
在已配对、已完成 onboarding 的三星真机（`com.hawkeyexb.ppass`,
versionCode=6, versionName=0.3.2）上做了现场排查，发现两个后台自动
备份通道在充电+Wi-Fi 条件都满足的情况下都没有正常工作。这不是"仅
充电/仅Wi-Fi默认双开导致日常不触发"那种预期内的省电行为——排查时
手机确实在插电+连 Wi-Fi，理论上应该能跑。

> ⚠️ **2026-08-18 更正**：上面这句「插电=在充电」是错的，见下面
> 《排查结论》根因 C。`dumpsys battery` 的 `USB powered: true` 只说明
> 插着线，同一份输出里 `status: 4`（BATTERY_STATUS_NOT_CHARGING）才是
> 充电判定，而 WorkManager 认的正是后者。整份「现象 2」都建立在这个
> 错误前提上。

触发机制背景见 `apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt`
开头注释（MOB-02 事件模型）：
- 事件②新照片落库 → `scheduleContentTriggerBackup`（`CONTENT_TRIGGER_WORK_NAME`，
  `addContentUriTrigger` 监听 MediaStore 两个集合，2 分钟安静窗口 +
  15 分钟兜底）。
- 事件③周期兜底 6 小时 → `scheduleAutoBackup`/`enqueueAutoBackup`
  （`BACKUP_WORK_NAME`）。

## 已验证的现象（现场证据，均可复现）

设备环境（排查时）：`adb shell dumpsys deviceidle whitelist` 确认
`com.hawkeyexb.ppass` 在电池优化白名单；`adb shell dumpsys battery`
确认 `USB powered: true`（插着 USB 电源）；`adb shell dumpsys
connectivity` 确认 Wi-Fi `CONNECTED` 且 `IS_UNMETERED`；`adb shell am
get-standby-bucket com.hawkeyexb.ppass` = 10（ACTIVE，最不受限档位）。

### 现象 1：content trigger 从未触发

```bash
# 确认 job 15 正确注册在 content://media/external/images/media 上（dumpsys jobscheduler 的 Observers 段）：
#   content://media/external/images/media 0x0 (127534477):
#     Jobs:
#       #androidx.work.systemjobscheduler:u0a353/15 from u0a353

# 走真实 ContentProvider.insert() 代码路径（跟相机 App 落库同一条路，不是伪造）：
adb shell content insert --uri content://media/external/images/media \
  --bind _display_name:s:ppass_diag2.jpg --bind mime_type:s:image/jpeg \
  --bind relative_path:s:DCIM/Camera/

# 确认真的落库了：
adb shell content query --uri content://media/external/images/media \
  --projection _id:_display_name:date_added
#   Row: 73 _id=1000000299, _display_name=ppass_diag2.jpg, date_added=1787032812

# 插入后轮询 job 状态 120+ 秒（远超 2 分钟安静窗口）：
adb shell dumpsys jobscheduler | grep -A40 "JOB androidx.work.systemjobscheduler:u0a353/15" \
  | grep -E "Satisfied constraints|Unsatisfied constraints"
# 每次都是：
#   Satisfied constraints: CHARGING BATTERY_NOT_LOW CONNECTIVITY FLEXIBILITY DEVICE_NOT_DOZING BACKGROUND_NOT_RESTRICTED WITHIN_QUOTA UID_NOT_RESTRICTED
#   Unsatisfied constraints: CONTENT_TRIGGER   ← 全程没有变过，一次都没满足
```

在此之前还用 `adb push` 一张图到 `/sdcard/DCIM/Camera/` + 广播
`ACTION_MEDIA_SCANNER_SCAN_FILE` 做过一次同类测试，同样落库成功（后
续 `content query` 能查到），同样 `CONTENT_TRIGGER` 从未满足。两种不
同插入路径结果一致，排除单次测试方法的偶然性。

### 现象 2：周期任务（6h 兜底）触发了，但报错退出

排查期间周期任务窗口到了，`adb logcat` 抓到：

```
08-18 13:59:09.659 D WM-Processor: Processor ffee6e2a-... executed; reschedule = true
08-18 13:59:09.661 D WM-SystemJobService: ffee6e2a-... executed on JobScheduler
08-18 13:59:09.665 W PPassBackup: auto backup failed, will retry
08-18 13:59:09.665 W PPassBackup: kotlinx.coroutines.JobCancellationException: Job was cancelled; job=JobImpl{Cancelling}@35fc263
08-18 13:59:09.670 D WM-GreedyScheduler: Cancelling work ID ffee6e2a-...
08-18 13:59:09.676 D WM-SystemJobScheduler: Scheduling work ID ffee6e2a-...Job ID 23
```

即 `BackupWorker.doWork()`（`BackupWorker.kt:189` 起）内部某处 await
的协程被取消，落进 `catch (t: Throwable)` 分支（`BackupWorker.kt:280`），
记为一次失败尝试、走短退避重试，没有跑完一轮真正的备份。

同一条日志附近还有一行值得注意但目前判断为无害/预期内的信息，先记
录别重复排查：
```
D WM-GreedyScheduler: Ignoring {WorkSpec: e345d3f3-...}. Requires ContentUri triggers.
```
这是 GreedyScheduler（进程内调度器）主动把 content-trigger 类工作让
给真正支持该特性的 `SystemJobScheduler`/JobScheduler 处理，是
WorkManager 的正常分工日志，不是错误。

## 需要排查的方向（未定论，留给下一 session）

1. **`JobCancellationException` 的根因**——`doWork()` 里哪一步的协程
   被取消？优先怀疑：
   - `setForeground(foregroundInfo())`（`BackupWorker.kt:196`）在纯
     后台（非用户交互）触发时，Android 12+ 对后台启动前台服务的限制
     是否在某些系统状态下让这次提升失败/被系统收回，从而级联取消
     整个 Worker 的协程作用域？
   - `DaemonClient`/`client.bind(...)` 内部是否有自己的协程作用域，
     在某个超时或生命周期事件下被外部取消，异常沿调用栈冒泡成
     `JobCancellationException` 而不是更具体的异常类型？
   - 加更细的日志（哪一行 await 抛出的），或者本地复现（断网/切后台/
     锁屏时手动触发 `triggerUserPresentBackup` 观察是否复现同一异常）。

2. **content trigger 从未满足的根因**——按怀疑程度排序：
   - **三星 One UI 的 OEM 级后台限制**（最可能）：标准 Android 的
     Doze 白名单（`dumpsys deviceidle whitelist`）只是 AOSP 层豁免，
     三星"设备维护"里还有一层独立的"深度睡眠应用/休眠应用"名单，
     跟标准电池优化白名单是两回事，需要在真机的 设置→电池→后台
     使用限制 里额外确认这个 App 有没有被三星自己的机制限制。这是
     业内已知的三星痛点（众多同步/IM App 都撞过），值得优先验证。
   - ✅ **这一条就是根因，见《排查结论》根因 A。下面原文对它的判断
     （"这是业界标准写法"）是错的。**
   - `addContentUriTrigger(uri, false)`（`BackupWorker.kt:119`）第二
     参数 `forDescendants=false`——理论上 MediaProvider 对整个集合
     URI 的 insert 通知走的正是这个精确匹配路径（这是业界监听
     MediaStore 变化的标准写法），但如果三星的 MediaProvider 实现
     跟 AOSP 有出入（部分 OEM 定制过 MediaProvider），notifyChange
     的目标 URI 可能有差异，值得用 `adb shell dumpsys jobscheduler`
     里的 `ContentObserverController` 段配合真实拍照（不是 adb 插入）
     再测一次，排除"三星定制 MediaProvider 对 adb content insert 和
     相机真实写入两条路径处理不一致"的可能。
   - 用**真实相机拍照**（而不是 adb 模拟插入）重新走一遍这个测试，
     作为最终判定依据——虽然 `adb shell content insert` 理论上是走
     标准 ContentProvider.insert() 代码路径，跟相机 App 应该等价，但
     "应该等价"不是证据，需要真实按一次快门验证结果是否一致。

## 排查结论（2026-08-18 真机定位，SM-S9210 / One UI / API 35）

三个独立根因，其中两个是自家代码 bug（**与三星无关，在任何 Android
设备上都同样不触发**），一个是排查前提错误。「三星 OEM 后台限制」这条
原排序第一的怀疑**被证据否掉**：整个排查过程中该 job 的系统约束全绿
（`Doze whitelisted: true`、standby bucket=ACTIVE、`RUN_ANY_IN_BACKGROUND
allowed`、`BACKGROUND_NOT_RESTRICTED` 满足），同机其它 app 的 content
trigger 也在正常翻转。

### 根因 A：`addContentUriTrigger(it, false)` —— content trigger 从未触发

MediaProvider 在 insert 之后 `notifyChange` 发的是**带行 id 的 item
URI**，不是集合 URI。`forDescendants=false` 是精确匹配，收不到任何
item URI 通知，于是 `CONTENT_TRIGGER` 约束永远不满足。

现场对照（`dumpsys jobscheduler` 的 Observers 段）——修复前全机只有
我们一个观察者是 `0x0`：

```
content://media/external/images/media 0x0  ← 我们（收不到通知）
content://secmedia/images/media       0x1  ← 三星图库
content://media/external/file         0x1  ← 三星图库
```

修复后（`true`）真机实测，插入一张照片：

```
Trigger content URIs:
  1 content://media/external/images/media     ← flag 变 1
  1 content://media/external/video/media
Constraint history:
  -7m12s = ...（未满足）...                     ← App 启动时 enqueue
  -4m54s = ... CONTENT_TRIGGER ...              ← 插入后恰好 ~2min（安静窗口）
Changed URIs:
  content://media/external/images/media/1000000300
```

⚠️ 排查陷阱（上一轮就是这么误判的）：`Trigger update delay: +2m0s0ms`
的语义是**收到通知后再静默 2 分钟**才置位 `CONTENT_TRIGGER`。插入后
几秒去看必然还是 `Unsatisfied: CONTENT_TRIGGER`，这**不能**当作"没
触发"的证据。要看的是 `Changed URIs` 有没有内容、以及 constraint
history 有没有在 ~2 分钟处翻转。

### 根因 B：content trigger 跑完不重挂 —— 后台同步只在开过 App 那次有效

content trigger 是 `OneTimeWorkRequest`，被触发执行一次后 work 进入
终态，监听随之消失。`doWork()` 里没有任何重新 enqueue，只有
`scheduleAutoBackup`（App 启动）和 `rescheduleAutoBackup`（改设置）会
挂。即根因 A 修好之后，也只有开过 App 之后的第一张照片能触发。

⚠️ 这个 bug 在**失败重试路径上会被掩盖**：真机实测连插两张照片，两次
都触发了（job 27→28→29），因为 work 每次都失败（根因 C）走
`Result.retry()`，WorkManager 重排的是同一个 WorkSpec，content trigger
约束跟着一起回来了。所以验证重挂必须走**成功路径**，不能拿失败重试的
结果当证据。

修法：不能在 `doWork()` 里直接 REPLACE 同名 unique work——那会取消正在
跑的自己，亲手制造一个 `JobCancellationException`（正是现象 2 的形状）。
改用独立 name 的中转 work（`ContentTriggerRearmWorker`），延迟启动 +
等上一轮落终态后再重挂。

### 根因 C：`JobCancellationException` 的真相 —— 排查环境根本没在充电

```
USB powered: true      ← 插着线
status: 4              ← BATTERY_STATUS_NOT_CHARGING
level: 79              ← 一整天没变，current_avg ≈ 0
```

JobScheduler 的 `CHARGING` 约束认为满足（插电即可）并放行 job；
WorkManager 自己的 `BatteryChargingTracker` 再查一遍，判定未充电，于是
在 job 刚启动的同一瞬间 stopWork：

```
WM-Processor: Moving WorkSpec (c695c672-…) to the foreground
WM-ConstraintTracker: BatteryChargingTracker: initial state = false   ← 这里
WM-WorkerWrapper: Work [BackupWorker] was cancelled
androidx.work.impl.WorkerStoppedException
    at Processor.stopForegroundWork(Processor.java:227)
```

所以现象 2 不是代码 bug，是**测试前提错误**——`setForeground()` 被
打断这条原怀疑方向的方向对了（确实是 FGS 提升的同一瞬间被打断），但
原因不是 Android 12+ 后台 FGS 限制（日志明确 `Background started FGS:
Allowed … code:SYSTEM_ALLOW_LISTED`），而是充电约束当场不满足。

**对真机验收的直接影响：必须用真正的充电器，不能靠 adb 数据线供电**
（这台机插 adb 线时系统判定 NOT_CHARGING）。否则"仅充电时备份"开着的
情况下自动备份永远跑不起来，会把验收引到错误结论上。

它顺带暴露了三个真实缺陷，一并修掉：

1. `setForeground(foregroundInfo())` 原本写在 `try` **之外**——这条最
   常见的失败路径抛出的异常没有任何 catch 接得住，连日志都没有。
2. `catch (t: Throwable)` 把 `CancellationException` 当业务失败吞掉：
   计入连续失败次数、走短退避重试、还可能误发失败通知。系统 stop 不是
   业务失败，应原样抛出交回 WorkManager。
3. `finally` 里的 `client.close()` 是 suspend 函数——协程已被取消时它
   直接抛异常，清理**根本跑不到**（连接泄漏）。已用
   `withContext(NonCancellable)` 包住收尾。

新增仪器化：取消路径打印 `stopReason`（可读文本）+ 从启动到被取消的
毫秒数，用来区分"几秒内被打断"和"跑满执行时限"。

## 范围

只准动：
- `apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt`
- 如确认是三星 OEM 后台限制问题，可能需要在 `HomeScreen.kt`/引导流程
  里加一张类似 DOG-02 电池白名单卡的"去三星电池设置解除限制"引导卡
  （届时另评估是否要拆成子卡）

## 不准动

- 本卡是纯排障+修复，不顺带做本轮 UI 对齐之外的其它功能改动；发现的
  新问题（无论是否本卡范围）按 `docs/AGENT_PROTOCOL.md` §C.2 写成新
  卡，不要在本卡里顺手扩大范围。

## 可执行验收

- **反证前提**：先在断开 adb、真实充电线+真实 Wi-Fi 的条件下，用相机
  App 拍一张真实照片，计时观察这张照片从落库到出现在电脑存储端的
  延迟——这是本卡最终必须跑通的验收路径，不接受"日志看起来对了"就
  收工。
- 周期任务：`adb logcat | grep PPassBackup` 在触发窗口不再出现
  `JobCancellationException`，`auto backup: offered=... pushed=...
  ingested=...` 正常打印。
- content trigger：真实拍照后 ≤2 分钟安静窗口 + 处理时间内，
  `dumpsys jobscheduler` 里该 job 的 `Unsatisfied constraints` 不再
  含 `CONTENT_TRIGGER`，且 `PPassBackup` 日志打出成功摘要。
- 若最终定位是三星 OEM 限制且无法在应用层绕过，验收标准改为：Home
  页出现引导卡，明确告知用户"三星设备需要额外去电池设置解除限制"，
  并给出可点击的跳转（参考 DOG-02 `onOpenBatterySettings` 的实现），
  同时如实记录在 PROGRESS.md 里这是"引导用户手动解决"而非"应用层
  修复"。

## 验证记录（2026-08-18，adb 侧闭环）

### JVM 侧

- `:app:testDebugUnitTest` **179/179 绿**（4 skipped 为既有），新增 2 条
  回归锁测试。
- **反证成立**：把 `addContentUriTrigger(it, true)` 改回 `false` →
  `TriggerPolicyTest > content_trigger_wires_delays_in_constraints_builder
  FAILED`；改回 true 复绿。判据不是恒真式。
- `:app:lintDebug`：`getStopReason` 是 API 31+，minSdk 26 会 NewApi 报错
  （低版本真会崩），已加版本保护，本卡引入的 2 条 error 清零（余下 5 条
  为既有：produceState ×4 + Manifest ×1，不属本卡范围）。CI 的
  ci-android 只跑 `testDebugUnitTest` + `assembleDebug`，不跑 lint。

### 真机侧（SM-S9210）

**① 根因 A 修复生效**——注册 flag 从 `0x0` 变 `0x1`，插入照片后：

```
Constraint history:
  -7m12s = ...（未满足）...
  -4m54s = ... CONTENT_TRIGGER ...      ← 插入后恰好 ~2min（安静窗口）
Changed URIs:
  content://media/external/images/media/1000000300
```

**② 根因 B——对照组（未修复版，成功/失败都算终态）**：模拟充电后
work 跑到终态，`Worker result FAILURE` + `reschedule = false`，随即

```
[t=122s] content-trigger jobs: 29
[t=137s] content-trigger jobs:          ← 空了，且此后再无新 job 顶上
```

监听彻底消失。⚠️ 这一组的终态是 FAILURE 而非 SUCCESS——`adb content
insert` 造的是 `_size=NULL` 的空记录（无实体文件），`openInputStream`
抛 `ENOENT`。对结论无影响（任何终态都不重挂），但也顺带暴露了一个新
问题，见下面《本卡外的新发现》。

**③ 根因 B——实验组（修复版）**：清掉空记录、用 `adb push` 真实 jpg +
`MEDIA_SCANNER_SCAN_FILE` 让照片带真实文件落库后，备份真正跑通：

```
15:28:03 I PPassBackup: auto backup: offered=15 pushed=15 ingested=14
15:28:03 I WM-WorkerWrapper: Worker result SUCCESS for BackupWorker
15:28:03 D WM-Processor: executed; reschedule = false     ← 终态（对照组死在这）
15:28:30 D WM-WorkerWrapper: Starting work for ContentTriggerRearmWorker
15:28:30 I WM-WorkerWrapper: Worker result SUCCESS for ContentTriggerRearmWorker
→ dumpsys: job 34 带 2 个 content trigger URI            ← 监听被接回来了
```

**④ 端到端到达**：电脑端 `~/P-Pass NAS/originals/` 按创建时间新增
（注意：备份保留原始 mtime，按 mtime 查会漏）——

```
15:28:03  ppass_mob08_d2.jpg        ← 本次模拟的「拍照」
15:28:01  20260818_134727.mp4       ← 用户当天 13:47 真实拍摄
15:28:00  20260818_134733.jpg       ← 同上
15:27:55  20260818_134228.jpg       ← 同上
```

用户当天下午真实拍摄的照片/视频此前一直滞留在手机里没同步，本次修复
后一次补齐 15 个——这是根因 A+B 造成用户可感损失的直接证据。

**⑤ 自持循环——第二张照片全程不碰 App 也触发**（这一条才是根因 B 的
真正验收，只测一张测不出来）：

```
[t=121s] ct: 34          ← rearm 挂回来的监听
[t=136s] ct:             ← 第二张照片触发，work 正在跑
[t=151s] ct: 36          ← rearm 再次续上

15:31:47 I PPassBackup: auto backup: offered=1 pushed=0 ingested=0
         （pushed=0 是因为这张的内容与前一张完全相同，hash 去重跳过——
           幂等收敛的正常行为，不是失败）
15:31:47 I WM-WorkerWrapper: Worker result SUCCESS for BackupWorker
15:32:02 I WM-WorkerWrapper: Worker result SUCCESS for ContentTriggerRearmWorker
```

触发 → 备份 → 重挂 → 再触发的循环成立，不再依赖用户打开 App。

### 排查环境的清理

`dumpsys battery set status 2` 造的模拟充电态已 `reset`（当前回到真实
的 `status: 4`）；排查期造的测试图片（`ppass_probe` / `ppass_mob08_*` /
`ppass_diag_*`）已从手机删除，MediaStore 里 `_size=NULL` 的坏记录数
归零，只剩用户真实照片。

⚠️ **电脑端留了 3 个测试假图**（160/824 字节）在
`~/P-Pass NAS/originals/` 下：`ppass_probe.jpg`、`ppass_mob08_d2.jpg`、
`ppass_diag_1787032489.jpg`。是否删除由用户决定（删手机端不会联动删
电脑端——这是设计如此，备份不跟随源端删除）。

## 本卡外的新发现（按 §C.2 另开卡，本卡不动）

1. **一条坏记录毁掉整批备份**：MediaStore 里有记录但实体文件不存在时
   （用户删了文件、云端占位、本次的空记录），`hashWithCache` 的
   `openInputStream` 抛 `ENOENT`，异常冒泡到 `doWork` 的 catch，**整批
   备份失败并重试**。一张坏照片就能让备份永久卡死——现网风险不低。
   应当跳过坏项继续跑完剩余照片。
2. **「仅充电」档在 USB 供电但系统判 NOT_CHARGING 时静默失效**：用户
   看到手机插着线、开关开着，实际永远不备份，界面上没有任何提示。
   建议在设置/首页显示当前是否满足自动备份条件。

## 用户真机验收剧本（本卡最后一步，必须由人做）

adb 侧能证的都已经证完（见《排查结论》与《验证记录》），剩下这一步
物理上需要人按快门。**照剧本做，否则会复现假阴性**：

1. **插墙充电器，不要用连电脑的数据线**。这台机插 adb 线时系统判定
   `status: 4 NOT_CHARGING`，"仅充电时备份"档下自动备份永远不满足
   条件——上一轮排查就是栽在这个前提上（根因 C）。插上后可以用
   `adb shell dumpsys battery | grep status` 确认变成 `status: 2`。
2. 确认手机连着家里 Wi-Fi（不是热点/移动网络——默认档要求 unmetered）。
3. 确认电脑端 P-Pass 开着（daemon 在跑）。
4. **打开一次 App 再退出**（这一步只是为了确保监听已挂上；修复后正常
   使用中不需要每次都开——那正是本卡修的 bug）。
5. 用相机 App 真实拍一张照片，记下时刻。
6. 预期：≤2 分钟安静窗口 + 传输时间后，照片出现在电脑端
   `~/P-Pass NAS/originals/` 下。
7. **再拍第二张，全程不要打开 App**——第二张也必须到达。这一条才是
   根因 B（跑完不重挂）的验收，只测一张测不出来。

## 用户真机验收结果（2026-08-18，卸载重装的干净环境，真实相机拍照）

用户卸载 App 后全新安装（`firstInstallTime=2026-08-18 15:55:41`），
重新配对、选相册、**关掉「仅充电」**（原因见下），然后用相机 App 真实
拍照。文件名里的时间戳即拍摄时刻，与电脑端文件创建时间对照：

| 拍摄 | 到达 `~/P-Pass NAS/originals/` | 延迟 | 大小 |
|---|---|---|---|
| 15:57:44 | 15:59:47 | **2 分 03 秒** | 957 KB |
| 16:02:17 | 16:04:20 | **2 分 03 秒** | 3.1 MB |

两张延迟完全一致 = `CONTENT_UPDATE_DELAY_MS`（2min 安静窗口）+ ~3s
传输。**这是 content trigger 主路径在工作，不是 6h 周期兜底。**

对应日志（第二张全程未打开 App，正是根因 B 的验收）：

```
15:59:48 I PPassBackup: auto backup: offered=1 pushed=1 ingested=1   ← 第一张
16:00:03 I WM-WorkerWrapper: Worker result SUCCESS ContentTriggerRearmWorker (29ms)
16:04:21 I PPassBackup: auto backup: offered=1 pushed=1 ingested=1   ← 第二张
16:04:36 I WM-WorkerWrapper: Worker result SUCCESS ContentTriggerRearmWorker (41ms)
```

### 新增仪器化当场兑现了价值

关掉「仅充电」之前那次触发：

```
15:56:57 W PPassBackup: auto backup cancelled by system after 20ms,
                        stopReason=CONSTRAINT_CHARGING(6)
```

**20 毫秒被取消 + 原因直接可读**。修复前这里只会打一句没头没尾的
`JobCancellationException`——上一轮排查正是卡在这条日志上、误判成
"三星 OEM 后台限制"。

### 验收时必须关掉「仅充电」——这是 MOB-10，不是本卡未修完

这台机开着三星「保护电池」（`settings get global protect_battery = 2`），
充到上限（80%）后系统状态恒为 `NOT_CHARGING`，插墙充也一样。于是
产品默认的 `chargeOnly = true` 在这台设备上等于"后台档永不满足"。
本卡的三个根因与此无关（关掉开关后全部通过），但**用户实际能不能用
上自动备份取决于 MOB-10 怎么解**——那张卡已按此升级为"默认策略在
真实设备上失效"，等用户拍板。

### 另：rearm 的耗时有两种形态（符合设计，非缺陷）

正常路径 29~41ms（上一轮 work 已终态，立即重挂）；上一轮处于 retry
等待（非终态）时会轮询满 60s 后放手——那一轮 work 自己落终态时
`finally` 会再排一次 rearm，逻辑自洽，不会漏挂。

## adb 模拟未覆盖的部分（当时的顾虑，已被真实快门验收覆盖）

> ✅ 下面这段是真实快门验收之前写的顾虑，**已由上面的验收结果证伪**
> ——真实相机的 `IS_PENDING` 生命周期没有造成任何问题，两张照片都
> 正常触发并送达。保留存档，供日后类似排查参考。

本轮验证用的是 `adb push` 完整文件 + `MEDIA_SCANNER_SCAN_FILE`，文件
落库那一刻就是完整的。**真实相机走的是 `IS_PENDING=1` → 写入数据 →
`IS_PENDING=0` 的生命周期**，MediaStore 的通知时序和条目可见性跟本轮
模拟不完全等价：如果 `MediaScanner.scanSince` 恰好落在 pending 窗口
内，照片可能查不到或读不出。

这不推翻上面任何一条结论（根因 A/B 是注册与重挂层面的问题，与
pending 无关），但它正是本卡坚持"最终验收必须真实拍照"的又一条理由。
**若用户按剧本验收时出现"拍了但没同步"，第一个要查的就是这里**：
`adb shell content query --uri content://media/external/images/media
--projection _display_name:is_pending` 看新照片的 pending 状态，以及
`PPassBackup` 日志里 offered 是否为 0。

## 证据要求

真机 `adb logcat`/`dumpsys jobscheduler` 输出摘要（复现前后对比）+
真实拍照到送达存储端的实测延迟数字。不接受纯代码 review 结论。

## 跨卡声明禁令

不许写"后台自动同步已修复"却只验证了 adb 模拟插入的场景——本卡的
教训就是 adb 模拟和真实拍照可能不等价，最终验收必须有真实拍照的
实测记录。

## 收尾

Android 单测全绿（若改动涉及可测的纯函数）+ 真机实测记录（延迟数字/
日志摘录）+ PROGRESS.md 一行 + NEXT.md 状态更新 + 本卡移入 `done/`。
