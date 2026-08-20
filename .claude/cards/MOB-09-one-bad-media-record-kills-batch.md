# MOB-09 一条坏 MediaStore 记录让整批备份永久失败　级别 L1【单文件 bug + 反证】
> ## 🟡 状态：代码已合并，等真机验收（2026-08-20 复核）
>
> `buildCandidates()` 逐条隔离 + 探针 open 已在 `BackupWorker.kt`。
> 真机侧**部分完成**：2026-08-20 用 `content insert` 造探针记录时实测到
> `W PPassBackup: auto backup: skipped 1/1 unreadable media record(s)`
> 且无 ENOENT 导致的 RETRY/FAILURE。**未做**：坏记录与好记录同批的对照
> （卡面原验收要的是 `skipped 1/2`）。


**来源**：MOB-08 排查过程中实测撞到（2026-08-18）。不属于 MOB-08 范围，
按 `docs/AGENT_PROTOCOL.md` §C.2 另开。

## 目标

MediaStore 里存在「有记录但实体文件打不开」的条目时，备份跳过这些条目
并把其余照片正常传完，而不是整批失败进重试。

## 现场证据

MOB-08 排查时用 `adb shell content insert` 造了几条 `_size=NULL` 的空
记录（有 MediaStore 行、没有实体文件）。此后每一轮自动备份都是：

```
W PPassBackup: auto backup failed, will retry
W PPassBackup: java.io.FileNotFoundException: open failed: ENOENT (No such file or directory)
    at android.content.ContentResolver.openInputStream(ContentResolver.java:1532)
    at com.hawkeyexb.ppass.backup.BackupWorker.doWork$lambda$0$0(BackupWorker.kt:259)
    at com.hawkeyexb.ppass.backup.HashCacheKt.hashWithCache(HashCache.kt:51)
    at com.hawkeyexb.ppass.backup.BackupWorker.doWork(BackupWorker.kt:265)
I WM-WorkerWrapper: Worker result RETRY / FAILURE
```

即：`doWork()` 里 `scan.items.map { … hashWithCache(…) }` 这一步，任何
一条打不开的记录都会让异常冒泡到外层 `catch (t: Throwable)`，**整批**
记为失败，走短退避重试，重试仍然撞同一条坏记录。watermark 不推进，
于是**这一条坏记录会永久卡住这台设备的所有后续备份**。

删掉那 5 条空记录之后，同一批立刻跑通：
`auto backup: offered=15 pushed=15 ingested=14`。

## 为什么现网真的会发生

不是只有 adb 造得出来。真实成因至少有：用户在文件管理器里删了文件但
MediaStore 行未同步清理、云相册/占位文件、外部存储卸载、以及第三方
App 写坏的记录。用户看到的现象会是「备份莫名其妙从某天起再也不动了」，
且没有任何界面提示（失败通知只在放弃本轮时发一次）。

## 范围

只准动：
- `apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt`
  （候选构建那一段的错误隔离）
- 如判定更合适放在扫描层：
  `apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/MediaScanner.kt`
- 对应单测文件

## 不准动

- MOB-08 正在改的 content trigger / rearm / cancellation 相关逻辑（等
  MOB-08 合并后再动本卡，或明确以 MOB-08 为前置）。
- 备份协议、BackupRunner、daemon 侧。

## 可执行验收

- 单测：构造一个 `open` 抛 `FileNotFoundException` 的候选 + 若干正常
  候选 → 期望正常候选全部进入 offered，坏候选被跳过，整体不抛异常。
- **反证**（必带）：把「跳过坏项」的逻辑去掉 → 该测试必须变红，证明
  断言不是恒真式。
- 真机：用 `adb shell content insert`（不带实体文件）造 1 条坏记录 +
  `adb push` 真实 jpg 造 1 条好记录 → 触发一轮自动备份 → 期望 logcat
  出现 `auto backup: offered=… pushed=…`（好记录传到），且**没有**
  `ENOENT` 导致的 RETRY/FAILURE。
- 决策点（实施时定并写进卡）：坏记录要不要计数上报/通知用户？建议至少
  打一条 `PPassBackup` 日志记录被跳过的条目数，别静默吞掉。

## 证据要求

单测输出 + 反证红的输出 + 真机 logcat 摘录。

## 收尾

Android 单测全绿 + PROGRESS.md 一行 + NEXT.md 状态更新 + 本卡移入
`done/`。

---

## 实施记录（2026-08-19）

### 决策点（卡面要求"实施时定并写进卡"）

1. **坏记录只打日志，不发通知、不计入失败计数。** 用户对"相册里有几行脏
   数据"无能为力，通知只制造焦虑；日志给排查用（不静默吞）。格式：
   `W PPassBackup: auto backup: skipped <n>/<total> unreadable media record(s): <前 5 个文件名>`
2. **部分跳过 → 水位照常推进**，坏行随之被永久跳过（这正是本卡要的：
   一条脏数据不许挡住其余照片）。
3. **整批都读不了 → 不 commit、不推进水位**，直接 `Result.success()` 返回。
   理由：全批失败更可能是"暂时读不到"（权限被撤、外部存储卸载）而非
   "这些行都是垃圾"；推进水位等于把这批照片永久跳过，那是真丢数据。
   代价是每轮重试一次 open（便宜）。
4. **跳过点顺带堵了缓存洞**：`hashWithCache` 命中缓存时不调 `open`
   （PERF-01），"上一轮哈希过、之后文件被删"的记录会带着旧 hash 溜进候选，
   直到 `BackupRunner.pushFile` 才抛 ENOENT——同样炸整批。候选构建里加了
   一次探针 `open().use { }`（只开关流不读内容）。
5. **`CancellationException` 必须原样上抛**，不算坏记录——吞掉它会把一次
   系统 stop（MOB-08 的配额/约束/FGS 回收）伪装成"全部跳过"的成功批次。
6. **与 MOB-13 的交叉不变量**：`fileEntriesOf` 要求文件列表与候选列表 1:1
   同序，跳过坏记录天然打破"候选 == 扫描结果"。`CandidateBuild.kept` 就是
   为此存在（产出候选的那些原始条目，与 candidates 1:1），调用处喂 `kept`
   而不是 `scan.items`。未动 ConfirmedStore.kt。

### 改动

- `apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt`
  新增 `CandidateBuild<T>` / `buildCandidates()`（逐条隔离），doWork 候选
  构建改走它 + 探针 open + 跳过日志 + 全空早退 + `files = fileEntriesOf(built.kept…)`。
- `apps/android/app/src/test/java/com/hawkeyexb/ppass/backup/BadMediaRecordTest.kt`（新）6 个测试。
- MediaScanner.kt 未动（隔离放在候选构建层更合适：扫描层不碰文件内容）。

### 证据

- 全量：`./gradlew :app:testDebugUnitTest --rerun-tasks` → BUILD SUCCESSFUL，
  206 tests / 0 failures / 4 skipped（skipped = 需要活 daemon 的 assumeTrue 用例）。
  本卡改动前基线 193 / 0 failures / 4 skipped。
- 反证 A（把 `buildCandidates` 的跳过逻辑去掉，改成无条件 rethrow）：
  4 个行为测试全红——`one_unreadable_record_does_not_kill_the_batch`、
  `every_record_unreadable_yields_empty_batch_without_throwing`、
  `cached_hash_does_not_smuggle_a_deleted_file_into_the_batch` 抛
  `java.io.FileNotFoundException`，`a_late_read_error_is_skipped_too` 抛
  `java.io.IOException`。
- 反证 B（把生产链路的探针 `open().use { }` 删掉）：
  `doWork_builds_candidates_through_the_isolating_path` 红
  （`候选构建必须先探一次 open（缓存命中不调 open，删掉的文件会溜进批次）`）。
  ⚠️ 教训：反证 B 第一次跑是**绿**的——`cached_hash_…` 那个行为测试用的是
  测试自己写的 build lambda，生产探针删了它照样绿。补了源码级断言才锁住。

### 未完成（本卡不能移入 done/）

- **真机验收未做**（无设备接入）：`adb shell content insert` 造坏记录 +
  `adb push` 真 jpg → 触发一轮 → 期望 logcat 出现 `auto backup: offered=…`
  且无 ENOENT 导致的 RETRY/FAILURE，另有 `skipped 1/2 unreadable media record(s)`。
- PROGRESS.md / NEXT.md / ROADMAP.md 未更新（等真机验收过了一起收口）。

### 顺手发现（不在本卡范围，建议另开卡）

手动备份链路 `BackupUiStateHolder.kt` 的候选构建是同一形状的裸 map + open，
同一条坏记录同样会炸掉整批手动备份。本卡范围写死只准动 BackupWorker/
MediaScanner，未动它。
