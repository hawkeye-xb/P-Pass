# MOB-31 选了 12 张的相册，进度条显示 186 张　级别 L2

> ✅ 状态：代码已合并（commit 592b252），2026-08-27 验收人认定归档
> 级别：L2 · 阻塞：无

## 问题

用户报告（2026-08-21）：
「我勾选了一个相册，那个相册只有12个文件，结果进度条显示备份186张！！！」

已核实的事实：

| 事实 | 证据 |
|---|---|
| 选中的相册确实只有 12 张 | `content query ... where bucket_id=-1033401746` → **12** |
| 相册范围**保存正确** | `backup_scope.xml`: `bucket_ids=-1033401746`（11:18 写入） |
| 扫描确实**只扫了选中相册** | 存储端 11:19:11 `ingest.new = 12`，一张不多 |
| 成功那次 run 的输出就是 12 | WorkManager `WorkSpec.output` 解码：`ppass.backup.ingested = 12` |
| 那一次是**重试** | `ppass-catchup-backup` `run_attempt_count = 1`，11:18 有两条 `backup.started` |
| `186` 这个数**真实存在于手机状态里** | `confirmed.json` 的 `bucketOf`：**186 条属于相册 `-1739773001`**（见 MOB-29） |

**所以「选中相册 → 只扫 12 张」这条链路是对的，屏幕上的 186 是显示挑错了
记录。** 而 186 恰好等于 MOB-29 里那批陈旧「已备份」记录的条数——三张卡
（MOB-29/31/32）都绕着这个 186 转：它是相机相册的照片数。

⚠️ **别把本卡的结论扩大成"什么都没发生"。** 同一时段真的有 186 张照片被上传
到 staging 并被丢弃（MOB-32），那是另一条独立的缺陷。本卡只解释**数字为什么
是 186**，不解释那批照片去哪了。

## 期望行为

选一个 12 张的相册发起备份，进度条与三元组分母都必须是 12；界面显示永远取
**最新一次**完成的备份结果，不许随机挑一条历史终态记录。

## 验收标准

- [x] 单测：终态按 `KEY_FINISHED_AT` 时间戳挑最大值，五条通道的历史记录
  同时存在时也选最新（`the_most_recent_finished_run_wins` +
  `five_channels_of_history_still_yield_the_newest` 等，2026-08-21 绿，
  全量 252/252）
- [x] **反证 4/4 有效**（N1–N4，2026-08-21 实测全红，明细见验收证据）
- [ ] 先加日志，再复现：换相册 → 抓日志 → 确认屏幕上的数字来自哪个口径
- [ ] 定位后再改，改完必须带反证（已带，见上）
- [ ] 真机：选一个 12 张的相册，进度条与三元组分母都必须是 12

## 范围

- 只准动：`BackupUiStateHolder.kt`（`uiStateOf` 挑记录口径）、
  `BackupWorker.kt`（终态盖时间戳 + 结构化日志）及对应单测。
- 不准动：MOB-32 的 staging/孤儿问题（另一条独立缺陷，归 MOB-32）。

## 阻塞与依赖

真机验收待做。无其它前置。

---

## 根因分析

### 根因（定位到行）

`BackupUiStateHolder.kt` 的 `uiStateOf`：

```kotlin
val last = infos.lastOrNull { it.state.isFinished } ?: return null   // 旧代码
```

`lastOrNull` 取的是**列表最后一个元素**。而备份有**五条通道**，各自独立
unique name：

```
ppass-auto-backup / ppass-catchup-backup / ppass-process-catchup
ppass-manual-backup / ppass-media-watch-backup
```

它们**共用同一个 tag**，终态记录会同时躺在 WorkManager 里最多五条；而
`getWorkInfosByTagFlow` **不保证按时间排序**（Room 查询顺序，实际按 UUID）。

**所以「拿列表最后一个」= 随机挑一条历史记录。** 用户刚同步完 12 张，界面
报「186 张」——那是 8/20 那次全量运行留下的旧终态（当时它的 WorkSpec 行还在
库里，现在已被 WorkManager 清掉，所以事后查不到）。

我当时据此对用户说「**不是在执行全量同步**」——**这句是错的，已更正**。
我核到的每条事实都真：`WorkProgress` 表零行、存储端审计零 ingest、库里行数不变、
`ppass-auto-backup` 从 11:22:05 排队至今一次都没跑过。但这些只证明**我检查那一刻
没有 work 在跑**，我把它外推成了「那次全量同步没发生过」。

真相见 MOB-32：11:18–11:22 确实上传了 186 张（547MB 进 staging），commit 报
`ingested=0` 却返回成功，所以**入库审计里当然一条记录都没有**。

⚠️ **教训：审计里"没有 X 发生"不等于"X 没被尝试过"。** 被丢弃的工作恰恰不会
留下入库记录——判断"传了没有"必须去看中转区和磁盘占用。

### 改法

worker 的**每一个**终态返回都盖 `KEY_FINISHED_AT`（`successStamped()` 统一出口
+ 失败分支单独盖），`uiStateOf` 按这个戳挑最大值。没有戳的记录（升级前存量、
CANCELLED 拿不到 outputData）算最旧；**一条戳都没有**时才退回旧的列表顺序口径
（升级首帧不至于空白）。

### 验收证据

反证 4/4 有效：

```
✅ N1 终态按列表顺序挑（回到旧口径）        → the_most_recent_finished_run_wins… FAILED
                                            + five_channels_of_history_still_yield_the_newest FAILED
✅ N2 worker 不盖时间戳                    → every_terminal_outcome_carries_a_finish_stamp FAILED
✅ N3 没戳的记录按最新算（两处 0L 一起打）  → unstamped_history_never_beats_a_stamped_run FAILED
✅ N4 全无戳时不退回列表顺序                → all_unstamped_falls_back_to_list_order_not_null FAILED
```

⚠️ 反证过程中抓到我自己两个恒真式，都已修：

1. `every_terminal_outcome_carries_a_finish_stamp` 原本对**整个文件** contains
   `KEY_FINISHED_AT to System.currentTimeMillis()`——失败分支里也有同一串，
   把成功分支的戳删掉照样绿。改成夹在 `successStamped` 函数体内断言。
2. `all_unstamped_falls_back_to_list_order_not_null` 原本只放**一条**存量记录
   ——一条时任何挑法结果都一样。改成两条。

守卫：`every_terminal_outcome_carries_a_finish_stamp` 还断言正文里**不许再出现
裸 `Result.success(`**（只允许 `successStamped` 内部那一处）。真正的风险不是
这次改错，是以后有人加一个新终态返回点忘了盖戳——那条路径在 `uiStateOf` 眼里
永远是上古记录，永远选不中。

android 单测 **252/252**。

### 顺手记一笔：这轮我差点又误判

第一次跑 `./gradlew :app:compileDebugKotlin` 时我 grep 的是 `^e:|error:`，而
gradle 报的是 `Unable to locate a Java Runtime`——**根本没跑起来，我却报告
"编译过了"**。`justfile` 里 `android-test` 是带 `JAVA_HOME=$(brew --prefix
openjdk)` 的，直接调 gradlew 必须自己设。⚠️ **grep 过滤器没匹配到 ≠ 成功**，
要看退出码或 BUILD SUCCESSFUL。

### 尚未查明（不影响本卡结论）

用户报告的「186」也可能同时来自另一条路：`MainActivity.kt` 保存相册范围后
立刻 `triggerUserPresentBackup`，而 `refreshTriplet()` 只在 init / WorkInfo 流
变化时跑，`saveScope` 之后**没有显式刷新**——那一刻英雄卡的 M/N 可能还是旧范围
的数字。这条没有直接证据，且本卡的修复已经能解释现象，先不动。

### 为什么当时查不下去

`WorkProgress` 表在 work 完成时会被清空，**用户看到的那个进度数据已经不存在了**。
`ppass-catchup-backup` 的第一次尝试（被重试掉的那次）读到的 `bucketIds` 是什么、
`scan.items.size` 是多少，现在无法还原。

⚠️ **不许在卡里写一个「大概是因为…」的机制然后照着改。** 上一轮 WATCH-02 我
列了三条「最可能」的假设，三条全错，根因是一个斜杠。

### 第一步：加可观测性（本卡真正要做的）

BackupWorker 每次运行开始时打一条结构化日志，至少包含：

```
bucketIds（或 null=全量）、since(watermark)、fullRescan、scan.items.size、
triplet 的 N/M/K、run_attempt_count
```

现在 `BackupWorker` 只在跳过坏记录时 `Log.w`（`BackupWorker.kt:465`），
正常路径**一行日志都没有**，真机上什么都看不见。

### 第二个怀疑点（顺手核）

`MainActivity.kt:654-670`：保存相册范围后立刻 `triggerUserPresentBackup`。
`refreshTriplet()` 只在 init / WorkInfo 流变化时跑，**`saveScope` 之后没有
显式刷新**。所以「改完相册返回首页」那一刻，英雄卡上的 M/N 可能还是**旧范围**
的数字——旧范围如果是那个 186 张的相机相册，屏幕上就是 186。

这条能解释用户看到的现象，但**没有直接证据**，必须先复现。
