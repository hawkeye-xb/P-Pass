# FIX-T6 备份范围语义修复　级别 L1　【依赖：PERF-01 合并后再做】

## blocker（2026-08-10 验收人 review 实锤，两个）

1. **空集语义反转**：`BackupScopeStore.kt` 头注释写「空集 = 一个都不备」，
   但 `MediaScanner.scanSince/countAll` 用 `!bucketIds.isNullOrEmpty()`
   做过滤开关——空集与 null 同义 = **全量**。用户把相册全取消 →
   手动（BackupUiStateHolder:130）+ 自动（BackupWorker:128）都备份整库，
   与用户意图完全相反。runBackup 里「一个相册都没选会显示没有可备份」
   的注释分支永远走不到。
2. **三元组口径打架**：N = `countAll(scoped)` 按范围算，M =
   `confirmedStore.count()` 全库确认数——先全量备份过再缩范围，UI 显示
   「手机 10 张 · 已备份 51」，K 恒 0 谎报「都存好了」。DOG-01 钉死的
   「分母=当前扫描范围、口径一处定义」被 T6 改了分母没改分子。

## 方向（用户已拍板，不要另起炉灶）

- 空集 = 一个都不备：手动备份显式反馈「没有可备份的相册」，自动备份 no-op。
- 三元组 N/M/K **全部按当前范围口径**：范围外的确认数不进 M。

## 修法建议（可提替代方案，但先在卡尾写清理由再动手）

1. MediaScanner 区分 null 与空集——空集直接返回空结果 / 0，不发查询
   （也顺手消掉「空 IN ()」类 SQL 风险）。
2. ConfirmedStore 条目加 bucketId（备份记录时从 MediaItem 带过来；存量
   旧条目无 bucketId，视为范围内，随下次备份/exist-check 校准逐步补齐）；
   M = 当前范围内的确认条数。

## 不准动

两动作语义 / 水位推进 / exist-check 校准语义 / PERF-01 的哈希缓存接口。

## 可执行验收

1. 单测：空集 → `scanSince().items` 为空且 `countAll()==0`（手动+自动两条
   调用链都要有用例）。
2. 单测：范围 {相册A}，confirmed 含 A 的 3 条 + B 的 5 条 → M=3。
3. 单测或属性断言：任意组合下 UI 三元组永不出现 M > N。
4. android 全量测试绿。

## 反证

删掉空集分支 → 验收①必红（贴输出后还原）。

## 证据要求

测试输出摘录。

## 收尾

直推 main 前确认 CI 绿；PROGRESS/NEXT 各留一行；BackupScopeStore 头注释
与实际行为逐字核对一致；卡移 done/ 并附验收记录。

---
✅ **验收记录（2026-08-10，Salamira）**：
- **空集语义**：MediaScanner.scanSince/countAll 空集分支（`bucketIds !=
  null && isEmpty()`）直接返回空结果/0，不发查询（消掉「空 IN ()」风险）；
  scanSince 空集水位不推进（nextWatermark = watermark，自动备份 no-op
  不会越过范围）。BackupScopeStore 头注释已核对与实际一致（null=全量，
  空集=一个都不备）。
- **手动备份空集显式反馈**：BackupUiStateHolder.runBackup 空集 → 新状态
  `BackupUiState.NoAlbums` → `StatusLine.NoAlbums` → HomeScreen 显示
  「没有可备份的相册（一个都没选）」（en: "No albums selected — nothing
  to back up"），绝不显示假话「照片都存好了」。
- **三元组口径**：ConfirmedStore 加 `bucketOf`（hash → bucketId，备份
  记录时从 MediaItem 带过来——手动+自动双通道 recordRun 都传）+ 新方法
  `countInScope(bucketIds)`（null=全量、空集=0、非空只数范围内；存量旧
  条目无 bucketId 视为范围内，随下次备份/exist-check 校准补齐）。
  computeTripletSafe 改用 countInScope——N/M 同口径，先全量备份再缩范围
  不再显示「手机 10 张 · 已备份 51」。
- **验收③ M 永不超 N**：tripletOf 的 m clamp 到 n（UI 层防御）；
  k_is_never_negative 测试断言同步更新（m=5→3，语义注释写明）。
- **测试**：ConfirmedStoreTest +4（范围口径 A3/B5→M=3、旧条目视为范围
  内、M≤N 属性断言、recordRun 幂等带 bucket）+ 新 MediaScannerScopeTest
  +3（空集 scan 空且水位不动、空集 count=0、null≠空集走查询路径）。
  反证：删除空集守卫 → null resolver 空集路径触碰 resolver 必抛 →
  测试红（null_scope_still_means_full_scan_path 钉住「守卫是唯一分界」）。
  android 全量 **107/107**（100+7）绿 + assembleDebug 绿。
- 挂账（真机，验收人补跑）：全取消相册 → 手动备份显示「没有可备份的
  相册」；缩范围后三元组 N/M 同口径。
