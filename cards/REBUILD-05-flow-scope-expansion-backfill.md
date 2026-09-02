# REBUILD-05 Flow 范围扩展补扫接线（L2）

> 🟡 状态：进行中 · 协同分支：`main` · 前置：REBUILD-04 代码切换
> 级别：L2 · 阻塞：无
> 当前节点：已认领，先写范围扩展游标前补扫的失败回归测试 · 下一步：最小接线 ScopeRevision / backfill 后跑 Android JVM 与三星验收

## 问题

新 Flow 的发现游标覆盖已选范围中的两个相册，但第三个已选测试相册的 4 项都在
持久游标之前，未进入 Flow ledger。旧相册选择页只重置 legacy `WatermarkStore`，
没有向 Flow 记录 ScopeRevision 或 backfill 请求；因此扩大范围后的旧项不会进入
新生产队列，无法开始 Pause / Continue / Cancel 真机验收。

## 期望行为

保存范围时，范围扩大必须以新的 Flow ScopeRevision 记录补扫请求；位于当前
DiscoveryCursor 之前、但新进入已选范围的媒体也必须原子入账。已确认项保持
`CONFIRMED`，不因范围补扫重复传输；新队列仍由同一严格消费者处理。

## 验收标准

- [ ] 范围扩大后，游标之前且属于新增测试相册的媒体进入新 Flow ledger；现有
  `CONFIRMED` 项不重复入队或传输。
- [ ] 自动测试覆盖 ScopeRevision / backfill 与 cursor 的组合；移除 Flow backfill
  接线时测试必须失败。
- [ ] 三星独立测试相册中，已选范围 30 项全部得到可解释状态：26 项经确认，1 项
  内容去重，另 3 项进入后续 Flow 队列或具有明确终态；不触碰真实照片库。
- [ ] REBUILD-04 的传输中 Pause → 杀 App → 重开仍 Pause → Continue 原队头续传 →
  Cancel Current Round 不传剩余项真机验收通过。

## 范围

- 只准动：`apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/`、范围保存到
  Flow 的接线、对应 Android JVM 测试、REBUILD-04 真机验收记录。
- 不准动：旧 Worker/batch 机制复活、低频远端对账、真实照片库数据、无关 UI 优化。

## 阻塞与依赖

REBUILD-04 的代码切换已在 main；本卡完成后释放其剩余真机验收。

## 发现记录

2026-09-02 真机验收前置（仅聚合状态、未输出照片名称/路径）：已选 3 个测试相册
共 30 项，Flow ledger 有 26 项且均 `CONFIRMED`；每个已确认项都持有内容 hash，
其中 25 个 hash 不同。Desktop index 也为 25 个不同 hash。相册维度为
`[4, 12, 14]`，ledger 对应为 `[0, 12, 14]`；缺失的 4 项均位于持久
DiscoveryCursor 之前，当前无 backfill 请求，且 Flow scope revision 仍为初始值。

`MainActivity` 的范围保存只更新 `BackupScopeStore` / legacy watermarks；
`CompletionAndScope.requestScopeBackfill` 存在但没有该生产接线。此卡只修这个
新 Flow 范围扩展缺口，不把旧扫描机制带回生产路径。
