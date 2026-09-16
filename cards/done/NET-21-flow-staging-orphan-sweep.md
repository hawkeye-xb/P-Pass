# NET-21 flow-staging 装卸台无孤儿回收——磁盘单调泄漏　级别 L1

> ✅ 状态：已修复并通过 `just ci` · 协同分支：`main`
> 级别：L1 · 阻塞：无
> **背景**：2026-09-16 用户对话追问 NET-20 时发现的第二处 NET-06 重构漏项——
> 「为什么不能按整个 `.ppf` 目录巡检」的追问促成本次快速修复，非真机验收，
> 仅本地测试 + `just ci`。

## 验证脚本（用户可自行确认，不必等真机回归）

`tools/verify-flow-staging-gc.sh` 提供两种验证方式：

- **只读检查真实库**（默认）：`./tools/verify-flow-staging-gc.sh` ——
  报告 `~/Library/Application Support/P-Pass/.ppf/flow-staging` 现有
  文件数、大小，标出哪些已超过 1 小时宽限期理论上该被下一轮巡检收走。
  可加 `--library-root <path>` 指向别的库（比如
  `~/Pictures/P-Pass 家庭照片库`）。
- **隔离沙盒模拟全流程**：`./tools/verify-flow-staging-gc.sh --dry-run`——
  在 `/tmp` 下建一个临时目录，放 3 个文件（孤儿/有主/刚落地各一个），
  直接调用生产代码里的 `daemon::sweep_flow_staging_orphans`（不是重新
  写一遍判据去测），断言：孤儿被清、有主的和刚落地的都保留。全程不碰
  真实库或运行中的 daemon 进程，退出码 0 = 全部符合预期。

日常怀疑"是不是又开始泄漏了"时，先跑只读检查；怀疑"回收逻辑本身是不是
坏了"时跑 `--dry-run`（它验证的是生产函数本身，不是脚本自己糊的逻辑）。
本地已跑通两种模式，输出附在卡片实施记录。

## 问题

Flow 单通道（`flow_delivery.rs`）把 iroh-blobs 拉到的字节先 `export_to`
成普通文件落在 `.ppf/flow-staging/{node_hex}-{queue_sequence}-{content_hash_hex}`，
再喂给 `Ingestor::ingest`。这份复制品落盘那一刻起就跟 iroh 的周期 GC
（`.ppf/flow-blobs`，`open_with_periodic_gc`）无关——iroh 只认自己仓库里的
哈希，看不见门外这个中转文件。

只有"成功 ingest（含判重）"这一条路径会删它（`run_fetch_body` 的 `Ok(_)`
分支）。三种情况会留下孤儿，且此前没有任何定时任务扫描这个目录：

1. ingest 真失败（非 Duplicate 的实际错误）→ 直接 `return Err`，staging
   文件留在磁盘。
2. materialize 中途被 cancel（`require_active` 提前返回 `Err`）→ 部分
   导出的文件留在磁盘。
3. daemon 在这两步之间崩溃/被杀 → 文件原地留下。

旧上传管线在 MOB-32 已经修过同一类根因（有主的留，没主的收：
`sweep_orphans` + `reclaim_staging`，main.rs 每小时巡检一次），但 NET-06
重构 Flow 单通道时只复用了"落盘中转"这个设计，没有把"巡场人"接过来——
新装卸台 `.ppf/flow-staging` 从诞生起就没人扫，长期运行下磁盘占用单调
增长，没有自动回收路径。

## 修复

不是新架构，是给已有的通用回收模式接第二个点：

- `crates/daemon/src/inbox.rs` 新增 `sweep_flow_staging_orphans(staging_dir,
  protected: &HashSet<[u8; 32]>, grace)`——判据与 `sweep_orphans` 同构
  （命名不合契约的不碰、落地不足 `grace` 的不碰、`protected` 里的
  content_hash 不碰），复用 `flow_staged_file_hash_hex` 从文件名末段解析
  出 content_hash 再查保护集，纯函数单测覆盖（4 条新用例 + 1 条反证：
  临时禁用保护判据后用例确实变红，证明测试真的锁住了这条防线）。
- `crates/daemon/src/main.rs`：启动时和每小时定时任务里各调一次，保护集
  直接复用 `Db::active_flow_content_hashes()`——与 flow-blobs 的 iroh GC
  回调（`flow_gc_protected`）读的是**同一张持久表**，不是另起一份判据。
  与旧路径不同：Flow 的保护集是持久表而非内存态会话，因此启动时也可以
  用真实保护集（不必像旧路径那样在启动时假设保护集为空）。
- 查询保护集失败时跳过本轮回收并记警告日志，宁可漏收不可误删。

## 验收标准

- [x] RED 先行：4 条纯函数单测（文件名解析、三道保护、宽限期、目录不
      存在）+ 1 条反证（临时把 `if protected_hex.contains(hash_hex)` 改成
      `if false`，`flow_staging_orphan_sweep_respects_every_guard` 从
      9 变成 16，证明反证成立；已恢复）。
- [x] `cargo test -p daemon --lib inbox::` 10/10 全绿（含既有 5 条 + 新增
      5 条）。
- [x] `cargo test -p daemon` 全量（flow_delivery/upload_flow/watch_flow 等）
      无回归。
- [x] `just ci`（fmt/clippy/nextest/架构隔离检查/queue-sync）全绿。
- [x] 版本 bump：`0.5.4-test.1` → `0.5.4-test.2`（workspace Cargo.toml、
      desktop tauri.conf.json、desktop package.json、desktop Cargo.toml、
      Android `build.gradle.kts` 回退版本号）。

## 范围

- 只动：`crates/daemon/src/inbox.rs`（新函数+测试）、
  `crates/daemon/src/lib.rs`（导出）、`crates/daemon/src/main.rs`（启动+
  定时接线）、版本号文件、卡片/队列文档。
- 未动：Android 侧代码、协议线格式、旧批量管线 `backup.rs`、`flow-blobs`
  的 iroh GC 配置本身。

## 阻塞与依赖

无前置，无下游。与 NET-20（offer 传输前哈希对齐）并行、互不阻塞，两者
都是 NET-06 重构核心管道时漏掉的独立业务逻辑缺口。

## 真机验收欠账

本卡只做了本地单测 + `just ci`，**未做真机长跑验证**（长期运行、失败率
非零场景下 `.ppf/flow-staging` 是否真的不再单调增长）。如需要，另开卡或
在下一轮真机回归清单里加一项：故意制造几次 materialize 失败/cancel，
确认 staging 目录在下一次巡检后清零。
