# 索引丢了/坏了怎么排查（`index.sqlite` 丢失或损坏）

> 遇事翻这里（`docs/runbook/README.md` §9）。本文档面向内部排障，不是
> 用户自助文档。没有用户可点的"重建索引"入口；索引丢失后由 daemon 启动
> 对账自动收编（见下）。

## 会出现什么症状

- 手机/桌面照片墙突然清空或数量骤降，但 Finder 直接打开 `originals/`
  目录能看到照片文件本身还在。
- daemon 启动时报数据库打开失败（sqlite 文件损坏/schema 不识别）。
- 用户反馈"换了台电脑，照片在，但相册是空的"（只拷了 `originals/`，
  没拷 `.ppf/` 隐藏目录）。

## 为什么会这样：架构上的设计（不是 bug）

P-Pass 的资产索引（`.ppf/index.sqlite`，`crates/storage`）在架构上被
当成**可以随时从磁盘重新推导出来的缓存**，不是唯一真相来源——真相
来源是 `originals/` 文件树本身（ADR-006）。这个设计的意义：哪怕索引
库整个丢了/坏了，照片和它的元数据理论上都还能找回来，不是真的没了。

会导致索引丢失/损坏的真实场景：
- SQLite 文件本身损坏（断电/磁盘故障砸中写入过程）
- `.ppf/` 是隐藏点号文件夹，容易被用户或清理工具误当成"缓存"删掉
  （紧挨着看得见的 `originals/`，外观上确实很像可删的东西）
- 换电脑/从备份恢复时只拷了 `originals/`，没拷 `.ppf/index.sqlite`
  （有些备份工具默认跳过点号隐藏目录）
- 未来某次数据库 schema 升级出 bug，daemon 打不开旧库，需要硬重置

## 恢复路径：重启 daemon，启动对账自动收编（`adopt_orphans`）

daemon 启动时跑一轮对账，之后每小时一轮（`crates/daemon/src/reconcile.rs`
`Reconcile::run_once`，接了 `with_local_node_id` 才开收编方向）。其中
`core_index::adopt_orphans`（`crates/core-index/src/rebuild.rs`）把
`originals/` 下「文件在、索引行没有」的文件补成索引行：

- 不清表：已有行的 `added_at`、尺寸、缩略图状态不动；稳态一轮零写入。
- 只收媒体文件：判据是 `core_index::media_type_for`（扩展名 → MIME 表，
  `image/*`、`video/*`，排除 svg/svgz/ico）；隐藏文件、0 字节文件不收。
- 有收编时写一条审计 `index.adopted`（actor 为空）。
- 收编后触发缩略图预生成回填。

因此：
- **`.ppf/index.sqlite` 丢了**（被删、换电脑只拷了 `originals/`）：启动
  daemon，空库建好后启动对账把整棵 `originals/` 收编回来。
- **`index.sqlite` 损坏打不开**：daemon 启动失败（stderr 最后一行是
  `cli::startup_error_line` 的 JSON；只有「库 schema 比程序新」带
  `ui.startup_migration_guidance` key）。把 `index.sqlite` 连同同目录的
  `index.sqlite-wal`、`index.sqlite-shm` 三个文件一起移出 `.ppf/` 后重启（只移
  主文件会让旧 WAL 与新库错配），即走上一条。
- 已经丢失、只存在于索引里的信息（审计历史、设备行、配对 epoch）不在
  `originals/` 里，收编找不回；设备需要重新配对。

## `src_device` 解码规则

按目录名 `originals/<64位十六进制NodeId>/<yyyy>/<mm>/文件` 解码
`src_device`（`rebuild.rs::device_of`）。不符合这个格式的文件（daemon
没开时手动塞进 `originals/` 的）**归本机**（2026-08-21 裁决），不再有
"来源不明"一档。

## `core_index::rebuild`（只在测试里调用）

`rebuild(db, library_root, local_node_id)`：清空 `asset` 表 → 全量重扫
`originals/` → 写一条 `index.rebuild` 审计。生产代码零调用（只有
`crates/core-index/tests/rebuild.rs` 与 daemon 的 `backup_flow` 测试），
作为 ADR-006「索引可由文件树重新推导」的可执行证明保留。与
`adopt_orphans` 共用扫描口径。
