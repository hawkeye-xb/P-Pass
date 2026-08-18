# MOB-08 三星真机后台自动同步不生效——content trigger 从未触发 + 周期任务报 JobCancellationException　级别 L3【真机排障，需要连着 adb 的三星设备】

## 背景

用户实机反馈："现在三星手机，后台不主动同步内容吗？"——2026-08-18
在已配对、已完成 onboarding 的三星真机（`com.hawkeyexb.ppass`,
versionCode=6, versionName=0.3.2）上做了现场排查，发现两个后台自动
备份通道在充电+Wi-Fi 条件都满足的情况下都没有正常工作。这不是"仅
充电/仅Wi-Fi默认双开导致日常不触发"那种预期内的省电行为——排查时
手机确实在插电+连 Wi-Fi，理论上应该能跑。

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
