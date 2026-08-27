# WATCH-02 手动删 originals 里的照片，索引与界面无反应　级别 L2

> 🟡 状态：代码已合并，等真机验收。
> 级别：L2 · 阻塞：无

## 问题

2026-08-20 用户在 Finder 里删掉 `~/P-Pass NAS/originals` 下的内容（手动删
照片 / 删整个日期目录），桌面端照片墙纹丝不动，索引行数也没减。

复现：在 Finder 中删除 `originals/` 下的文件或整棵子目录 → 观察桌面照片墙
与 `select count(*) from asset`。

## 期望行为

外部删除被 watcher 对账发现：索引行同步删除、照片墙/时间线在秒级内消失，
并发出失效事件。

## 验收标准

- [ ] 真机：Finder 删几张照片 → 桌面照片墙 5 秒内消失、`select count(*) from asset` 同步减少
- [ ] 真机：Finder 删掉整个日期目录 → 同上
- [x] `just ci` 全绿，Rust 301/301（合并时证据，见实施记录）
- [x] 反证 8/8 有效：每处修复改回去，对应测试变红（见实施记录，2026-08-20）

## 范围

- 只准动：`crates/storage/src/asset_repo.rs`、`crates/daemon/src/watcher.rs`
- 不准动：ingest 管线的入库语义、相邻 watcher 卡（WATCH-03/04）的改动面

## 阻塞与依赖

无。

---

## 根因分析（实测锁定，不是推测）

**SQL 前缀多了一个斜杠，`LIKE` 一行不中。**

`watcher.rs` 局部对账拼前缀：

```rust
let prefix = format!("originals/{}", rel.to_string_lossy());
```

`list_asset_paths_under` 再补一层：

```rust
let like = format!("{prefix}/%");   // 旧代码
```

整棵子树被删时，`affected_dirs` 会收敛到 `originals` **本身**（被删目录的
父目录还在，`filter_parent_paths` 保留最浅的那个），于是 `rel` 是**空串**：

```
prefix = "originals/"  →  LIKE 'originals//%'  →  命中 0 行
```

库里明明有 `originals/<device>/2026/08/*.jpg`。**查出 0 条 → 什么也不删 →
不 emit 事件 → 界面纹丝不动。**

当场探针输出（临时 eprintln，已移除）：

```
PROBE dir=".../originals" rel="" prefix="originals/"
PROBE   matched rows = 0        ← 库里有 2 行
```

删**单个文件**时 `rel` 非空（`<device>/2026/08`），前缀正常，所以
`watch_flow.rs` 一直是绿的 —— 测试形状和用户操作形状不一样。

## 被排除的假设（三条全错）

| 假设 | 结论 |
|---|---|
| macOS FSEvents 句柄在整树删除后失效 | ❌ 事件正常投递，探针能打印出来 |
| ingest 瞬态 remove 过滤吞掉真删除 | ❌ 与本 bug 无关 |
| daemon 没起 / 跑了旧二进制 / 目录不存在 | ❌ 当场都核过了 |

顺带发现的第二个缺陷（也修了）：`walk_media` 对已消失的目录返回
`Err(ENOENT)` → `process` 早退 → **删除方向的对账被一起跳过**。整树删除时
`read_dir` 必然 ENOENT，「不在了」是这条路径的正常结果，不是错误。

## 实施记录

改动：

- `crates/storage/src/asset_repo.rs`：`list_asset_paths_under` 先剥掉
  `prefix` 尾部斜杠，让「目录边界」语义对根目录同样成立。
- `crates/daemon/src/watcher.rs`：
  - `walk_media` 对 `NotFound` 返回 `Ok(())` 而非 `Err`；
  - `process` 里扫描失败降级为空文件列表，不再中断删除方向；
  - 存在性检查整批下放 `spawn_blocking`（性能：候选集是变化子树下的索引
    行，变化目录是 `originals` 本身时就是全库，每行一次 stat，5 万行约
    百毫秒级；逐行同步 stat 会钉住 async 运行时的工作线程）。

反证 8/8 有效（把每处修复改回去，对应测试必须变红）：

```
✅ M1  前缀不剥尾斜杠                  → storage 单测 FAILED
✅ M1b 同一处 → 整树删除失效（用户撞到的） → removing_the_whole_device_subtree FAILED
✅ M1c 同一处 → 废纸篓改名失效           → trashing_the_device_subtree FAILED
✅ M2  目录消失当错误抛出               → watcher::tests::scanning FAILED
✅ M5  对账不做存在性过滤               → ingest_self_events_are_idempotent FAILED
```

新增测试（三种删除形状全覆盖）：

- `removing_the_whole_device_subtree_is_reconciled` —— `rm -rf` 整棵子树
- `trashing_the_device_subtree_is_reconciled` —— Finder「删除」= 顶层目录
  rename 进 `~/.Trash`（同卷改名）
- `whole_subtree_removal_emits_invalidated` —— 索引减到位**之外**要发事件
- `paths_under_prefix_tolerates_a_trailing_slash` / `..._respects_directory_boundaries`
  —— `list_asset_paths_under` 此前**零测试覆盖**，双斜杠就是这么活下来的

`just ci` 全绿，Rust 301/301。

## 备注

此 bug 修好后直接暴露了 DESK-08（批量对账产生同毫秒多条审计，前端 key
撞键）——「修好一个 bug 会让下游的 bug 第一次有机会发生」。
