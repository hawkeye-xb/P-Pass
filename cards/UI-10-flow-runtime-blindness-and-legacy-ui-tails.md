# UI-10 Flow runtime 空快照静默 + 旧数据源 UI 尾巴（重传提示/归属过滤/失联哨兵）（L3）

> ⬜ 状态：未开工 · 当前节点：等 UI-09 合并（同文件 `BackupUiStateHolder` 冲突面）；下一步：按卡内三项逐条换源或下线 · 协同分支：`main`
> 级别：L3 · 阻塞：UI-09

## 问题

聚合状态迁移（UI-09）之外，UI 上还挂着三处与旧内核/新账本脱节的尾巴，
均为 2026-09-06 源码盘点发现（真机表现待 UI-09 合并后复核）：

1. **runtime 空快照静默**：`AndroidFlowRuntime.runtimeFor()` 在配对缺失或
   `pairingEpoch` 为空时返回 null → `flowLedgerSnapshot()` 回退**空账本** →
   UI 恒显 Idle、暂停/继续/取消点击全部静默 no-op，用户看不到任何解释。
   升级安装或换 Desktop 后可能落入此态（传输 Worker 走独立唤醒路径不受影响，
   造成「后台在传、界面装死」的分裂观感）。
2. **重传提示死 UI**：`BackupUiStateHolder._reuploadNoticeCount` 没有任何
   生产写入方（`acknowledgeReuploadNotice()` 是空函数）——首页条件
   `reuploadNoticeCount > 0` 永假，提示卡永不出现；其旧数据源是已冻结的
   LEGACY `ReuploadQueue`。
3. **照片页「仅本机」过滤器读旧源**：`PhotosScreen` 用 `ConfirmedStore` 的
   hash 集合近似归属判断——新内核不写它，迁移后过滤器会把所有本机照片判成
   「家人的」。
4. **失联天数哨兵写入方缺失**：`MainActivity` 只读 `SentinelStore`，主源码
   未检索到写入方（可能在 daemon/Workers 侧或随 LEGACY 冻结失去更新）——
   需核实，若确实无人写则该字段显示的是停摆数据。

## 期望行为

1. runtime/配对不可用时，首页显示真实状态（「需要重新配对」+ 出路），
   操作按钮不再可点成哑巴；不许伪造 Idle。
2. 重传提示：改为从账本派生（当前 epoch 内 `NEEDS_DECISION` 计数），或直接
   下线该 UI 与死代码——二选一在实施时按验收人口径定，不留恒假分支。
3. 归属过滤换源到 Flow 账本 `CONFIRMED` 项的 `contentHash` 集合。
4. 哨兵项：定位写入方后修复或开卡拆分；找不到且无消费价值则连同 UI 一起下线。

## 验收标准

- [ ] 构造「配对存在但 epoch 为空」的存储状态 → 首页显示配对失效可见提示，
      JVM 用例锁死（反证：回退空快照的路径变红）。
- [ ] 重传提示：数据源换账本派生或彻底下线，两条路径之一有测试覆盖，
      代码中无恒假分支残留。
- [ ] 照片页过滤器在「只经新内核备份」的账本上判对归属（用例覆盖）。
- [ ] 哨兵：写入方结论写回本卡（文件+行号级证据），修复或另开卡。
- [ ] Android JVM 全量绿（报测试计数）+ debug APK + `just ci`。
- [ ] 真机：UI-09 验收流跑通后，本卡四项在真机无异常表现。

## 范围

- 只准动：`backup/flow/AndroidFlowRuntime.kt`（空快照语义）、
  `BackupUiStateHolder.kt`（notice 计数）、`ui/HomeScreen.kt`（提示卡与
  配对失效呈现）、`ui/PhotosScreen.kt`（过滤源）、`SentinelStore` 消费方、
  对应 JVM 测试、卡片/队列/进度文档。
- 不准动：账本协议、FlowRunner/StrictConsumer 语义、LEGACY 管线、桌面端。

## 阻塞与依赖

前置：UI-09（同文件 `BackupUiStateHolder`，避免并发冲突）。重传提示若改
账本派生，依赖 ARCH-07 的 `disposition` 字段（已在账本，无新代码）。

---

## 实施记录

（待填）

## 备注

- 本卡第 1 项同时是验收人 09-06「暂停/取消没有展示机会」的候选根因之一
  （若其设备当时处于 epoch 缺失态）；UI-09 合并后先复测再定性。
