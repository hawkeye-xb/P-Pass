# WATCH-02 手动删 originals 里的照片，索引与界面无反应　级别 L2

**现场**：2026-08-20 用户在 Finder 里删掉 `~/P-Pass NAS/originals` 下的内容，
桌面端照片墙纹丝不动，索引也没减。

## 实测证据（当场取的，不是推测）

```
originals 里剩余文件            1（只有 .DS_Store，185 张全被删）
index.sqlite 里 asset 行数    186   ← 一条都没减
daemon 进程                   在跑（PID 53378，16:31:32 启动）
daemon 二进制                  与 target/release/daemon 哈希一致
                              （f14b2b7f… ——确认是含 BLOB-01 的新代码，
                               不是那个 8/14 的旧 sidecar）
```

所以三件事都排除了：**不是 daemon 没起、不是跑了旧二进制、不是环境问题。**

## 已排除的猜测

- **不是"启动时 originals 不存在导致挂载失败"**：`watcher.rs:116` 在
  `watch()` 之前先 `create_dir_all(&inner.originals)`，目录一定存在。
- **不是防抖窗口没到**：`DEFAULT_DEBOUNCE = 500ms`（`watcher.rs:38`），
  用户观察时早就过了。
- **不是"没有监听代码"**：WATCH-01 完整存在（`notify = "7"`，`main.rs:344`
  spawn，有集成测试 `crates/daemon/tests/watch_flow.rs` 断言"删除后必须
  emit `timeline.invalidated`"）。

## 三条待验的假设（按可能性排序）

1. **监听句柄失效**：用户删的是**整棵子树**（连日期子目录一起），macOS
   FSEvents 在被监听目录本身被删除/重建后可能不再投递事件。
   验法：`fs_usage` 或在 daemon 里打监听事件日志，删一个**单文件**（保留
   目录）看有没有事件；再删整个目录看有没有。
2. **删除路径的前缀对账没匹配上**：`watcher.rs:287` 的
   `list_asset_paths_under(&prefix)` —— prefix 是从事件路径推出来的，
   目录整棵消失时事件里的路径可能是 `originals` 本身或已不存在的子目录，
   与 `rel_path` 的前缀口径对不上 → 查出 0 条 → 什么也不删。
   验法：给那段加日志打 prefix 与命中条数；或直接单测喂一个"整棵子树删除"
   的事件序列。
3. **事件被"ingest 瞬态 remove"的过滤吞掉**：文件头注释写了"ingest 移动
   文件产生的瞬态 remove 由防抖窗口吸收"——如果吸收逻辑判据太宽，真删除
   也会被当成瞬态。

## 为什么 `watch_flow.rs` 是绿的却没拦住

集成测试删的多半是**单个文件**，而用户删的是整棵子树。假设 1 和 2 都只在
"目录级删除"时暴露。**补测试时必须覆盖"删整个日期目录"和"删 originals 本身"
这两种形状**，否则修完还是拦不住。

## 范围

只准动：
- `crates/daemon/src/watcher.rs`（删除分支的对账与事件过滤）
- `crates/daemon/src/reconcile.rs`（如判定是前缀口径问题）
- `crates/daemon/tests/watch_flow.rs`（补目录级删除的用例）

## 不准动

- 照片墙前端（`apps/desktop/src/photoWall.js` 的三向合并已经能正确移除，
  DESK-09 那轮已测；这张卡是 daemon 侧根本没发事件/没改索引）。
- SYNC-01 每小时全量对账（它是兜底，能最终一致——**这也解释了为什么这个
  bug 一直没被发现：等一小时就自己好了**）。

## 可执行验收

- 单测/集成：删单文件 / 删整个日期子目录 / 删 `originals` 本身，三种形状
  都必须 emit `timeline.invalidated` 且索引减到位。
- **反证**（必带）：把删除分支的对账去掉 → 上面三条必须变红。
- 真机：Finder 删几张 → 桌面照片墙 5 秒内消失、`select count(*) from asset`
  同步减少。

## 补充：一个可能相关的观察

用户这次是**先备份 186 张、再一次性删光**。如果 daemon 在 ingest 那 186 张
期间攒了大量 watcher 事件，删除事件可能排在很长的队列后面，或者被合并逻辑
误吞。排查时留意事件积压这条线。
