# MOB-09 一条坏 MediaStore 记录让整批备份永久失败　级别 L1【单文件 bug + 反证】

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
