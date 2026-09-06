# UI-09 聚合状态条/三元组仍读 LEGACY ConfirmedStore，换内核后 UI 全挂（L2）

> 🟠 状态：进行中 · 当前节点：已认领，RED 用例先行（传完 N 项 → K 必须归零）；下一步：账本派生投影 + 换源 + 补 completedAt · 协同分支：`main`
> 级别：L2 · 阻塞：无

## 问题

2026-09-06 验收人真机狗粮（v0.5.0-test.4，含 REBUILD-00~06 全部代码）实证：
照片实际传输成功，但 App 首页**全程没有任何状态变化**——传输中不显示、
暂停/取消按钮没有出现的窗口、传完后「待备份 K」与上次成功时间纹丝不动。
验收人因此无法执行 §六 的验收（UX-13/UX-14/MOB-13 的验收前提不成立）。

根因（源码核实，非推测）：

1. 六态投影（`FlowUiProjection.kt`）本身已迁移到账本，但**聚合展示层**——
   状态条的 K、三元组 M、上次成功时间——读的是 `ConfirmedStore`
   （`BackupUiStateHolder.computeTripletSafe`）。`ConfirmedStore.recordRun`
   的唯一生产调用方是 LEGACY `BackupRunner`（REBUILD-00 已冻结）；新 Flow
   内核零写入。于是新内核传得越多，K 纹丝不动。
2. `REBUILD-03` 注释自述「R3 deliberately does not change
   reconciliation/triplet UI」——迁移时**故意**没接上，且从未开卡挂账。
3. 新六态里没有「本轮全部传完」的呈现：传完后账本全 `CONFIRMED` → 投影
   `Idle` → 文案落回 `Pending(K)`，而 K 来自坏数据源（第 1 条）→ 表现即
   「传完和没传完全一样」。旧管线的 `AllSafe` 态在新路径下不可达。
4. `TransferItem` 无完成时间字段（`completedAt`），「上次成功时间」在账本
   里没有事实源，需补 schema（序列化已开 `encodeDefaults` +
   `ignoreUnknownKeys`，加带默认值的可选字段可平滑兼容旧账本文件）。

## 期望行为

- 首页状态条、三元组 K/M、上次成功时间、本轮跑完提示，全部从
  `discovery-ledger.json`（当前 pairing epoch 内）派生，UI 不再读
  `ConfirmedStore` 的备份聚合。
- 传输中投影出 `Transferring` → 英雄区给「暂停」；暂停 → 「继续」+可「取消」；
  传完 → K 归零、出现「照片都存好了」类 AllSafe 文案 + 上次成功时间。
- 派生是纯函数：同一快照永远算出同一组数字（可 JVM 直测）。

## 验收标准

- [ ] RED→GREEN：账本集成用例——发现 20 项 → 逐项 receipt 至全 `CONFIRMED`，
      断言派生 K 从 20 单调降到 0、M=20、lastSuccessAt>0、投影出 AllSafe；
      本卡开工前该用例必须是红的（复现验收人观察）。
- [ ] `TransferItem` 新增 `completedAt: Long = 0`，仅在 receipt 确认时写入；
      旧账本 JSON（无该字段）加载不报错、值为 0（有反序列化用例）。
- [ ] `BackupUiStateHolder` 的 triplet/K/lastSuccess 全部换源到账本派生；
      全仓 `git grep ConfirmedStore` 在首页聚合路径零命中（照片页归属过滤
      属 UI-10，不在本卡）。
- [ ] 反证：把派生函数指回旧 ConfirmedStore 的变体，20 项用例必须变红。
- [ ] Android JVM 全量绿（报数必须给测试计数）+ debug APK + `just ci`。
- [ ] 真机（验收人）：隔离测试相册一批照片从配对后到传完，首页依次出现过
      「备份中」→（手动）暂停/继续可用→传完 K 归零 + 成功文案。

## 范围

- 只准动：`backup/flow/DiscoveryLedger.kt`（加字段）、`backup/flow/CompletionAndScope.kt`
  （确认时写 completedAt）、`backup/flow/FlowUiProjection.kt`（派生纯函数）、
  `backup/BackupUiStateHolder.kt`、`ui/BackupStatus.kt`（AllSafe 语义接新态）、
  对应 JVM 测试、卡片/队列/进度文档。
- 不准动：账本提交协议与严格消费者语义；LEGACY 管线（只冻结不删除）；
  reconciliation 行为本身；照片页归属过滤与重传提示（→ UI-10）；桌面端。

## 阻塞与依赖

无前置。下游：UX-13、UX-14、MOB-13 的真机验收前提由本卡恢复；UI-10 与本卡
同文件（`BackupUiStateHolder`），须待本卡合并后开工。

---

## 实施记录

- 2026-09-06：开卡即认领（验收人口头授权「按流程一步步走」）。开卡前源码
  证据：`ConfirmedStore.recordRun` 生产调用方仅 `BackupRunner`（LEGACY 头
  注释 REBUILD-00 冻结）；`Holder._reuploadNoticeCount` 无任何生产写入方
  （恒 0，死 UI——移交 UI-10 处置）；`MainActivity.kt` 仅读 SentinelStore，
  主源码内未找到写入方（→ UI-10 核实）。

## 备注

- 验收人观察「暂停/取消没有展示机会」有两种解释：单头逐项传输时
  Transferring 窗口短、500ms 轮询可能错过（正常），或 runtime 空快照使 UI
  失明（缺陷，见 UI-10）。本卡修好后若仍无暂停窗口，按 UI-10 的可见性项追查。
