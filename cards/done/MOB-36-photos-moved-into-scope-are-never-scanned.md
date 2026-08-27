# MOB-36 移进备份范围的照片永远不会被扫到——水位挡住了它　级别 L1

> ✅ 状态：代码已合并（commit 55f8c43），2026-08-27 真机验收通过，验收人认定归档
> 级别：L1 · 阻塞：无

## 问题

验收人反馈（2026-08-26 真机）：**「必须拍照才行？我通过相册移动，它后台没触发？」**

增量扫描按**水位**过滤（`_ID` / `date_added`）。而在相册之间**移动**一张照片
**既不改 `_ID` 也不改 `date_added`**——变的只是 `bucket_id` /
`RELATIVE_PATH`。于是一张从未选相册**移进**已选相册的老照片：

- MediaStore 确实发了内容变化通知 → 看门 job 被叫起来 → 派活正常
- 但派出去的那趟扫描按水位过滤，这张照片的 `_ID` 远在水位之下 → **不进候选**
- 结果：**触发了，但什么也没传**，用户看起来就是「移动不触发」

这跟 `MOB-34` 是**同一族根因**：水位只认「新拍的」，认不出「变成范围内的」。
MOB-34 修的是「被删了要传回来」，本卡修的是「被移进来要传上去」。

## 期望行为

把一张老照片移进已选相册 → 它被备份。不管它多老。

## 验收标准

- [x] 集成（android）：一条 `_ID` 在水位之下、`bucket_id` 属于已选相册、
      且 hash 不在 `confirmed` 里的记录 → **进本轮候选**
- [x] 反证：去掉这条补偿 → 上一条变红（当前实现就是红的）
- [x] 集成：**不许退化成每轮全量重扫**（与 `MOB-34` 卡面第 3 条同一条约束）。
      判据：一轮里定向查询的条数有上界，且不随库大小线性增长
- [x] 集成：已经备份过的照片被移动 → **不重复上传**（hash 已在 `confirmed`
      → 不该进候选；即使进了，存储端也只会 duplicate，但这里要在客户端就挡住，
      否则每次移动都白跑一趟传输）
- [x] 集成：移出已选相册 → **不触发任何上传**（范围外的不是我们的事）
- [ ] 真机：把一张 1 月的老照片移进已选相册 → 不手动干预 → 它被备份

## 范围

- 只准动：`apps/android/.../backup/`（扫描与候选构建）及其测试
- 不准动：水位推进规则本身（`MOB-09` 的坏记录跳过语义不许回退）；
  `manifest` / `missing` 的存储端语义

## 阻塞与依赖

无。**与 `MOB-34` 的定向补偿是同一套机制**，实施时优先复用
（`ReuploadQueue` / `MediaScanner.itemsByKeys` / `planReuploads`），别造第二套。

---

## 实施建议

两条路，实施时权衡后择一并写清理由：

- **A. 按 bucket 定向查**：扫描时除了「水位之上的全部」，再查一次「已选
  bucket 里、`_ID` 在水位之下、且不在 `confirmed` 里的」。代价是每轮多一次
  带 `bucket_id IN (…)` 的查询，返回集要靠 `confirmed` 过滤掉绝大多数。
  ⚠️ 这个查询的结果集大小 ≈ 已选相册总张数，**不能每轮全量哈希**——只对
  「hash 未知」的那些做，靠 PERF-01 的哈希缓存把成本压住。
- **B. 记录 bucket 归属的快照**：上一轮记下每个 `_ID` 的 `bucket_id`，这轮
  比对出「换过 bucket 的」。代价是要多存一张表，但每轮的比对是 O(变化量)。

A 简单但每轮有一次范围查询；B 精确但多一份状态。倾向 A（复用已有的
`confirmed` 与哈希缓存，不新增落盘状态），但要把「结果集上界」这条钉进测试。

---

## 实施记录（2026-08-26，commit 55f8c43）

### 方案：选 A（按 bucket 定向查），并把「靠两张现成的表把成本压成零」做实

每轮在增量扫描之外，再查一次「**已选 bucket 里、水位之下**」的行（元数据 only，
**一个 collection 一次查询**），返回集 ≈ 已选相册总张数——所以**一行都不许直接
哈希**。每一行先问两张已经在盘上的表要「已知 hash」：

1. `ConfirmedState.files`（`MOB-13` 的文件级确认记录，fileKey → hash）；
2. `HashCache`（`PERF-01` 的哈希缓存，`uri → hash`，跨版本跨配对存活）。

已知 hash 且仍在 `confirmed` 里 → **跳过，不开流不哈希**（验收④）。剩下两类才进
候选：hash **未知**的（= 从没在范围内被哈希过，正是刚被移进来的那些），以及
hash 已知但不在 `confirmed` 的（还没传成功 / 被校准剔除过）。

**为什么不选 B（记 bucket 归属快照）**：B 也**必须**每轮发同一条范围查询才能比
出「换过 bucket 的」，查询成本一模一样，却额外多一张要落盘、要清理、要跟
confirmed/hash-cache 三方对齐的状态表。A 的「快照」是免费的——`files` 与
`hash-cache` 本身就是按 fileKey 索引的，「这个文件我们处理过没有」直接问它们。
**少一份状态，同样的成本上界。**

**为什么不搭 `MOB-34` 的 `ReuploadQueue`**：队列存在的理由是「lost hash 只在校准
那一刻知道，必须活到下一轮」。本卡的待补集合**每轮都能从 MediaStore 重新推导**，
持久化它是白存一份状态。复用的是 `MOB-34` 的**汇合点**（`plan.items` 那条唯一
列表）与它建起来的两张反查表，不复用它的落盘队列。

### 成本账（如实写，别只写「定向」两个字）

| 项 | 量级 | 说明 |
|---|---|---|
| 查询**次数** | 恒 2（images + video） | 不按条发查询；范围为 null 或水位为 0 时 **0 次** |
| 查询返回**行数** | O(已选相册张数)，元数据 only | 与 `countAll()`（每轮三元组分母）/ `allItemUris()`（每轮 hash-cache 清孤儿）**同量级、同频率**，这两条已经是每轮的既有开销 |
| 开流 + 哈希次数 | O(**变化量**)；稳态 **0** | 已确认的一律跳过 → 与库大小无关 |
| 上传量 | O(变化量) | 同上 |

所以卡面第 3 条的判据落成两条真测试：**查询次数恒定**（源码级，钉「一个
collection 一次查询」）+ **开流/哈希与上传成本在稳态为 0、有变化时 ∝ 变化量**
（10 张库与 10000 张库跑同一组断言，数字必须一模一样）。

### 改了什么（每处一句话理由）

- **新增 `backup/ScopeBackfill.kt`**——`planScopeBackfill`（纯函数：已确认的剔掉、
  本轮已有的不重复追加、`below` 内部重复 key 也只留一条，保住下游 `fileEntriesOf`
  的「1:1 同序」）+ `knownHashOfFile`（两张表的查询顺序：per-remote 权威口径优先，
  哈希缓存兜底存量条目 / 换过配对的机器）。
- **`MediaScanner.scanScopeBelow`**——补齐查询本身：`BUCKET_ID IN (已选) AND
  genCol <= ?`，**移出已选相册的行根本不在结果集里**（验收⑤ 由查询构造保证，不靠
  下游过滤）。**不返回 `nextWatermark`**——返回类型就钉死「补齐条目不参与水位推进」，
  `MOB-09` 的坏记录跳过语义一行未动。两条零成本早退：范围为 null（全量模式没有
  「范围边界」可跨，本卡的 bug 不存在）或空集、水位为 0（手动全量重扫 `since=0`
  已覆盖全部）→ 一次查询都不发。
- **`BackupWorker.doWork`**——`val items = plan.items + backfill` 走 `MOB-34` 建的
  同一条汇合点（候选构建 / 进度分母 / batchSize 因此**自动**全部用上，不需要第二处
  改动）。`HashCache` 的构造从哈希阶段提前到扫描阶段（补齐判定要用它，构造只是读一
  次盘）。补齐条目非空时打一行日志（`scope backfill: N in-scope item(s)…`），真机
  排查靠它区分「补齐生效」与「压根没查」。
- **新增 `ScopeBackfillTest`（12 条）**——覆盖验收①③④⑤ + 1:1 同序 + 接线顺序。
  既有测试一行未改（`--rerun-tasks` 全量：38 类 / 290 → 39 类 / 302）。

### 顺带治好的另一半（预期行为，不是回归）

「新勾选一个相册 → 里面的**存量**照片自动备份永远够不着」是同一个根因的另一面
（此前只有手动触发的全量重扫能覆盖）。本卡的补齐一并治好它。**代价**：勾选一个大
相册后的第一轮自动备份会一次 offer 整个存量（与手动全量重扫同量级）。看到「第一轮
传了几百张」不要当回归。

### 与 `MOB-09` 的取舍（明写，别让它埋着）

一条「在范围内、水位之下、hash 未知、**文件打不开**」的坏记录，此前被水位永久跳过，
现在每轮都会被查回来、在 `buildCandidates` 的探针上开流失败一次。代价 = 每轮每条
坏记录一次失败的 `open`，上界是坏记录条数；`buildCandidates` 的逐条隔离保证它挡不住
整批（`MOB-09` 的红线不破）。**刻意不加「打不开」的负缓存**——那正是选 A 而不是 B
要省掉的那份状态。

### 一个隐含前提被拆掉了（两种设备行为都对）

不论「移动相册」这个动作在某台设备上会不会 bump `GENERATION_MODIFIED`：会 bump →
增量扫描直接扫到，补齐这一路把它去重掉；不 bump（验收人这台的实测行为）→ 补齐这一路
接住，且哈希缓存 key 未变、必然命中，不重新读流。**没有任何设备特定行为是承重的。**

### 测试

`export JAVA_HOME=/opt/homebrew/opt/openjdk && export ANDROID_HOME=…/Android/sdk`
后 `./gradlew :app:testDebugUnitTest :app:assembleDebug --rerun-tasks`
（计数从 `app/build/test-results/testDebugUnitTest/*.xml` 数，XML 时间戳
2026-08-26 11:11:51 = 本次生成）：

```
测试类 39  测试数 302  failures 0  errors 0  skipped 4
BUILD SUCCESSFUL
```

基线（改动前，同一条命令）38 类 / 290 tests / 0 failures —— 新增 12 条全部来自
`ScopeBackfillTest`，既有测试一条未改、一条未破。

**rebase 后复跑**（`MOB-33`(`59ecab3`) 与 `MOB-37`(`94574b1`) 也动了 `BackupWorker`，
合流后必须再验一次）：`42 类 / 322 tests / 0 failures`（XML 2026-08-26 11:19:37）+
`assembleDebug` 绿。多出来的 3 类 / 20 条来自那两张卡，不是本卡的。

### 反证（四条，全部真跑，之后全部还原）

1. `doWork` 里 `val items = plan.items + backfill` 退回 `val items = plan.items`
   （补齐算出来了却不喂进管线——正是本卡修的那个断点）：

```
ScopeBackfillTest > the_backfill_is_merged_into_this_rounds_list FAILED
ScopeBackfillTest > the_backfill_lands_before_the_pipeline_reads_the_list FAILED
34 tests completed, 2 failed
```

2. `planScopeBackfill` 首行改成 `if (true) return emptyList()`（不补齐 = 当前
   线上行为）：

```
ScopeBackfillTest > the_output_is_proportional_to_the_change_not_to_the_library FAILED
ScopeBackfillTest > duplicate_rows_inside_the_query_result_are_collapsed FAILED
ScopeBackfillTest > a_photo_moved_into_a_selected_album_enters_this_round FAILED
ScopeBackfillTest > a_hash_that_calibration_pruned_comes_back FAILED
12 tests completed, 4 failed
```

3. 去掉「已确认的跳过」这一条（`below` 全部返回 = 每轮把已选相册全量重传一遍）：

```
ScopeBackfillTest > a_photo_already_backed_up_is_not_uploaded_again_when_it_moves FAILED
    java.lang.AssertionError: 已确认的照片被移动不许重新上传
ScopeBackfillTest > the_output_is_proportional_to_the_change_not_to_the_library FAILED
ScopeBackfillTest > a_quiet_round_costs_nothing_no_matter_how_big_the_library_is FAILED
12 tests completed, 3 failed
```

4. 补齐查询的 WHERE 去掉 `BUCKET_ID IN (…)`（= 范围外的行也会被捞回来，验收⑤ 破）：

```
ScopeBackfillTest > moving_a_photo_out_of_scope_can_never_trigger_an_upload FAILED
12 tests completed, 1 failed
```

### 还差什么

- **真机验收（验收标准最后一条）**：把一张 1 月的老照片移进已选相册 → 不手动干预
  → 它被备份。实施 agent 不碰验收人的照片库、不对测试机做 adb 写操作，这条留验收人。
  排查抓手：`adb logcat -s PPassBackup` 里那行 `scope backfill: N in-scope item(s)…`
  ——有它 = 补齐找到了活干；没有它而照片也没传 = 查范围（是不是真的勾了那个相册）
  与水位（`since=0` 的轮次补齐不发查询，因为增量扫描已覆盖全部）。

## 验收记录（2026-08-27）

验收人真机验收通过（批量清理 QUEUE 待验收区），归档。
