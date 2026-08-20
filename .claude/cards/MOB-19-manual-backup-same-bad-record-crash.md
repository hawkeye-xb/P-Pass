# MOB-19 手动备份链路有与 MOB-09 同形的坏记录炸批问题　级别 L1
> ## 🟡 状态：代码已合并，等真机验收（2026-08-20）
>
> 修法被用户改了方向：不是"照搬 MOB-09 的错误隔离"，而是**把第二条管线
> 删掉**——手动只是又一种触发方式。见文末实施记录。


**发现于**：MOB-09 实施过程中顺手读到（2026-08-19），当时卡面范围写死
只准动 `BackupWorker`/`MediaScanner`，故未动，按协议另开本卡。

## 问题

MOB-09 修的是自动备份链路：MediaStore 里「有记录但文件打不开」的条目会
让 `FileNotFoundException` 冒泡、**整批**备份失败并无限重试，watermark
不推进 = 永久卡死该设备的备份。

`apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupUiStateHolder.kt`
（约 159-181 行）的候选构建是**同一形状**的裸 `mapIndexed` + `open` +
`hashWithCache`，没有任何逐条隔离——同一条坏记录照样炸掉整批**手动**备份。

## 修法

复用 MOB-09 已经落地的 `buildCandidates()`（`BackupWorker.kt`，
`internal`，逐条 try/catch + `CancellationException` 原样上抛 +
`CandidateBuild.kept` 保持与候选 1:1 同序）。注意 MOB-09 的四条决策同样
适用，实施时逐条确认是否照搬：

1. 坏记录只打日志、不发通知；
2. 部分跳过 → 水位照常推进；
3. **整批读不了 → 不 commit、不推进水位**（防权限被撤/存储卸载时把整批
   照片永久跳过 = 真丢数据）；
4. 候选构建里要有探针 `open().use { }`——`hashWithCache` 命中缓存时不调
   `open`，「上轮哈希过、之后文件被删」的记录会带旧 hash 溜到
   `BackupRunner.pushFile` 才抛，同样炸整批。

手动链路有 UI，所以多一个决策点：**跳过的条目要不要在界面上告诉用户**？
自动链路的结论是"只打日志"（用户对脏数据无能为力，通知只制造焦虑），但
手动备份是用户主动发起、盯着结果看的，也许该显示"N 张跳过"。实施时定，
写进卡。

## 可执行验收

- 单测：手动链路构造 1 个坏候选 + 若干正常候选 → 正常的全部进入 offered，
  整体不抛异常。
- **反证**：去掉隔离 → 该测试必须变红（真跑，不许凭"应该会红"下结论）。
- ⚠️ 源码级断言必须先剥注释行再判断（MOB-09 踩过假绿：把生产代码注释掉，
  `src.contains(...)` 照样通过）。参考 `BadMediaRecordTest` 里加严版的
  `codeOf()`——它连 KDoc/块注释一起剥。

## 范围

只准动 `BackupUiStateHolder.kt` 及其单测。**不要动** `BackupWorker.kt`
里 MOB-09 刚落地的 `buildCandidates`（复用它，不改它）。

## 收尾

Android 单测全绿 + PROGRESS.md 一行 + 本卡移入 `done/`。

---

## 实施记录（2026-08-20）

### 用户定稿改变了修法

卡面原方案是"照搬 MOB-09 的逐条隔离到 BackupUiStateHolder"。用户直接否掉了
这个方向：

> "不是说应该自动和手动触发的备份一样吗？一个就是机器自动去触发，一个是
> 我们主动去触发。触发的种类不一样……手动就相当于第 5 种触发方式。
> **你为什么这里弄了两条路径去做备份呢？**"

对的。两份实现必然漂移，MOB-09 只修了其中一份就是活生生的证据。所以不是
"照搬一遍"，是**把第二条路径删掉**。

### 改动

**① 手动 = 又一种触发方式（事件⑥）**

`triggerManualBackup(context)` / `cancelManualBackup(context)` 入
`BackupWorker.kt`，与既有五种触发并列。手动专属的两个语义靠 input data
和触发档表达，管线本体一行未改：

- **零约束**（新增 `BackupTier.MANUAL`，`requiresUnmetered=false` +
  `requiresBatteryNotLow=false`）。用户定稿："ABCDE 种触发方式都会过
  Wi-Fi 电量的监测，那手动能不能在检测-发起之间，**直接人工点击-发起**？"
  ——人在场、亲手点的是当场的明确指令，压过「仅 Wi-Fi」那条**给自动备份
  定的规则**。这一档是唯一不读 settings 的。
- **全量重扫**（`KEY_FULL_RESCAN`）。忽略水位，把选中相册整个过一遍——
  「选相册」与「发起备份」是两个动作。
- `ExistingWorkPolicy.KEEP`：跑着的时候再点不打断正在传的那批。

**② 删掉第二条管线**

`BackupUiStateHolder` 298 行 → 199 行。删的是它自己那份
扫描/哈希/推送/推水位（`scanSince` / `hashWithCache` / `BackupRunner.run` /
`WatermarkStore`）。**MOB-19 是靠删除修掉的，不是靠加错误处理。**

保留的两处 `MediaScanner`/`BackupRunner` 引用是正当用途：`countAll`（三元组
分母 N）与 `existCheck`（DOG-01c 漂移校准，只查不传）。测试断言按**动作**
而非类名写死（第一版按类名一刀切把这两个判红了）。

**③ 界面状态改从 work 上读**

`BackupWorker` 新增 `setProgressAsync` 上报（scanning / hashing / sending
三阶段 + 终态 ingested/duplicates/no_albums/error），`uiStateOf(infos)` 纯函数
把 `WorkInfo` 映射成 `BackupUiState`。

- 用 `setProgressAsync` 而非 suspend 的 `setProgress`：调用点在
  `buildCandidates` 的 build lambda 与 `BackupRunner` 的进度回调里，两者都
  不是 suspend 上下文（编译器直接顶回来）。
- `ProgressThrottle`：每次上报是一条 IPC + 一次 DB 写，千张库逐张上报会把
  WorkManager 写爆。**首末两次必发**——MOB-11 的教训是"进度条像卡死然后
  突然全传完"。
- 上报失败一律吞（`runCatching`）：**上报不是业务逻辑**，不许因为界面刷新
  失败而让一批照片传不成。
- **顺带收益**：自动备份第一次有了实时进度（在此之前后台跑完只刷三元组，
  状态行全程不动）。

**④ MOB-13 的特例分支消失了**

旧手动链路有个"全已确认 → 早退 + 补齐文件级记录"的特例分支，存在的理由只是
它自己会先按确认缓存过滤掉全部候选。合并后手动走全量重扫，这批候选即使一张
都不用传（offered=N pushed=0）也照样 commit、照样 `recordRun` 写文件级记录
——迁移路径由正常路径覆盖，少一个特例就少一处会漂移的地方。
`ConfirmedStoreTest` 的相关断言已随之更新（写入点从两处变一处）。

### ⚠️ 真机核实到的事实：这个入口早就隐藏了

真机（0.3.5(10)）走查设置页，**没有「立即备份」这一项**：

```
备份哪些相册 / 仅 Wi-Fi 时备份 / 备份失败时通知我 / 存储电脑 / 版本 / 自动备份
```

`onBackupNow` 现在只剩两个触点：①备份进行中的「暂停」按钮 ②失败红卡上的
「再试一次」。`R.string.manual_backup_entry` 这条文案**已经没有任何代码引用**
（死文案）。

所以本卡修的不是"用户点得到的那个按钮"，而是**「再试一次」这条路径**——它
同样走 `backupNow()`，同样会撞坏记录、同样永久卡死。用户在失败红卡上反复点
「再试一次」而永远好不了，比设置页那个隐藏入口严重得多。

顺带：`manual_backup_entry` 死文案要不要删，留给用户定（删了 en/zh 两份，
`StringsSymmetryTest` 会跟着走）。

### 验证

- `:app:testDebugUnitTest --rerun-tasks` **247/247 绿**（本卡前基线 234）。
  新增 `OneBackupPipelineTest`（11 个）。
- `:app:assembleDebug` 绿。versionCode 9→10，本地回退版本名 0.3.4→0.3.5。
- **反证 27 条全红**（MOB-27/28 的 17 条一起复跑，确认旧锁未被削弱）：

| # | 破坏 | 变红的测试 |
|---|---|---|
| S | 手动档也查 Wi-Fi（点了不动） | `manual_tap_skips_every_constraint_check` |
| T | 手动不做全量重扫 | `manual_trigger_asks_for_a_full_rescan_and_keeps_a_running_batch` |
| U | 手动改成 REPLACE（打断正在传的） | 同上 |
| V | 进行中再点不再暂停 | `the_holder_no_longer_owns_a_second_pipeline` |
| W | 手动按钮不走统一入口 | 同上 |
| X | 进度节流吃掉最后一条 | `progress_is_throttled_but_never_swallows_the_first_or_last_tick` |
| Y | 正在跑时被历史终态覆盖 | `running_work_drives_the_status_line` |
| Z | 空列表擅自改回 Idle | `nothing_to_show_keeps_the_current_state` |
| AA | 空相册说成「都存好了」 | `an_empty_album_scope_never_says_all_safe` |

- ⚠️ **U 和 AA 第一次跑是绿的**（恒真式），原因值得记：
  `sliceAfter(src, "fun triggerManualBackup(")` 把锚点之后的**整个文件**都
  带进来了，于是"这个函数里必须是 KEEP"实际是在全文找 KEEP——而
  `triggerProcessStartCatchup` 里正好有一个。**函数级断言必须夹出函数体**
  （加了带右边界的 `sliceBetween`）。AA 则是压根没有断言覆盖 worker 发
  `KEY_NO_ALBUMS` 这件事，补了源码级断言。

### 未完成

- **真机验收挂用户**：备份进行中点「暂停」→ 停住且不 commit；再点「再试
  一次」→ 续传。（手机当时锁屏，未做，且这两个触点都要先制造一次备份/失败
  状态才能出现。）
- `manual_backup_entry` 死文案的去留待用户拍板。
