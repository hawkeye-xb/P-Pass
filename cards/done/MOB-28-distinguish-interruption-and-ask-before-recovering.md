# MOB-28 区分「重启」与「被清」，被清了只提示不恢复　级别 L2

> ✅ 状态：代码已合并，真机端到端已验（见 §九），2026-08-27 验收人认定归档
> 级别：L2 · 阻塞：无

## 问题

用户在系统设置里「强行停止」App 之后，JobScheduler 清空这个 App 名下的
**全部** job——照片监听没了、周期兜底没了。这件事是**静默**的：权限还在、
配对还在，既有三张引导卡一张都不亮，用户只会觉得"照片怎么不同步了"。

用户要的语义很明确：**检测到 → 提示 → 用户点了才恢复。**
用户原话（2026-08-19，本卡的全部理由）：

> "不要做静默恢复，就是要提醒。"
> "必须点了才恢复。你都提示了，就别自作主张。"
> "你先能让他不自动拉起，监测后我们提示，用户手动拉起了？"

**取代 MOB-18**（`cards/backlog/MOB-18-force-stop-detection.md`）。
MOB-18 当初 pending 的技术前提已被 MOB-27 推翻，详见根因分析 §二。

## 期望行为

- 重启手机（用户没表达"停止"）：监听**自动恢复**。
- force-stop / OEM 清理（用户表达了"停止"，或系统代他做了）：**必须问**——
  设置页顶部出琥珀提示卡，用户点「恢复备份」才重挂监听并立刻补跑一次。
- 已经在等用户点的时候，**重启也不许悄悄替他决定**。

## 验收标准

- [x] 单测：`decideRecovery` 纯函数八种组合全覆盖（2026-08-20 全量
  234/234 绿，基线 218）
- [x] **反证 18 条全红**（含 MOB-27 的 9 条一起复跑，确认旧锁没被削弱；
  明细见根因分析 §九）
- [x] 真机端到端（0.3.4(9) / <测试机>，2026-08-20）：force-stop → 相册
  变化不拉起进程 → 打开 App 看门 job **不**自动装回 → 提示卡出现 → 点
  「恢复备份」→ 看门 job 回来 + 标志清 + 提示卡消失 + 立刻补跑一次备份
  （完整剧本与输出见 §九真机端到端）
- [ ] 已知边界不验不修：force-stop → 重启 → 打开 App 被判成"重启"自动
  恢复不提示（诚实记录于 §十，本卡不做）

## 范围

- 只准动：进程启动对账（`PPassApplication.onCreate` →
  `reconcileWatchOnProcessStart`）、`MainActivity` 的 `LaunchedEffect` 闸门、
  `BootWatchReceiver`、提示卡 UI 与文案、相关单测。（实施实动文件未逐条
  记录，以 diff 为准。）
- 不准动：MOB-27 的看门 job 机制本身（复用，不推翻）；WorkManager 自愈的
  周期任务（拦不住也不必拦）。

## 阻塞与依赖

- 前置：MOB-27 已合并（照片监听是我们自己注册在 JobScheduler 上的 job，
  WorkManager 的 `ForceStopRunnable` 碰不到它，"用户点了才恢复"才成立）。
- 无其它阻塞。

---

## 根因分析

### 二、为什么现在能做，MOB-18 当时不能

MOB-18 pending 的理由是真机实测的：

```
force-stop 前  JobScheduler job 数: 2
force-stop 后  JobScheduler job 数: 0
重开 App 后    JobScheduler job 数: 2   ← 没等我们的代码动手就恢复了
```

WorkManager 有个内建的 `ForceStopRunnable`，跑在 `androidx.startup` 的
ContentProvider 里——**比 `Application.onCreate` 还早**——检测到 App 被强停
过就把所有未完成 work 重排一遍。应用层拦不住。

**MOB-27 把这个前提推翻了。** 照片监听现在是我们自己注册在 JobScheduler
上的 job（`MEDIA_WATCH_JOB_ID`），**WorkManager 完全不知道它存在**，
`ForceStopRunnable` 碰不到它。除了我们自己调 `ensureMediaWatch`，没有任何
东西会把它装回去——"用户点了才恢复"于是成立。

本轮真机实证（0.3.4(9)，<测试机>）：

```
force-stop 后        已注册 job = 0
打开 App 之后        已注册 job = 1，其中看门 job = 0   ← 那 1 个是 WorkManager
                                                        自愈的周期任务，拦不住也不必拦
```

### 三、判据：怎么区分「重启」和「被清」

两种情况都表现为"监听不在"，但语义完全相反：

| 场景 | 用户有没有表达"停止"的意思 | 该怎么办 |
|---|---|---|
| 重启手机 | 没有 | **自动恢复**才符合预期 |
| force-stop / OEM 清理 | 有（或系统代他做了） | **必须问** |

判据是**开机时刻**：`System.currentTimeMillis() - SystemClock.elapsedRealtime()`。
`elapsedRealtime` 从开机起单调递增（含深睡不停），所以这个差在同一次开机内
是**稳定值**，重启后会变。零权限、零依赖。

容差 60 秒（`BOOT_STAMP_TOLERANCE_MS`）：NTP 校时会让墙上时钟小跳几秒，
误判的后果是"被强停过"被当成"重启过"，提示就出不来。

### 四、判定表

`decideRecovery(watchScheduled, sameBootAsLastRun, awaitingUserConsent)`
是纯函数，八种组合全部单测覆盖。

```
awaitingUserConsent -> ASK_USER      ← 顺序承重，见下
watchScheduled      -> NORMAL
!sameBootAsLastRun  -> AUTO_REARM    ← 重启 / 首次安装
else                -> ASK_USER      ← 同一次开机内凭空消失
```

**第一行必须排在最前面。** 已经在等用户点了，**重启也不许悄悄替他决定**
——否则用户重启一次手机，那条提示就凭空消失，而"备份被谁停过"这件事他
永远不会知道。这是"别自作主张"的字面要求。

`lastBootStamp = 0`（首次安装）天然落进 `!sameBoot` → 自动挂上，不会给
全新用户一上来就弹提示。

### 五、三处闸门，缺一处等于没有

用户实测栽过两次（"还是没有提示，强行停止立即就恢复了"），因为恢复路径
不止一条：

1. **`PPassApplication.onCreate`** → `reconcileWatchOnProcessStart`
   （ASK_USER 分支里既不重挂也不跑备份）
2. **`MainActivity` 的 `LaunchedEffect`** → `if (backupInterrupted) return`
   ——这条是"打开 App 就悄悄恢复"的那个漏子，MOB-14 让它无条件重挂
3. **`BootWatchReceiver`** → 走同一段 `reconcileWatchOnProcessStart`

第 1 与第 3 共用同一段判定，不许各写一份：两份实现会漂移，而漂移的后果
正是"某条路径悄悄恢复了"。

**恢复的唯一入口**是提示卡上的「恢复备份」→ `resumeAfterInterruption()`：
清标志 + 重挂 + 立刻补跑一次（人在操作，用户在场档）。

### 六、顺带做的：开机 receiver（MOB-27 §五那个待定项）

`JobInfo` 的 trigger URI 与 `setPersisted` **互斥**（AOSP javadoc 明文），
看门 job 每次重启必死。MOB-27 里我判断"加开机 receiver 性价比不明"，
**这个判断是错的**，本轮更正：

- 查合并 manifest：`RECEIVE_BOOT_COMPLETED` **本来就在**（WorkManager 带
  进来的），我们自己没声明过 → 加它**不增加任何用户可见权限**
- WorkManager 自带的 `RescheduleReceiver` 虽然监听 BOOT_COMPLETED，但
  `enabled=false`（只在 API<23 的 systemalarm 路径动态开启）→ 救不了我们
- manifest receiver **不常驻**，只在广播到来时实例化，跑完即回收

所以成本 = 一行声明。收益 = 重启后监听立刻回来，而不是等 5h 周期任务。

`onReceive` 用 `goAsync()`：返回之后进程就可被回收，而对账要读文件 + 发
binder。`finish()` 必须在 `finally`——异常路径漏掉会挂住广播。

**force-stop 之后收不到这个广播**（系统把 App 置为 stopped 态，重启也不
清除，只有用户手动打开才解除）。这正是本卡要的语义，不是缺陷。

### 七、UI

琥珀提示卡放在**设置页顶部**（打开 App 落地的第一屏），与电池白名单 /
通知引导同一族视觉。不用红色：备份没坏，只是停了，点一下就回来。

文案（en/zh 对称，`StringsSymmetryTest` 兜底）：

> 后台备份被停掉了，这段时间没有在跑。照片都还在，一张没丢。　**恢复备份**

"一张没丢"是实话，不是安慰：水位只在 commit 成功后推进，监听断掉期间的
照片一直在水位之上等下一趟车。

### 八、删掉的东西

`isBackupScheduled()`——MOB-18 那套"WorkManager 与 JobScheduler 两边对账"
的判据。MOB-27 之后它既不精确也会误导（看门 job 重启必死，它无法区分
重启与被清）。判据换成"直接查看门 job + 开机时刻"。教训保留在注释里：

> 初版只查 `getWorkInfosForUniqueWork` **完全失效**——那个 API 读的是
> WorkManager 自己的数据库，而 force-stop 清的是 JobScheduler 里的 job，
> 两套存储。force-stop 后 work 记录纹丝不动，判据恒真。

### 九、验证记录

- `:app:testDebugUnitTest --rerun-tasks` **234/234 绿**（本卡前基线 218）。
- `:app:assembleDebug` 绿。versionCode 8→9，本地回退版本名 0.3.3→0.3.4。
- **反证 18 条全红**（含 MOB-27 的 9 条一起复跑——本卡改动了共用判定，
  必须确认旧锁没被削弱）：

| # | 破坏 | 变红的测试 |
|---|---|---|
| A | 去 forDescendants | `watch_job_listens_for_descendants` |
| B | 调换派活/重挂顺序 | `watch_job_dispatches_before_it_rearms` |
| C | 排队改丢弃(KEEP) | `dispatch_queues_instead_of_dropping_or_preempting` |
| D | 去 ensure guard | `ensure_is_guard_then_schedule` |
| E | 暂停不停监听 | `paused_state_blocks_every_channel` |
| F | 备份结束不自检监听 | `every_backup_round_reconfirms_the_listener` |
| G | manifest 漏 BIND_JOB_SERVICE | `job_service_is_registered_in_manifest` |
| H | 队列去重恒真 | `skips_when_something_is_already_waiting` |
| I | 不做升级清理 | `upgrade_kills_the_legacy_workmanager_trigger` |
| J | 重启替用户决定 | `a_pending_question_survives_a_reboot` |
| K | 重启也弹提示 | `reboot_recovers_by_itself` |
| L | 提示分支偷偷重挂 | `ask_user_branch_never_rearms` |
| M | `recordInterrupted` 抹开机时刻 | `acknowledging_keeps_the_boot_stamp_too` |
| N | 打开 App 悄悄恢复 | `opening_the_app_does_not_silently_recover` |
| O | 不记开机时刻 | `reconcile_records_the_boot_stamp_before_branching` |
| P | `goAsync` finish 不在 finally | `boot_receiver_is_registered_and_survives_the_broadcast` |
| Q | manifest 漏开机 receiver | `boot_receiver_is_registered_and_survives_the_broadcast` |
| R | Application 自己判定/自己重挂 | `process_start_goes_through_the_shared_reconcile` |

#### 真机端到端（0.3.4(9) / <测试机>，2026-08-20）

```
① 正常状态                  看门 job 在岗
② am force-stop            已注册 job = 0（全清）
③ 相册变化（探针）           进程未被拉起 ← stopped 态收不到任何 job/广播，符合预期
④ 打开 App                 已注册 job = 1，看门 job = 0  ← 没有被自动装回去 ✓
                           backup_health.json:
                             {"interruptedUnacknowledged":true,
                              "detectedAt":1787138838725,
                              "lastBootStamp":1787041924048}
⑤ 设置页 UI 树              "后台备份被停掉了，这段时间没有在跑。照片都还在，一张没丢。"
                           "恢复备份"                    ← 提示真的出现了 ✓
⑥ 点「恢复备份」             看门 job 回来了 ✓
                           标志已清（interruptedUnacknowledged 字段消失=false）✓
                           提示卡消失 ✓
                           立刻补跑一次备份（logcat 有 auto backup 行）✓
```

### 十、⚠️ 已知边界（诚实记录，本卡不做）

**force-stop → 重启 → 打开 App** 这条路径会被判成"重启"，自动恢复，
不提示。原因：force-stop 之后我们的代码一行都跑不了（stopped 态），
所以"被清"这件事没人记下来；等到用户终于打开 App，开机时刻已经变了。

不做的理由：要覆盖它得有一个"force-stop 本身"的信号，而应用层拿不到
（WorkManager 的 `ForceStopRunnable` 有，但那是 internal）。而且这条路径
的语义本身可辩——重启之后 force-stop 的意图算不算过期，没有定论。
主路径（force-stop → 打开 App）已经真机验过，那正是用户实测抱怨的那条。

### 十一、教训（写进测试注释，防重犯）

1. **Kotlin 的 `substringAfter` / `substringBefore` 找不到分隔符时返回
   整个字符串**（`missingDelimiterValue` 默认是 receiver 本身）。于是
   `src.substringAfter("finally").contains("pending.finish()")` 在把
   `finally` 整块删掉之后**反而变成对全文求 contains，照样绿**——反证跑
   出来不红才发现。两个测试文件的切片类断言已全部改走 `sliceAfter` /
   `sliceBetween`（先断言锚点存在）。
2. **`codeOf` 只剥 `//` 行不够**，KDoc 块注释里的示例代码会被当成真代码
   （MOB-27 已记）。
3. **zsh 不对未加引号的变量做分词。** 反证脚本里 `for f in $ALL` 把七个
   路径当成一个文件名，备份和还原全部静默失败，18 次破坏叠加在工作区上，
   于是 D 之后每一条"红"都是脏状态的产物、不算证据。反证驱动已改成
   Python（`scratchpad/cp.py`），每轮 snapshot/restore 内存快照。
4. **反证驱动只认 `FAILED` 行会把编译失败当成绿。** 一个改坏了参数个数
   的变异让 gradle 在跑测试之前就失败，脚本报"绿了，恒真式"。驱动已加
   returncode 判断，编译失败单独标注。
5. **用索引区间重写测试时会连带切掉夹在中间的用例。** 重写
   `process_start_must_rearm_the_listener` 时把
   `upgrade_kills_the_legacy_workmanager_trigger` 一起切没了，直到反证 I
   报"绿"才发现（那条测试压根不存在了）。
6. **`grep -c` 数 dumpsys 的 job 会把历史记录算进去。** 两次差点误判
   （"看门 job 还在 5 处"实际是 0 个已注册 + 历史行）。按 `JOB ` 分块解析
   才是可靠的。
