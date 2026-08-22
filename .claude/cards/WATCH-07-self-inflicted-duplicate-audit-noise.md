# WATCH-07 每批备份后活动流被 N 条「重复」刷屏　级别 L2

> 🟡 状态：代码已合并（方案 2），等真机验收
> 级别：L2 · 阻塞：真机验收一条（见验收标准）

## 问题

每批备份跑完，活动流/审计表立刻被 N 条 `ingest.duplicate` 刷屏——条数与
本批照片数完全相等。真机实测（2026-08-21）一批 12 张的备份，审计表是这样：

```
13:59:42-43   12 × ingest.new        ← 备份管线正常入库
13:59:43      backup.finished  ingested=12 duplicates=0
13:59:43      12 × ingest.duplicate  ← ⚠️ 同样的 12 条路径，紧跟着又来一遍
```

14:07 那批 7 张也一样，7 条 `ingest.duplicate` 跟在后面。

初步指向：这些 duplicate 行的**审计 actor 是本机存储端 node id**——即文件
监听（watcher）在重新 ingest 备份管线自己 `place()` 进 `originals/…` 的文件。
（此判断仍需按验收标准第 1 条正式复现证明，见「根因分析」。）

## 期望行为

一批备份落地后，活动流里条目数 = 照片数，不是 2 倍；「什么都没变化」的
重复 ingest 不产生用户可见的噪音记录。

## 验收标准

- [x] 先证明这些 `ingest.duplicate` 行是谁写的：审计行 actor = 本机存储端
  node id（2026-08-21 真机已查实）；机制复现 = 新测试
  `watcher_recheck_of_the_recorded_file_is_not_an_audit_event`
  （watcher 视角对已落位文件再 ingest → Duplicate）
- [x] 集成：同一文件的复检**不写**审计行；不同路径的同内容文件**仍写**
  （`same_content_at_a_different_path_is_still_audited` + 既有
  `ingest_is_audited_to_device_granularity` 保持绿）
- [x] 反证：把 `is_recorded_file` 判定去掉 →
  `watcher_recheck...` 立刻红（`got ["ingest.duplicate", "ingest.new"]`），
  恢复后绿
- [ ] 真机：传一批照片，活动流里条目数 = 照片数，不是 2 倍

## 范围

- 只准动：`crates/core-index/src/ingest.rs`（Duplicate 分支）、
  `crates/core-index/tests/ingest.rs`（两个新测试）
- 不准动：watcher「事件 = 去看这个路径，磁盘才是真相」的铁律语义；
  竞态落败分支（insert 撞 unique 约束时写的那条 `ingest.duplicate`，
  语义是「两个并发 ingest 抢同一份内容」，不在本卡范围，未改）

## 阻塞与依赖

无（2026-08-22 用户拍板按方案 2 实施）。

---

## 实施记录（2026-08-22）

**方案 2 落地**：Duplicate 分支加 `is_recorded_file()` 判定——被 ingest 的
路径与索引记录路径相同（canonicalize 双侧比较，/var vs /private/var 陷阱
按 WATCH-03 处理）→ 是复检，不写审计，直接返回 `Duplicate`；不同路径 →
用户真实放了一份拷贝，审计照记。canonicalize 任一侧失败保守按「不同」
处理（宁可多记，不漏真实事件）。

**证据**：
- `cargo test -p core-index` 全绿（含 2 个新测试）
- 反证实跑：去掉判定 → 新测试红（审计里出现 `ingest.duplicate`）；
  恢复 → 绿
- 行为保留：`ingest_is_audited_to_device_granularity`（staging 不同路径
  重复）与 `same_content_at_a_different_path_is_still_audited` 双保险

**审计设计规矩（2026-08-22 与用户讨论后定稿，适用于以后所有卡）**：

1. 审计只记「**数据层面**发生的事」，不记「代码层面跑了什么」——后者归
   开发日志（logcat/UidtLogger），不进审计表
2. 每写一行前先问：这行被翻到的时候，能说出它对用户数据的意义吗？
   说不出就不写
3. 审计语义必须稳定为「发生过的事件」——**业务可能读审计表做决策**
   （现存实例：PRES-01 用 `last_audit_ts` 读 `device.connected` 做 10
   分钟去重）。把审计行当展示层素材随意增删，会静默弄坏这类功能
4. 「展示对、实际错」的防御不靠更详细的审计，靠**对账**：两个独立来源
   互相验证（手机说的 vs 库里真有的；staging 剩 0 字节 vs backup.finished）。
   审计只能记录它被告知的——MOB-32 就是审计写 `ingested=0` 而 186 张
   实际被丢的实例

历史已写入的同路径 `ingest.duplicate` 垃圾行不动（审计表只增不删，
用户 2026-08-22 确认不用考虑以前的测试数据）。

## 根因分析（原内容，已被实施证实）

**很可能**是 WATCH-01 的目录监听咬自己的尾巴：备份管线把文件 `place()` 进
`originals/…`，FSEvents 立刻报告「这个路径变了」，监听去 ingest 一遍，
内容已在索引 → `Duplicate` → 写一条 `ingest.duplicate` 审计。

⚠️ **这条只是最像的那个，必须先复现再改。** WATCH-02 那次列了三条「最可能」
的假设，三条全错，根因是一个斜杠。本卡第一步是**证明**这些 duplicate 行的
actor 是监听而不是备份管线（审计行有 actor 字段，先去看它）。

## 为什么要修（不只是"日志脏"）

- 活动流是**用户看的界面**（IPC-02 `activity.list` 直接喂桌面端）。传 200 张
  就是 200 条「重复」，把真正有信息量的条目全冲走了
- `asset.replaced_in_place` / `asset.removed_external` / `asset.relocated` /
  `ingest.duplicate` 这些原始机器串本来就已经在界面上露出来过（用户投诉过
  这一类文案），现在还要乘以 2

## 候选改法（没定，实施前拍板）

1. **监听侧抑制自触发**：备份管线 `place()` 之后把目标路径登记进一个短时效
   的「我自己刚写的」集合，监听命中就跳过。⚠️ 这是有状态的时间窗，
   WATCH-01 的模块注释明确写着「事件 = 去看这个路径，磁盘才是真相」——
   加抑制窗等于往这条铁律里塞例外，要非常小心
2. **审计侧不记无变化的 duplicate**：`ingest` 判定 Duplicate **且**记录的
   rel_path 就是这个路径（什么都没变）→ 不写审计行。这条改动面最小，
   语义也最诚实：「什么都没发生」不该产生一条记录
3. 活动流查询侧过滤掉 `ingest.duplicate`（治标，审计表还是脏的）

**倾向 2。** 但先复现、先证明 actor。
