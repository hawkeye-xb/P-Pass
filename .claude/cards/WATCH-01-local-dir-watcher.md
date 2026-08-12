# WATCH-01 本地目录监听 + 增量同步（库目录事件驱动）　级别 L2【本 session 认领实现】

背景与裁决：2026-08-12 讨论定稿——无监听时 metadata 更新不及时（本地
新增只有 backup 协议入口、删除靠每小时 reconcile），用户实测踩坑。
策略：notify 监听 `originals/` 树 + 防抖 + 父路径合并 + 增量扫描，
复用现有 ingest/reconcile/Throttle，事件链路（SYNC-02/03/04）已通，
本卡补「本地文件变化 → 触发 ingest/清理」这第一跳。

## 目标

库目录（`data_dir/originals`）文件变化在秒级反映到索引：
- 新增文件 → ingest（复用 `Ingestor`，src_device = 本机 node_id，审计如实记本地导入）
- 删除文件 → 局部对账清理（复用 `Reconcile::remove_asset`）
- 变化 → `timeline.invalidated`（走 `events::Throttle`，批量合并）
- 每小时全量 reconcile 保留为兜底（监听丢事件时最终一致）

## 范围

- 新文件 `crates/daemon/src/watcher.rs`（`LibraryWatcher`）
- `crates/daemon/Cargo.toml`：加 `notify`
- `crates/daemon/src/reconcile.rs`：`remove_asset` 改 `pub(crate)`（watcher 局部清理复用，审计/thumb 清理逻辑不复制）
- `crates/storage/src/asset_repo.rs`：加 `list_asset_paths_under(prefix)`（局部对账用，SQL prefix 过滤）
- `crates/daemon/src/main.rs`：挂载 watcher（失败降级为每小时对账，不阻塞 daemon 启动）
- 测试：`tests/watch_flow.rs` 集成测试 + watcher 单测

## 不准动

- `events.rs` 节流合并逻辑（SYNC-02，本卡只是消费者）
- `ingest.rs` / `reconcile.rs` 的既有语义（T-011 先落文件后插行顺序改不得）
- `subscriptions.rs` / router / Android 端任何代码
- blob 删除边界（reconcile.rs 模块注释的已知边界，孤儿 blob 惰性无害）

## 设计要点（事件风暴策略）

1. **监听根 = `data_dir/originals`**：`.ppf/`（staging/thumbs/blobs/索引）在
   树外，天然排除——不需要过滤自产目录。
2. **事件桥接**：notify 回调（std 线程）→ `std::sync::mpsc` → tokio mpsc
   （`blocking_send`）→ 防抖器 tokio 任务。
3. **防抖窗口 500ms**（const，可调）：Reset 风格——新事件重置计时器；
   窗口到点只处理一次。批量拖入 1000 张只触发一次扫描。
4. **父路径合并**：收集变化路径 → 取其父目录集合 → 排序后只保留非
   其他路径子目录的顶层（旧版 `filterParentPaths` 逻辑，纯函数单测）。
5. **增量扫描**：对合并后的目录递归 walk，收集文件 → 过滤（隐藏文件
   + 媒体扩展名白名单 jpg/jpeg/png/heic/heif/gif/webp/bmp/mp4/mov/
   m4v/avi/mkv/3gp/raw 系）→ `dedup::hash_file` → 查索引 → 未索引则
   `ingestor.ingest(IncomingFile)`。ingest 并发限制（Semaphore(4)）。
6. **删除方向**：对变化目录 `list_asset_paths_under(prefix)` → 磁盘缺失
   → `remove_asset`（局部 reconcile，不逐事件删——ingest 移动文件产生
   的瞬态 remove 由防抖窗口吸收，窗口后状态已稳定，索引与磁盘一致）。
7. **幂等**：hash dedup（ingest 自产事件扫描到已索引文件 = Duplicate
   跳过）；T-011 顺序保证对账不误判刚落盘文件。
8. **事件输出**：每 ingest 一个 New / 每清理一条 → `Throttle::signal()`，
   批次收尾 `flush_now()`（backup.commit 同款模式）。
9. **失败隔离**：单文件 ingest 失败记 warn 不中断整批；watcher 整体
   启动失败降级为每小时 reconcile（现有兜底不变）。

## 可执行验收

- 集成测试（真实 notify + 临时目录，轮询断言 + 超时容忍事件延迟）：
  1. 往 originals 写入媒体文件 → 数秒内 asset 行出现（ingest 成功）
  2. 删除该文件 → 数秒内 asset 行消失 + 收到 `timeline.invalidated`
  3. 往 originals 写入非媒体/隐藏文件（.DS_Store）→ 不 ingest
- 单测：父路径合并（含嵌套/排序）、扩展名白名单、隐藏过滤
- 既有测试全绿：`cargo test -p daemon -p proto -p core-index` +
  `just arch-check`（watcher 不引入 iroh 类型，B.1 不破）

## 证据要求

测试输出摘要 + arch-check 输出 + PROGRESS.md 一行 + NEXT.md 队列状态
+ ROADMAP.md 状态行。

## 收尾

全绿后本卡移入 `done/`。真机/真实库验证挂用户（可选）。
