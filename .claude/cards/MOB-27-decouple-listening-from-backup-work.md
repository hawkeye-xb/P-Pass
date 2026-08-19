# MOB-27 监听与干活分家——content trigger 绕过 WorkManager，改用 JobScheduler 看门 job　级别 L2

**来源**：2026-08-19 用户实测连拍丢同步后的连续追问。方案由用户提出
（"咱们就不能参照一下 Node 或者 JS 的 event loop 吗？事件来了，我们执行完
之后再释放，不 OK 吗？"），核对 AOSP 文档后确认这**就是**官方模式。

## 一、问题

content trigger 以前直接绑在 `BackupWorker` 上：MediaStore 一变，**同一个
job** 既是"监听"又是"干活"。job 一开始跑，监听就被消耗掉，直到备份跑完 +
rearm 重挂之前，**没有任何监听在接 MediaStore 通知**。

> 备份跑 2 分钟，监听就断 2 分钟。
> 用户真机原话（2026-08-19）："前面的出去了，后面的就没有同步。"

我们在系统之外用 `ContentTriggerRearmWorker` + `catchUp` 补捞造了个假队列去
补，补丁依赖时间常数（等 1s、轮询 30×500ms）。用户当场否掉：

> "你强行用时间来做判断的话，是不太合适的。"

而且补捞的触发条件是 `catchUp = batchSize > 0`——**上一轮触发来自范围外的
写（微信收图 / 截屏 / 未勾选的相册）时范围内扫描为空，就完全不补捞**，那轮
备份期间拍的照片最长要等 5 小时。

## 二、系统本来就给了正确答案

`JobInfo.Builder#addTriggerContentUri` 的 javadoc（本机
`~/Library/Android/sdk/sources/android-36/android/app/job/JobInfo.java:1763`
逐字核对，非二手转述）：

> To continually monitor for content changes, you need to schedule a new
> JobInfo **using the same job ID** and observing the same URIs **in place of
> calling `jobFinished()`**. […] Following this pattern will ensure you do not
> lose any content changes: **while your job is running, the system will
> continue monitoring for content changes, and propagate any changes it sees
> over to the next job you schedule**, so you do not have to worry about
> missing new changes. **Scheduling the new job before or during processing
> will cause the current job to be stopped** […] your app process may be
> killed since it will no longer be in a valid component lifecycle.

三条结论，每条都推翻了旧实现的一个假设：

1. **系统就是那个事件队列。** 它在 job 运行期间持续监听并缓存变更，转交给
   你 schedule 的下一个 job。我们根本不需要自己造队列。
2. **"释放"的动作是 `schedule(同 job ID)`，不是 `jobFinished()`。**
3. **运行中重挂 = 杀掉自己**——这正是 MOB-08 那个凭空冒出来的
   `JobCancellationException`，现在有了官方解释。旧实现的
   `REARM_INITIAL_DELAY_SECONDS` 不是保守，是被这条语义逼出来的。

**我们吃不到这个语义的唯一原因是中间隔着 WorkManager**：`REPLACE` 每次新建
WorkSpec，底下 job ID 跟着换，而系统的"转交"是**按 job ID 认人**的。

> ⚠️ 排查过程中我一度断言"这个红利对我们价值为零，因为我们不读
> `getTriggeredContentUris()`"。**这句是错的**，写下来防止后人重犯：红利不是
> 那份 URI 列表（我们确实不看），而是**系统会因此立刻再投递一次**。我们是
> 水位扫描器，只需要"知道有变化"这一个信号。

## 三、方案

content trigger 这一条通道**绕过 WorkManager**，直接 JobScheduler。

新文件 `backup/MediaWatchJob.kt`：

```
onStartJob(params):                    ← 系统投递变化通知
    thread {
        派活：enqueue 备份 work（APPEND_OR_REPLACE，带约束，异步跑）
        finally 释放：schedule(MEDIA_WATCH_JOB_ID)   ← 同 ID，代替 jobFinished
    }
    return true
```

看门 Job 只做两件事，毫秒级返回。备份在 WorkManager 那边异步跑，跑多久都跟
监听无关：**看门的永远在岗，干活的爱跑多久跑多久。**

### 三个承重细节

**① 顺序：先派活，后重挂。** javadoc 说重挂会 stop 当前 job 且进程可能被杀。
先重挂的话，派活代码可能根本跑不到——监听是活的，但这一波照片没人管。
派活走后台线程 + `.result.get()` 等落库，所以 `onStartJob` 返回 `true`。

**② `ensureMediaWatch` 一律 guard-then-schedule。** javadoc 承诺的"变更转交"
只覆盖 job **running** 期，**不覆盖 pending 期**——覆盖一个正在 pending 的
trigger job 会丢掉它已积累的变更并重置 1s 防抖（MOB-14 的老坑原样适用）。
只有 `MediaWatchJob` 自己的"释放"路径用 `scheduleMediaWatchNow`（那时旧 job
正在跑，不是 pending，schedule 同 ID 正是官方要求的动作）。

**③ 派活用 `APPEND_OR_REPLACE` + 队列去重。**

| 策略 | 后果 |
|---|---|
| `KEEP` | 正在跑时把事件**吞掉**——洞又回来了 |
| `REPLACE` | **打断**正在传照片的那个 |
| 裸 `enqueue` | 两个 BackupWorker **并行**扫同一水位，重复推字节 |
| `APPEND_OR_REPLACE` | ✅ 排队等着，前一个跑完才轮到 |

去重判据 `shouldDispatchWatchBackup(states)`：已经有 `ENQUEUED`/`BLOCKED` 的
就不再排（它跑起来会扫水位以上全部，前面攒的都能捞到）。
**`RUNNING` 不算**——正在跑的那个可能已经扫过水位了，这次事件的照片它未必
看得到，必须再排一个跟在它后面。这是整张卡的核心判断。

链上某个 work 彻底失败时，排在后面的会被连坐 FAILED——这是**对的**：水位没
推进，那一轮的照片还在，后面那个跑起来也是撞同一个错。下个事件来时
`APPEND_OR_REPLACE` 会把死链整个替换掉，自愈。

## 四、顺手堵掉的第二个洞（比 gap 严重）

旧的 content trigger **带着约束**（`UNMETERED` + `batteryNotLow`）：

> **不在 Wi-Fi 的时候，监听根本不会被投递。**
> 出门拍一天照片全程 4G——那一天所有通知都不会到我们这儿。回家连上 Wi-Fi
> 也不会补，只能等 5h 兜底或用户打开 App。

拆开之后天然解决：**监听是裸的（永远在线），约束挂在派出去的备份 work 上，
每次派活现读设置。** 有新照片立刻知道，能不能传是备份 work 自己的事。

附带好处：改设置不再需要重建监听（`rescheduleAutoBackup` 只做存在性确认）。

## 五、⚠️ 重启：新方案自带的代价

同一段 javadoc：`trigger URI 与 setPeriodic / setPersisted 互斥`。
**看门 job 不可持久化，每次重启必死。**

复活链路：重启 → WorkManager 的 BOOT_COMPLETED 拉起进程跑 5h 周期任务 →
`PPassApplication.onCreate` → `scheduleAutoBackup` → `ensureMediaWatch`。

- **数据不丢**（照片还在水位之上，周期任务连扫带重挂），亏的只是时延。
- **监听空窗上限 = 周期任务首跑。**
- 要压到 0 得自己加 `BOOT_COMPLETED` receiver。**本卡不做**——多一个
  常驻广播接收器换一次开机时延，性价比不明，等真机测出实际空窗再定。

因此 `BackupWorker` 每轮结束的 `finally` 保留一句幂等的 `ensureMediaWatch`，
让 5h 周期任务同时成为"监听还在不在"的兜底自检。

## 六、改到用户旧指令的一处（需要用户知晓）

`PPassApplication` 里 `if (!isBackupScheduled) { record; return@thread }` 的
**early-return 已删除**（保留 record）。

理由：用户 2026-08-19 的原话是"必须点了才恢复。你都提示了，就别自作主张"，
**前提是"你都提示了"**。MOB-18 的提示 UI 已随功能一起 pending 进 backlog，
现在没有任何提示——不恢复就等于静默死亡。而看门 job 每次重启必死，不重挂
监听会一直失联到用户主动打开 App，比 MOB-18 想防的问题严重得多。

**副作用**：`isBackupScheduled` 从此无法区分"重启"和"被 force-stop"（两者
都表现为看门 job 不在）。将来重做 MOB-18 必须先换判据（例如落盘开机序号）。
已写进 `BackupHealth.kt` 的 KDoc。

## 七、删掉的东西

`ContentTriggerRearmWorker`、`enqueueContentTriggerRearm`、`KEY_REARM_CATCH_UP`、
`REARM_INITIAL_DELAY_SECONDS` / `REARM_WAIT_TICKS` / `REARM_WAIT_TICK_MS`、
`CONTENT_TRIGGER_WORK_NAME`、`CONTENT_REARM_WORK_NAME`、`CONTENT_TRIGGER_POLICY`、
`buildContentTriggerRequest`、`scheduleContentTriggerBackup`。
`BackupWorker.kt` 净减约 6 KB。**一个时间常数都没剩下。**

保留不动：1s 防抖 / 30s 封顶（挪到 JobInfo 上）、5h 周期兜底、打开 App 触发、
进程启动补捞、水位扫描 / hash 缓存 / manifest 去重 / 退避重试（`BackupRunner`
与 `doWork` 主体一行未改）。

## 八、验证记录

- `:app:testDebugUnitTest --rerun-tasks` **217/217 绿**（4 skipped = 需活
  daemon 的 assumeTrue 用例）。本卡前基线 207。
- `:app:assembleDebug` 绿。versionCode 7→8，本地回退版本名 0.3.2→0.3.3。
- **反证 9 条，全红**（家规必带）：

| # | 破坏 | 变红的测试 |
|---|---|---|
| A | 去掉 `FLAG_NOTIFY_FOR_DESCENDANTS` | `watch_job_listens_for_descendants` |
| B | 调换派活/重挂顺序 | `watch_job_dispatches_before_it_rearms` |
| C | 排队改成丢弃（`KEEP`） | `dispatch_queues_instead_of_dropping_or_preempting` |
| D | 去掉 `ensureMediaWatch` 的 guard | `ensure_is_guard_then_schedule` |
| E | 暂停时不停监听 | `paused_state_blocks_every_channel` |
| F | 备份结束不再自检监听 | `every_backup_round_reconfirms_the_listener` |
| G | 恢复健康检查的 early-return | `process_start_must_rearm_the_listener` |
| H | manifest 漏 `BIND_JOB_SERVICE` | `job_service_is_registered_in_manifest` |
| I | 队列去重永远派活 | `skips_when_something_is_already_waiting` |

- ⚠️ **写测试时当场撞到一个恒真式**：`codeOf` 只剥 `//` 行，KDoc 块注释里
  引用 javadoc 原文写了 `jobFinished()`，于是"不该出现 jobFinished"这条
  断言被自己的注释判红。`MediaWatchJobTest.codeOf` 已改为**先剥块注释再剥
  行注释**，教训写在函数 KDoc 里。**否定式源码断言必须剥干净块注释。**

## 九、⚠️ 真机验收 owed（本卡因此不能移入 `done/`）

无设备接入，以下三项全部未做：

1. **连拍**：100ms 级连拍 5 秒 → 期望 logcat 只出现 **1 次**
   `auto backup: offered=…`（不是 50 次）；`dumpsys jobscheduler` 里
   job 20260819 在备份跑的**全程**都存在。
2. **备份期间拍照**（本卡要解决的原始问题）：触发一轮大批量备份 → 传输过程中
   拍 3 张 → 期望**不用等下一个事件**，第一轮结束后立刻接着传这 3 张。
3. **重启**：重启手机后**不打开 App** → 观察 `dumpsys jobscheduler` 里
   job 20260819 何时回来（预期 = 5h 周期任务首跑时）。若空窗不可接受，
   开卡加 `BOOT_COMPLETED` receiver。

补充观察项：`adb shell dumpsys jobscheduler | grep -A5 ppass` 确认看门 job
**没有任何 constraint**（这是第四节那个洞的直接证据）。

## 十、范围外（不在本卡动，建议另开卡）

- **四条备份通道可并行**：`BACKUP_WORK_NAME`（周期）/ `CATCHUP_WORK_NAME` /
  `PROCESS_CATCHUP_WORK_NAME` / `MEDIA_WATCH_BACKUP_WORK_NAME` 是四个独立
  unique name，理论上可同时跑两个 BackupWorker 扫同一水位、重复推字节。
  这是 MOB-27 之前就存在的形状，本卡未扩大也未修复。
- **`BucketScreen.kt:81` lint 红**（`ProduceStateDoesNotAssignValue`）：既有
  问题，CI 不跑 lint 所以一直没暴露。与本卡无关。
