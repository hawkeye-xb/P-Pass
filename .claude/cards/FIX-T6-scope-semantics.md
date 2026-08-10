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
