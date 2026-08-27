# MOB-13 「待备份 K」永远归不了零——M 按 hash 计数、N 按文件计数　级别 L1

> 🟡 状态：代码已合并，等真机验收
> 级别：L1 · 阻塞：无（真机复验需先手动按一次备份补齐文件级记录，见下）

## 问题

**用户报告**（2026-08-19）："设置里面显示有多少张没同步，但是我全部
相册都选择了啊。"

三元组 `K = N - M`（`ConfirmedStore.kt`）两个数的口径不一致：

```kotlin
// N：MediaStore 的文件 COUNT（扫描范围全量）
// M：
val confirmed: Set<String> = emptySet()    // ← 内容 hash 的 Set
fun count(): Int = load().confirmed.size   // ← M = 唯一 hash 数
val k: Long get() = (n - m).coerceAtLeast(0)
```

只要用户相册里有**内容重复**的照片（同一张图存两份、微信保存过又收到
一次、相机的 `xxx(0).jpg`），hash 集合只记一条、文件数记两条，K 就恒
大于 0——**哪怕每一张都已经成功备份**。用户看到的是"永远有 N 张没
同步"，且怎么等都不消失。

**现场佐证**：用户手机 116 个媒体文件（113 图 + 3 视频），电脑端 118 个
文件，逐文件名比对后手机独有的只有一个测试图（内容与前一张重复、被 hash
去重）。即**实际备份完整无缺**，但 UI 仍显示有未同步项。用户电脑端存在
`20260818_134226.jpg` / `20260818_134226(0).jpg` 这类重复内容文件。

## 期望行为

全部相册都选中、全部照片都备份成功时，设置页「待备份 K」必须是 0，不被
内容重复的照片虚增。

## 验收标准

- [x] 单测：构造 N=5（其中 2 张内容相同）、全部备份成功的场景 → 期望
  K == 0（`duplicate_content_all_backed_up_gives_k_zero`，2026-08-19 绿）
- [x] **反证**：退回 `k = n - confirmed.size` → 该测试必红
  （2026-08-19 实测 5 个测试红，真实输出见实施记录）
- [ ] 真机（前置：升级后先按一次「备份」补齐文件级记录）：在相册里复制
  一张已备份的照片（产生内容重复），等备份跑完 → 设置页「待备份」必须是 0
  （前后截图）

## 范围

- 只准动：`ConfirmedStore.kt`、两条备份链路的 `recordRun` 调用处
  （`BackupUiStateHolder.kt` / `BackupWorker.kt`）及对应单测。（实施时
  实动文件见实施记录表。）
- 不准动：`confirmed`（hash 集）语义本身——去重预过滤、漂移校准
  exist-check、照片页归属过滤本来就该按内容 hash 走，它们没错，错的只是
  "拿它当 M"。

## 阻塞与依赖

- 真机复验的前置：升级后先按一次「备份」（补齐文件级记录），再做卡面的
  "复制一张已备份的照片 → 等备份跑完 → K 必须 0"。在补齐之前，自动备份
  带进来的重复文件仍可能让 K > 0（存量 hash 的旧文件没有记录）——这是
  迁移窗口，不是修复失败。
- 与 MOB-09（同一工作区并行）有接口依赖，已在实施记录内对齐。

---

## 实施记录（2026-08-19）

### 选的方向：候选 1（`ConfirmedState` 增记文件级标识），理由

修复方向候选（卡面原文，实施时定，不直接抄）：

1. **`ConfirmedState` 增记文件级标识**（MediaStore `_id` 或 uri →
   hash 的映射），M 改成已确认**文件**数。改动中等，语义最正确；
   `bucketOf` 已经是 `hash → bucketId` 的映射，可以顺同一条路扩展。
   注意存量 `confirmed.json` 的迁移/兼容（旧数据没有文件级信息，
   参考 `bucketOf` 的"存量旧条目视为范围内"口径处理）。
2. K 改用"扫描出来但未成功传的文件数"直接计算，不再走 N - M 的估算。
   需要确认这个数在没跑扫描时也能给出（UI 是常驻显示）。

**不要**用"把 N 也去重"的方案——那需要对全库做 hash，代价不可接受。

选定候选 1 的理由：

- **本质是单位不一致，不是数值不一致**。N 数的是 MediaStore 的**文件行**，
  M 数的是**内容 hash**。候选 2（K 改用"扫描出来但没成功传的文件数"）换的
  是算法，没换单位来源——那个数只有跑过扫描才有，而三元组是常驻显示
  （`BackupUiStateHolder.init` 就要算、断网/从未备份也要算），常驻 UI 不能
  挂在一次扫描上。候选 1 把"已备份 M"变成一张**能被随时读出来的文件级
  账**，N 那边一行 `MediaStore COUNT` 不动，两边同为"文件数"，K 才是可减的。
- **顺着既有那条路**：`bucketOf` 已经是"确认条目的旁挂属性表"，加
  `files: Map<fileKey, ConfirmedFile(hash, bucketId)>` 是同一模式的第二张表，
  `@Serializable` 默认值 + 既有 `ignoreUnknownKeys` 让新旧 `confirmed.json`
  双向兼容（旧版读新文件忽略未知字段，新版读旧文件走默认空表）。
- **`confirmed`（hash 集）一条不动**：去重预过滤（`contains`）、漂移校准
  exist-check（`removeMissing`）、照片页归属过滤（`confirmedHashesUnder`）
  本来就该按内容 hash 走，它们没错，错的只是"拿它当 M"。
- 明确**没有**用被禁的"把 N 也去重"方案——全库 hash 的代价不可接受。

fileKey 口径 = `MediaItem.uri.toString()`（`content://media/.../<_ID>`），
与 PERF-01 哈希缓存的 key 同源，自动/手动两条链路一致，同一文件不会各记一条。

### 迁移与口径（存量 `confirmed.json` 没有 `files` 表）

参照 `bucketOf` 的"存量旧条目视为范围内"口径，`countInScope` 的计数规则：

```
M = 【有文件级记录且 hash 仍在 confirmed 的文件数（按范围过滤）】
  + 【一条文件级记录都没有的存量 hash 数（按 bucketOf 过滤）】
```

- 升级后立刻：`files` 空 → 整条退化成老口径，M 不会突然掉下去；
- 覆盖判定跨**全部**范围统计：某 hash 的文件全在范围外时，它已"有文件级
  记录"，不再按存量条目补记一条（否则缩范围后 M 又虚高）；
- **补齐时机 = 一次手动备份**：`runBackup` 是 `scanSince(0)` 全量扫描，一次
  就把范围内所有文件写进 `files`。**并且补在"全已确认"的早退分支上**——
  存量用户（每张都已备份）按下备份会走到 `fresh.isEmpty()` 早退，原来那条
  路径不写缓存，不补的话这类用户按几次都修不好 K。补完立刻
  `refreshTriplet()`，数字当场更新，不用等下次开 App。

⚠️ **真机验收的前置**：升级后先按一次「备份」（补齐文件级记录），再做卡面
的"复制一张已备份的照片 → 等备份跑完 → K 必须 0"。在补齐之前，自动备份
带进来的重复文件仍可能让 K > 0（存量 hash 的旧文件没有记录）——这是迁移窗口，
不是修复失败。

### 顺带修正（已在 diff 里，非静默）

`removeMissing` 原实现重建 `ConfirmedState` 时**没带 `bucketOf`**，一次漂移
校准就把所有相册归属抹平（残留条目全部退化成"视为范围内"，缩过范围的 M
虚高）。本卡顺手保留，并加断言钉住（`drift_removes_file_records_of_missing_hashes`）。

### 改了什么

| 文件 | 改动 |
|---|---|
| `apps/android/.../backup/ConfirmedStore.kt` | `ConfirmedFile` + `ConfirmedState.files`；`fileEntriesOf()`；`countInScope` 改文件口径（含存量回退）；`count()` 委托 `countInScope(null)`；`recordRun(files=)`；`removeMissing` 连带清 `files` / 保留 `bucketOf` |
| `apps/android/.../backup/BackupUiStateHolder.kt` | 手动备份两处 `recordRun` 带 `files=`（正常提交 + 全已确认早退补齐 + `refreshTriplet()`） |
| `apps/android/.../backup/BackupWorker.kt` | **只动 `recordRun` 调用处**：带 `files=`（列表源与 MOB-09 的 `built.kept` 对齐，见下） |
| `apps/android/.../test/.../ConfirmedStoreTest.kt` | +7 个测试（13 → 20） |

与 **MOB-09**（兄弟卡，同一工作区并行）的接口：`fileEntriesOf` 靠"文件列表
与候选列表 1:1 同序"配对，MOB-09 的逐条隔离会跳过坏记录、破坏
`scan.items == candidates`。MOB-09 侧已提供 `CandidateBuild.kept`（产出候选
的那些原始条目，与候选严格 1:1），worker 喂 `built.kept`。长度对不上时
`fileEntriesOf` **整体降级为空 map**（退回老口径，绝不错位写出假的
文件↔hash 对应），`file_entries_size_mismatch_degrades_to_empty` 钉住。

### 验收证据

基线（改动前，`--rerun-tasks` 全量）：`tests 193 failures 0 skipped 4`。
※ 卡面/派单说的 187 与实测 193 的差额是同工作区兄弟卡未提交的测试，本卡不认领。

改动后全量：

```
$ ./gradlew :app:testDebugUnitTest --rerun-tasks
BUILD SUCCESSFUL
FULL SUITE: tests 206 failures 0 errors 0 skipped 4
ConfirmedStoreTest: 20 tests / 0 failures
```

（206 = 193 基线 + 本卡 7 + 兄弟卡并行落地的 6；本卡只认领 ConfirmedStoreTest
的 13 → 20。）

卡面验收①的测试 `duplicate_content_all_backed_up_gives_k_zero`：5 个文件、
其中 2 个内容相同、全部备份成功 → `confirmed.size == 4`（hash 去重）、
`M == 5`（文件口径）、`K == 0`。

### 反证（真实输出，不是"应该会红"）

把 `count()` / `countInScope` **精确退回**改动前的实现（`M = confirmed.size`，
即 `k = n - confirmed.size`），其余一律不动：

```
$ ./gradlew :app:testDebugUnitTest --rerun-tasks --tests "com.hawkeyexb.ppass.backup.ConfirmedStoreTest"
> Task :app:testDebugUnitTest FAILED
20 tests completed, 5 failed

[FAILED] duplicate_content_all_backed_up_gives_k_zero
    java.lang.AssertionError: M 必须按文件数 = 5 expected:<5> but was:<4>
[FAILED] duplicate_content_with_one_unsynced_file_still_reports_k_one
    java.lang.AssertionError: 已确认文件 4 个 expected:<4> but was:<3>
[FAILED] legacy_hash_entries_without_file_records_still_count
    java.lang.AssertionError: 4 个已记录文件 + 7 个仍无文件记录的存量 hash expected:<11> but was:<10>
[FAILED] out_of_scope_file_records_do_not_fall_back_to_legacy_counting
    java.lang.AssertionError: 全量 = 3 个文件 expected:<3> but was:<2>
[FAILED] drift_removes_file_records_of_missing_hashes
    java.lang.AssertionError: expected:<3> but was:<2>
```

卡面验收①的测试报 `M expected:<5> but was:<4>` → K = 5 − 4 = 1，正是用户
"永远有 N 张没同步"的现象。**FIX-T6 的既有范围测试在反证下全部保持绿**
（`count_in_scope_*` / `triplet_m_never_exceeds_n` / `k_is_never_negative`），
说明红是文件级计数这一处引起的，不是判据宽泛地把半个套件带红。
反证后已精确还原，上面的全绿是还原后重跑的结果。

### 源码级断言（`production_call_sites_record_file_level_entries`）

`codeOf()` **先剥注释行**再 `contains`（TriggerPolicyTest 同款）——直接
contains 会被"把那行代码注释掉"骗成假绿。钉三件事：两条生产链路都传
`files = fileEntriesOf(`、fileKey 取值口径 `.map { it.uri.toString() to it.bucketId }`
两端一致、`runBackup` 里必须有**两处** `confirmedStore.recordRun(`（正常提交
+ 全已确认早退补齐，少一处 = 存量用户永远修不好）。

## 未做（留给验收人）

- 真机复验（L3）：升级 → 按一次备份 → 复制一张已备份照片 → 等备份跑完 →
  设置页「待备份」= 0 的前后截图。
- `PROGRESS.md` / `NEXT.md` / 本卡移入 `done/`：按指令未提交、未推送，
  工作区留给验收人合并时一并落。

## 备注

原卡证据要求：单测输出 + 反证红 + 真机截图（复制重复照片前后的三元组数字）。
2026-08-20 复核：真机复验需前置——升级后先手动按一次备份补齐文件级记录，
再验「复制一张已备份照片 → 待备份归零」。
