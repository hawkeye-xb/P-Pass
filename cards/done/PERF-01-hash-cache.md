# PERF-01 备份哈希缓存　级别 L1　【优先：先于 FIX-T6 做】

## blocker

T6（c4cfe940）把手动备份改成 since=0 全量重扫 + 对范围内**每张**照片
blake3 流式重哈希，之后才按确认缓存过滤。千张库每次点「现在备份」都是
分钟级卡在 Hashing 阶段（真机可复现），电池/IO 代价随库大小线性涨。

## 目标

同一张没变过的照片，只在第一次备份时读流哈希一次；之后的手动/自动
备份 hash 阶段命中缓存，秒级完成。

## 范围

apps/android（backup/ 下新增 HashCache + BackupUiStateHolder/BackupWorker
的 hash 阶段接线）。

## 修法

- `HashCache`：key = `(MediaStore _ID, GENERATION_MODIFIED)`（API<30 退
  `DATE_MODIFIED + SIZE`），value = blake3 hex。持久化 filesDir JSON，
  tmp+rename 崩溃安全，损坏当空不崩（与 ConfirmedStore 同款套路）。
- hash 阶段：先查缓存，miss 或 generation 变化才 openInputStream 重算并
  回写。MediaScanner 的 MediaItem 已带 generation，直接用。
- 缓存条目上限/清理策略自定（简单方案：跟随 MediaStore 现存 _ID 集合，
  校准时清孤儿），写进卡尾说明即可。

## 不准动

runBackup 两动作语义 / ConfirmedStore / 水位推进 / UI 状态机 /
FIX-T6 要改的范围语义（那是另一张卡，别顺手改）。

## 可执行验收

1. 单测：注入可计数的 open 工厂——第二次跑同一批候选，open 调用次数 = 0。
2. 单测：模拟 generation 变化的条目必须重算（该条目 open 次数 = 1）。
3. 单测：缓存文件损坏 → 当空缓存全量重算，不崩。
4. android 全量测试绿。
5. 真机（验收人补跑）：同一库第二次手动备份 Hashing 阶段秒级（贴前后耗时）。

## 反证

临时禁用缓存读取 → 验收①的 open 计数回到全量（贴输出后还原）。

## 证据要求

测试输出摘录 + 缓存文件样例。

## 收尾

直推 main 前确认 CI 绿；PROGRESS/NEXT 各留一行记录；卡移 done/ 并附验收记录。

---
✅ **验收记录（2026-08-10，Salamira）**：
- 实现：`backup/HashCache.kt`（HashCache + hashWithCache + hashCacheKey +
  hashCacheFile + pruneHashCache）；MediaItem 补 `dateModified` 字段（投影
  DATE_MODIFIED，全 API）；MediaScanner 新增 `allItemUris()`；手动
  （BackupUiStateHolder.runBackup）+ 自动（BackupWorker.doWork）双通道接线；
  校准时刻（calibrateFromDaemon / calibrateIfReachable）prune 孤儿。
- 验收①：`second_run_same_batch_opens_zero`——同批 50 候选二次跑 open=0
  （内存态 + flush 后重开实例双验证，贴 XML 输出）。
- 验收②：`generation_change_recomputes`——同 uri generation 5→6，
  第二次 open=1（重算）。
- 验收③：`corrupted_cache_reads_as_empty_full_recompute_no_crash`——
  损坏 JSON 当空全量重算（open=10）且恢复写入不崩。
- 反证：`counterproof_no_cache_read_opens_full`——空缓存 open 全量 20，
  填满后第二次 0（正反都钉死，证明命中逻辑非恒真）。
- 额外：缓存 hash 与流式 blake3 逐位一致；prune 只留现存 uri；
  API<30 key 含 dateModified+size。
- 全量：android **99/99**（92 基线 + 7 新增）绿 + assembleDebug 绿
  （输出：BUILD SUCCESSFUL，tests=99 failures=0 errors=0）。
- 清理策略（卡尾说明）：跟随 MediaStore 现存 _ID 集合，校准时刻
  （App 打开 / 备份前）清孤儿；MediaStore 查询失败跳过不影响备份。
- 真机验收挂账（验收人补跑）：同一库第二次手动备份 Hashing 阶段秒级
  （贴前后耗时）。
