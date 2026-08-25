# MOB-34 库里删掉的老照片永远不会被重传——水位把它们挡在扫描之外　级别 L1

> 🟡 状态：代码已合并（commit d592639），等真机验收
> 级别：L1 · 阻塞：无（`MOB-29` 的后续，方向已定）

## 问题

`MOB-29` 定的语义是「**重传是正确行为，不拦**」——用户在库里删了照片，存储端
照旧算它「缺」，手机照旧传回来，我们只负责把这件事告知用户。

存储端这一半是对的（`sync_flow.rs` 的反墓碑测试钉着：删掉的 hash 在下一轮
`manifest` 里仍在 `missing`）。**手机端这一半是断的。**

手机的增量扫描**按水位只看新照片**。删掉的如果是老照片，它远在水位之下，
永远不会被重新扫到 → 永远不进 `manifest` → 存储端一直报缺、手机压根不来问。

### 真机实测（2026-08-25，验收人 + 我）

用户在访达里删了 3 张，**全是 1 月的老照片**：

```
Screenshot_20260120_154425_<app>.jpg
Screenshot_20260120_154435_<app>.jpg
20260107_172658.jpg
```
（文件名已脱敏；关键事实是**拍摄日期在 1 月**，远在水位之下。）

删除后跑了 **11 轮备份**（`ingested=1/8/7/1/0/1/3/3/1…`），传的全是新照片。
那 3 张**一次都没回来**，磁盘上至今没有。

同一个 bug 的另一面：手机端「待备份 K」**永远归不了零**。校准把这 3 个 hash
从 `confirmed` 里剔除（`MOB-29` 的正常动作），K 变成 3，而它们永远不会被
重新 offer，于是界面永远显示「有未同步的照片」。验收人原话：「一直有待上传的，
就因为客户端本地删除了。但是核心和我们的设计不一致。」

## 期望行为

被删的照片**真的**被传回来，不管它多老；`K` 能回到 0。

## 验收标准

- [x] 集成（android）：`confirmed` 里有、`existCheck` 说缺、且该 hash 对应的
  本地文件**在水位之下** → 下一轮备份**仍然**把它作为候选 offer 出去
- [x] 反证：去掉这条补偿逻辑 → 上一条变红（当前实现就是红的）
- [x] 集成：补偿只针对「校准查出来缺的那些 hash」，**不退化成每轮全量重扫**
  （全量重扫在大库上是几分钟的活，不能变成常态）
- [x] 集成：`K` 在补偿完成后归零
- [ ] 真机：复现本卡那组数字——删 3 张老照片 → 不手动干预 → 它们回来，K=0

## 范围

- 只准动：`apps/android/.../backup/`（候选构建与校准的衔接）及其测试
- 不准动：`manifest` / `missing` 的存储端语义（那一半是对的）；水位本身的
  推进规则（`MOB-09` 的坏记录跳过语义不许回退）

## 阻塞与依赖

无。

---

## 实施建议

`ConfirmedStore` 里已经有**文件级**记录（`MOB-13` 为了让 K 与 N 同单位加的
`files` / `bucketOf`），所以从「缺失的 hash」反查「本地是哪个 MediaStore 条目」
是现成的——不需要全量重扫，按 hash 定向把那几条塞进候选即可。

⚠️ 注意别和 `MOB-09` 打架：如果那条本地记录已经是坏的（文件没了），定向补偿
要能跳过它而不是无限重试，否则又变成「一条坏记录卡死整批」。

## 备注

根因是 `MOB-29` 落地时的一个隐含假设：「存储端报缺 → 手机就会传」。实际链条中间
还夹着水位这一层。**卡面当时没写这一环，daemon 侧的反墓碑测试也只能证明存储端
的行为，证不到手机端会不会来问**——这是「两端各自绿、合起来断」的典型。

## 实施记录（2026-08-25，commit d592639）

### 改了什么（每处一句话理由）

- **新增 `backup/ReuploadQueue.kt`**——定向补偿的全部纯逻辑：`reuploadTargetsOf`
  （lost hash → fileKey 反查，吃 `MOB-13` 的文件级记录）、`ReuploadQueue`
  （落 `backup-state/<remoteId>/reupload-queue.json`，与 confirmed.json 同目录，
  断开配对时随 `clearConfirmedCacheForRemote` 的 `deleteRecursively` 一起清，
  不需要第二处清理逻辑）、`planReuploads`（合并 + 出队规则，纯函数）、
  `mediaIdsOf`（fileKey → `_ID`，只认「前缀 + `/` + 全数字」）。
- **`MediaScanner.itemsByKeys`**——按队列里那几个 `_ID` **定向**查回条目
  （`_ID IN (…)`，images/video 各查一次，队列为空时一次查询都不发）；重建的
  uri 必须与原 fileKey **字符串全等**才算配上，`_ID` 撞车或格式漂移时宁可当
  「查无此行」丢掉，也绝不把一张不相干的照片传上去。
- **`BackupWorker.doWork`**——扫描之后合并补偿条目，`plan.items` 取代
  `scan.items` 喂进管线（候选构建 / 进度 total / batchSize **全部**换掉，
  漏一处就断 `MOB-13` 的「文件列表与候选列表 1:1 同序」，`fileEntriesOf` 会
  整体降级成空 map、K 又归不了零）。`scan.nextWatermark` 不受影响——补偿条目
  在水位之下，不参与水位推进。
- **`BackupWorker.calibrateIfReachable` 的 `onLost`**——登记补偿目标（读的是
  `store.load()` 的**校准前**快照；`calibrateConfirmed` 的契约是先 `onLost`
  再 `removeMissing`）；`calibrateTail`（收尾补校准）顺带传队列。
- **`BackupUiStateHolder.calibrateFromDaemon`**——**第二条校准门**同样登记，
  且必须在 `removeMissing` 之前。这条路径原本只 `removeMissing` 不接队列，
  不改的话「App 打开时那次校准剔掉的 hash 永远回不来」，bug 换个门重现。
- **`BadMediaRecordTest`（既有测试）**：`MOB-09` 的接线断言从
  `buildCandidates(scan.items)` 改成 `buildCandidates(items)`——喂进去的列表
  改名了，钉的语义（走逐条隔离的 `buildCandidates`、不许退回裸 `.map` 建候选）
  一字未改。

### 出队三规则（别和 `MOB-09` 打架）

| 情况 | 处理 | 在哪 |
|---|---|---|
| MediaStore 查无此行（手机原图也删了 = `MOB-29` 说的正确姿势） | 立刻丢 | `planReuploads` 的 `drop` |
| 在当前备份范围外（用户缩过范围） | 立刻丢 | 同上 |
| 行还在、文件打不开（`MOB-09` 的坏记录） | 立刻丢，**在「整批读不了」早退之前** | `built.skipped` → `reuploads.remove` |
| 传成功 | 出队（`confirmed`/`files` 已写回） | `recordRun` **之后** |
| run 失败（网络瞬断） | **保留**，下一轮再试 | 抛错就走不到出队 |

### 测试

`export JAVA_HOME=/opt/homebrew/opt/openjdk && ./gradlew :app:testDebugUnitTest
:app:assembleDebug --rerun-tasks`（计数从
`app/build/test-results/testDebugUnitTest/*.xml` 数，时间戳
2026-08-25 18:12 = 本次生成）：

```
测试类 37  测试数 283  failures 0  errors 0  skipped 4
BUILD SUCCESSFUL
```

其中新增 `ReuploadCompensationTest` **20 个 / 0 失败**，覆盖验收①③④：
水位之下的老照片在增量扫描为空时仍进本轮候选；队列为空时一次查询都不发、
且回归锁住「补偿不许靠把 `since` 改成 0 实现」；补偿完成后 `K` 归零；
行没了 / 范围外 / 打不开三种情况出队而不是无限重试；两条校准门都在
`removeMissing` 之前登记。

### 反证（真跑，两条）

1. `planReuploads` 退回不合并（`ReuploadPlan(scanned, drop)`）：

```
ReuploadCompensationTest > K_returns_to_zero_after_the_compensation_lands FAILED
ReuploadCompensationTest > below_the_watermark_photo_comes_back_even_when_the_scan_is_empty FAILED
ReuploadCompensationTest > compensation_rides_along_with_the_new_photos FAILED
ReuploadCompensationTest > an_item_with_unknown_bucket_is_kept_in_scope FAILED
20 tests completed, 4 failed
```

2. `doWork` 里 `val items = plan.items` 退回 `val items = scan.items`
   （补偿算出来了却不喂进管线，正是本卡修的那个断点）：

```
ReuploadCompensationTest > doWork_feeds_the_merged_list_into_the_pipeline FAILED
    java.lang.AssertionError: 合并结果必须落成本轮列表
26 tests completed, 1 failed
```

两次反证之后都已还原，最后一次全量跑是还原后的绿。

### 还差什么

- **真机验收（验收标准最后一条）**：删 3 张老照片 → 不手动干预 → 它们回来、
  K=0。实施 agent 不碰验收人的照片库、不对测试机做 adb 写操作，这条留验收人。
- ⚠️ **已知边界**：定向补偿靠 `MOB-13` 的**文件级**记录反查。`MOB-13`（0.3.4）
  之前备份的存量条目只有 hash、没有 `files` 记录，反查不到 fileKey，补偿够
  不着——真机那 3 张若正好属于这类，回归会看不到效果。判别法：看该 remote 的
  `confirmed.json` 里有没有指向那些 hash 的 `files` 条目；没有的话先手动触发
  一次备份（事件⑥ = 全量重扫，会把文件级记录补齐）再验。**刻意不为此加自动
  全量重扫**（卡面第 3 条的硬约束）。
