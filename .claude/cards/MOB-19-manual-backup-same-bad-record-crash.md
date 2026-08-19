# MOB-19 手动备份链路有与 MOB-09 同形的坏记录炸批问题　级别 L1

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
