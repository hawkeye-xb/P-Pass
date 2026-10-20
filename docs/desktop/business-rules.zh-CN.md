# 桌面业务规则（daemon + 桌面壳）

## 0 范围与读法

- 范围：桌面端 `crates/{daemon,core-index,core-media,media-codec,storage,proto,diag,platform,version-cmp}` 与 `apps/desktop`（`src-tauri` + Svelte）。只支持 macOS 与 Windows 带界面版本；Linux / 免 GUI 内核方向已于 2026-10-20 关闭（里程碑 #7）。
- 读者是 agent。定位一律用「文件路径 + 符号名」与 case ID，不用行号。
- 真相源层级：代码常量 > 本文 > 设计归档。本文与代码冲突时以代码为准，并在同一 PR 改本文。
- §12 常量表由测试校验（见 §12 开头）。改常量必须同步改表，否则测试变红。
- 跨端合同不在本文复制，按 ID 引用：
  - `docs/design/2026-08-29-arch01-backup-core/04-case-matrix.zh-CN.md`（case ID：O-/D-/R-/C-/H-/E-/X-/P-/I-）
  - `docs/design/2026-08-29-arch01-backup-core/final-design-413.md`（下称 final-design-413）
  - `docs/design/2026-08-29-arch01-backup-core/README.zh-CN.md`（ARCH-01）
  - `docs/design/2026-08-29-arch01-backup-core/workstreams-contract-413.md`（下称 contract-413）
- 「拍板」标注 issue 号与日期；「待 #N」表示规则已定、实现或验证挂在该 issue。

## 1 分层与职责（ADR-012）

ADR-012：**业务只在 `crates/`；平台差异只在 `crates/platform`；桌面壳 = UI + 托管。**

### 1.1 daemon（`crates/daemon`）= 全部业务判断

对外接口三类：
- 网络（`crates/proto`，ALPN `ctrl` / `blobs` / `download`，入口 `daemon::router::Router::dispatch`）。
- 本机 IPC（行分隔 JSON，首行 token，入口 `daemon::ipc::IpcServer`）。只服务同机桌面壳与 testclient。
- CLI（`daemon::cli::parse_cli`）：常驻启动；一次性子命令 `config init --library <dir>`、`config set-library <dir>`、`diag export --out <zip> [--app-version <v>]`；`--version [--json]`。子命令不启服务、不占端口、不开库。退出码：0 成功；1 操作失败（stderr 一行，校验类为带 key 的 JSON）；2 用法错误。

daemon 是 `config.toml` 与诊断包的唯一写者（壳经子命令调用，§8.6、§9.3）。

### 1.2 `crates/platform` = 端口

两个 trait，入口 `platform::adapter()` / `platform::hosting()`：

- `PlatformAdapter`（平台能力，`crates/` 任何 crate 可依赖）：`assert_awake`、`power_hint`、`notify`、`data_dir`、`system_locale`、`home_dir`、`pictures_dir`、`ingest_file_name_sanitizer`、`migrate_legacy_data_dir`、`volume_stats`、`on_external_power`、`watch_external_power`、`daemon_log_paths`、`default_log_tees_stderr`、`capture_unattached_stderr`、`restrict_to_owner`、`truncate_own_stderr`、`disable_auto_sleep`、`remove_stale_ipc_endpoint`、`system_video_thumbnail`、`platform_name`、`power_settings_uri`、`tray_icon_is_template`、`is_file_in_use_os_error`、`close_to_tray_hint`、`overlay_titlebar`、`sleep_owner`、`tray_shows_menu_on_left_click`。
- `HostingAdapter`（托管，只许 `apps/desktop` 用）：自启登记（`install_autostart` / `uninstall_autostart` / `autostart_registration` / `reconcile_autostart` …）、`service_mode`、`stop_daemon`、`resident_daemon_pid`、`restart_resident_daemon`、壳登录项与换壳（`register_shell_login_item`、`kickstart_shell_agent` …）、`installed_bundle_version`、安装位置闸门（`is_install_location`）。
- 起子进程唯一入口 `platform::command`（Windows 带 CREATE_NO_WINDOW；clippy `disallowed-methods` 拦直接 `Command::new`）。
- 停止信号 `platform::stop_signal()`（#1047，见 §8.5）。

各能力的平台实现差异登记在 §10。

### 1.3 桌面壳（`apps/desktop`）= UI + 托管

- UI：Svelte 呈现 daemon 给出的事实，不做业务判断（设备行状态、计数、可见审计、版本关系、低空间、传输中都读字段，§6）。
- 托管（发行层，纯 Rust `apps/desktop/src-tauri/src/distribution.rs` 判据 + `lib.rs` 执行）：拉起 / 停止 daemon、自启登记对账、用户停止标记、自愈、内核对账（换内核）、应用内更新交接、首启向导是否出现（§8）。
- 壳只读 `config.toml`（`ipc::read_config_data_dir`），写一律走 `daemon config` 子命令（门禁 G4）。
- 壳依赖：`crates/platform`、`crates/version-cmp`（单向 path 依赖）；独立 cargo workspace。

### 1.4 门禁（`tools/arch-check.sh`，自测 `tools/test-arch-check.sh`）

| 规则 | 拦什么 |
|---|---|
| B.1 | `iroh` 只许在 `crates/transport/` |
| B.2 | 平台 cfg（`cfg` / `cfg_attr` / `cfg!`，各 OS 轴）只许在 `crates/platform/`；只豁免 `windows_subsystem` 属性 |
| B.3 | `crates/` 内不得物理删除 `device` / `backup_watermark` 行（跨行、引号、schema 前缀都拦，DEV-02） |
| G1 | 壳（`apps/desktop/src/**` 的 js/ts/svelte、`src-tauri/src/**`）不判断平台、不读 HOME/USERPROFILE/LANG/LC_*、不拼 plist/LaunchAgents、不匹配 OS 报错原文 |
| G2 | `crates/**`（除 platform）无托管代码：不调 `HostingAdapter` 方法、不用托管类型、不出现 launchctl/schtasks/kickstart |
| G3 | `crates/**`（除 platform）不引用 `HostingAdapter` / `platform::hosting` |
| G4 | 壳不写 `config.toml` |
| G5 | platform 之外的 Rust 不用 `std::os::*`、`env::consts::OS`、平台专属 crate、`Command::new` 调系统管理命令 |

白名单 `tools/arch-allowlist.txt`：`[ratchet]` 命中数须与登记数精确相等、相对基线只降不升；`[permanent]` 只放客观平台差异，新增须经 issue 拍板。

## 2 配对与撤销

### 2.1 二维码与令牌

- `daemon::pairing::Pairing::start` 生成 `ppf://pair?node=<64hex NodeId>&t=<24hex>[&r=<relay URL>]`。只带 relay，不带地址（`&a=` 已移除；`transport::pair_link::parse_pair_link` 仍能解析旧码）。
- 令牌 12 字节随机数（`parse_token` 要求恰好 24 hex）。TTL = `TOKEN_TTL_MS`，严格一次性：第一次 `pair.request` 即置 `used`，之后不论结果，其他设备重放被拒。同一 `(token, peer)` 重发返回已有 `request_id`。
- 过期在请求时评估（`Pairing::submit_request`）：系统时钟回拨会让过期令牌复活，这是已知权衡。
- 测试：`pairing_flow::{expired_token_is_rejected, token_replay_is_rejected}`、`pair_status_flow::{bad_token_is_refused_at_once, resubmitting_the_same_token_reuses_the_request_and_the_queue_stays_one_row}`。

### 2.2 提交与审批分离

- `Router::handle_pair`：必须带 `ack_then_poll`，否则在校验令牌之前回 `err.unsupported`（不消耗令牌，#1050）。成功回 `PairSubmitted{request_id, ttl_ms}`；手机轮询 `pair.status`、撤回走 `pair.cancel`（能力位 `pair.status.v1` / `pair.cancel.v1`）。
- `pair.status` 状态：`pending` / `accepted`（带 `pairing_epoch`）/ `denied` / `expired` / `not_found`。ledger 只在内存：daemon 重启后为 `not_found`。只能查自己的 `request_id`。
- 待审批 TTL = `PENDING_TTL_MS`（等于令牌 TTL），同时用于等待、桌面队列清扫、手机轮询截止。
- 业主决定先于手机撤回（`await_owner` 的 `biased` select）。
- 桌面审批：`pairing.confirm` 按 `node_id` > `device_name` > 队首查找；横幅与弹窗显式传 `node_id`（#1044）。查不到或已过期回 NOT_FOUND，不伪造成功。
- 测试：`pair_status_flow.rs`、`pairing_ttl.rs` 全部用例。

### 2.3 审批落库

- `Pairing::apply_verdict` → `storage::Db::accept_pairing`：upsert 设备行 + unrevoke + 写新 `pairing_epoch`（16 字节随机 hex）**在一个事务里**（#1055）；任一步失败整体回滚，结果为 denied。
- 已有设备行沿用库里的名字（业主改过的名优先，DEV-04）；新设备用 `safe_name(自报名)`，截断到 `MAX_DEVICE_NAME_CHARS` 个字符。
- 审计写入失败不让配对 / 撤销失败，只打 warn（`warn_if_audit_failed`，#1055）。
- 测试：`device_repo::{accept_pairing_commits_row_unrevoke_and_epoch_together, accept_pairing_rolls_back_everything_when_the_last_step_fails}`。

### 2.4 设备行不物理删除（DEV-02）

- 只软删：`revoked=1, revoked_at, revoked_by`。恢复信任只有配对能做（`accept_pairing` / `Db::unrevoke`）。门禁 B.3。

### 2.5 撤销：业主移除与手机自己断开

- `RevokedBy::{Owner, Device}`；历史行 `revoked_by = NULL` 按业主移除处理（`Db::backfill_revocation_provenance` 回填）。
- 业主移除（IPC `device.revoke`）：先落库撤销，再 `FlowDelivery::revoke_peer`（先取消该设备全部 active grant，再中断在途拉取），再写审计、关订阅。
- 手机自己断开（`device.unpair`，`Router::handle_unpair`）：带 `pairing_epoch` 时只撤销该 epoch（不匹配不改、仍回 ok，#565）；不带时无条件撤销。
- 撤销后：`authz::check` 只放行 `pair.request` / `pair.status` / `pair.cancel`，hello 也拒；`record_presence` 不刷新 `last_seen`；入库前复检设备状态（`flow_revoke::revoked_device_is_rechecked_before_ingest_even_without_the_sweep`）。

### 2.6 角色

- `storage::Role` 只有 `Member` / `Viewer`；`Role::Owner` 已退役（#1050）。网络端永不授予 owner；`PairRequest.role="viewer"` 才是 Viewer。
- 权限表 `authz::role_allows`：viewer 可浏览（hello、timeline、meta、thumb、download、`blobs.fetch`、订阅、`device.unpair`）；member 另加 `backup.*`、`flow.*`；未知方法一律拒。

### 2.7 presence 与设备行投影

- `daemon::presence::presence`（纯函数，只做展示）：有实时连接 → online；否则 `age = now - last_seen`：`≤ ONLINE_HEARTBEAT_MS` online，`≤ OFFLINE_SENTINEL_MS` recent，更大或从未见过 offline。`last_seen` 只由 hello 刷新，hello 不写审计。
- `daemon::device_projection`（#1044，B4）给 `devices.list` 每行：
  - `removal`：`none` / `disconnected`（手机自己断开，留在主列表）/ `removed`（业主移除，含 NULL 历史行，不进主列表）。
  - `needs_attention`：未撤销且最近一次备份距今 `> BACKUP_ATTENTION_MS`；从未备份不算。与 `OFFLINE_SENTINEL_MS` 同值不同义，不互相替代。
  - `row_state` 优先级：`removed` > `disconnected` > `needs_attention` > `transferring`（`flow_connection` 有值）> presence（`online`/`recent`/`offline`）。
  - `last_activity_at`：`last_seen` 与 `last_backup_at` 取较大者。
- `devices.list` 默认是家庭视图（`Db::list_devices_for_family_view`：未撤销或自己断开）；`include_revoked=true` 给全量（诊断用）。
- 测试：`device_projection::row_state_priority`、`ipc_flow::device_rows_carry_daemon_conclusions_and_status_counts_match_the_list`。

## 3 Flow 收件（手机 → 桌面）

模块 `daemon::flow_delivery::FlowDelivery`，与旧批量管线 `daemon::backup` 独立（§11.3）。跨端语义见 ARCH-01 与 contract-413。

### 3.1 offer

- 入口 `Router::handle_flow_delivery` → `FlowDelivery::offer`。校验（`checked_request`，失败不建 grant）：字段非空、`content_hash` 为 64 hex、`pairing_epoch` 等于该设备当前持久化 epoch（否则 `GuardMismatch` → `err.not_authorized`）；provider ticket 的 hash 必须等于 `content_hash`。
- 判重（`core_index::Ingestor::has_durable_copy`）：索引有这份内容（含 supersede 别名）**且文件在盘上** → `complete_without_fetch`，立即回 `completed` + receipt，不拉取、不预检（R-02、R-03）。
- 空间预检（`FlowDelivery::admit`，在建 grant 之前）：需要 `(size − 已有残片) + size + SPACE_RESERVE_BYTES`，不够回 `storage_full`、不留 grant（H-03）。`size_bytes ≤ 0` 或剩余空间探测不到时放行；库目录不可用回 `library_unavailable`。
- 否则 `upsert_flow_grant_at` 建 / 续 grant，`spawn_fetch_task` 后台拉取，立即回 `state:"active", task_running:true`（NET-06）。
- 同一 tuple 已 `completed`：`Db::rebind_completed_flow_grant` 只改 lease 与 provider，回 `completed` + receipt，不重拉。

### 3.2 grant 状态机（表 `flow_delivery`）

- `Active` → `Completed`（`complete_flow_grant`，写 receipt；completed 不可变）/ `Cancelled`（`cancel_flow_grant`）。cancelled 的行可被新 offer 重新置为 active。
- `flow.suspend`（`FlowDelivery::suspend`）：只中断后台任务，grant 保持 active，残片仍受 GC 保护；已终态时幂等（C-01、C-05）。
- `flow.cancel_tuple`（`FlowDelivery::cancel_by_tuple`）：只凭 `queue_sequence + pairing_epoch + lease_token` 取消，残片失去保护；grant 已终态时回 ok 不改状态（#1027）；tuple 不存在或 lease 已被取代回 `GuardMismatch`。
- `flow.status`：只读；grant 为 active 而进程内没有任务时（daemon 重启后），由这次轮询重新拉起任务（`status_respawns_the_delivery_task_lost_to_a_daemon_restart`）。
- 拉取路径：fetch → 导出到 `.ppf/flow-staging/{node_hex}-{queue_sequence}-{hash_hex}` → `Ingestor::ingest_flow` → `complete_flow_grant` → 推 `flow.delivered`（E-01）。

### 3.3 拉取停滞

- 桌面侧：连续 `FETCH_BYTE_STALL_LIMIT` 没有新字节 → `DeliveryError::Fetch`（`fetch_failed`），推 `flow.failed`。supersede 的区间拉取同一阈值。测试 `flow_delivery::a_fetch_that_receives_no_bytes_fails_within_the_stall_limit_and_pushes_flow_failed`。
- 手机侧另有 3 分钟无字节判路径失败（C-10）。两个阈值各管各端，互不推导。

### 3.4 回收

- 3 天回收（H-05）：`FlowDelivery::expire_stale_grants`，`last_resumed_ms` 早于 `now − GRANT_RESUME_TTL_MS` 且进程内没有在跑的 active grant 被取消。`last_resumed_ms` 由 offer 与 status 重驱刷新。启动扫一轮，之后每小时（§5.4）。
- flow-blobs GC：`.ppf/flow-blobs` 每 60 s 一轮（`main` 里 `Blobs::open_with_periodic_gc` 的字面量），只保护 `Db::active_flow_content_hashes`；保护集查询失败则跳过本轮。
- flow-staging 孤儿：`daemon::sweep_flow_staging_orphans`，宽限 `STAGING_ORPHAN_GRACE`；hash 在 active 保护集、未过宽限、mtime 读不出、文件名不合契约的都不删。启动一次 + 每小时。ingest 成功（含 Duplicate）即删对应 staging 文件。

### 3.5 对端失败三分类（C-12）

- 对外只有 `PeerFailure::code()`：`storage_full` / `library_unavailable` / `storage_failed`，出现在 offer 拒绝的 `msg_key` 与 `flow.failed` 推送的 `code`。
- 细分原因（`materialize_staging_failed` / `materialize_export_failed` / `materialize_ingest_failed` / `offer_storage_full` …）只进日志 `detail=`（`DeliveryError::detail_code`）。
- 分类 `classify_peer_failure`：io 错误优先（空间满 → storage_full；只读 / 无权限 / 不存在 → library_unavailable），否则看环境（库不可写 → library_unavailable；剩余 < `SPACE_RESERVE_BYTES` → storage_full），其余 storage_failed；剩余空间未知不猜 full。
- `RespError.msg_key` 在 Flow 拒绝里放的是上述机器码，不是 i18n key。

### 3.6 supersede（原地替换元数据，#851）

- `FlowDelivery::supersede` → `core_index::supersede`：只拉元数据区间，区间总长 ≤ `MAX_REGION_BYTES`（否则 `region_too_large`）；校验长度相同、差异位置旧副本为 0、整份 hash 等于新 hash；只替换上传者自己的副本。
- 旧副本移进 `.ppf/superseded/`（`QUARANTINE_DIR`），不硬删；**目前没有回收隔离区的任务**。崩溃由启动时 `Ingestor::finish_pending_swaps` 补完。成功写审计 `asset.superseded`（隐藏，§6.4）。

### 3.7 `backup.presence` 与 offer 判重是两个判据（B5）

- `backup.presence`（`BackupEngine::presence`，每页 1–500 个 hash，字面量）：只看索引（含别名），**不看文件是否在盘上**。
- offer 判重额外要求文件在盘上（§3.1）。
- 后果：桌面文件被外部删除后、对账跑之前（最长约 1 h），presence 仍报「在」，手机不补传；对账删掉索引行后收敛。墓碑不拦截重传（O-08）。拍板：保持两个判据并写明差别（2026-10-19）。

## 4 入库与索引

### 4.1 内容身份

- BLAKE3（`core_index::hash_file`，64 KiB 流式读，字面量），与 iroh-blobs 同一 hash 域；hash 是 asset 主键，同内容只有一行。

### 4.2 存放布局与月份口径（B2）

- `originals/<device_dir>/<yyyy>/<mm>/<文件名>`（`Ingestor::place_blocking`）。`device_dir` = 上传设备完整 NodeId 的 64 hex（`core_index::device_dir`，ADR-006：只靠目录树可重建索引）。
- **月份目录按 UTC 切分**（`ingest::year_month`）。目录只是存放位置，拍摄时间以 `taken_at` 为准，换算成用户时区是展示层的事。理由：时区不同的家人共用一个库，任何「本机偏移」都对不齐。拍板 2026-10-20；旧库本来就是 UTC，无迁移。测试 `ingest::tests::year_month_matches_calendar`。
- 重名：`name` → `stem-1.ext` → …，上限 10000 次（`IndexError::NameSpaceExhausted`）。文件名先去目录与 `.`/`..`（`sanitize_file_name`），再经平台 `ingest_file_name_sanitizer`（只有 Windows 有）。

### 4.3 taken_at 优先级

- `ingest::taken_at_ms`：EXIF（有 `OffsetTimeOriginal` / `OffsetTime` 用之；没有则按本机当前偏移解释；取不到本机偏移给 None，不静默当 UTC）> 手机 hint（`capture_at_ms_hint > 0`，MediaStore DATE_TAKEN；永不覆盖 EXIF）> mtime。监听、收编、重建不带 hint。

### 4.4 入库落位

- 已在 `originals/` 树里的文件原地采纳（`rel_inside_originals`），失败不删用户文件；库外文件按布局落位。
- 落位不留 0 字节占位（#1047）：同卷 `hard_link` 原子发布；跨卷先复制成同目录 `.ppf-ingest-<随机>.part` 再 hard_link（`publish_no_clobber`）。
- 同 hash 已有行而文件不在原处：改指新位置，审计 `asset.relocated`。一个路径一行：新行占用的路径被别的 hash 占着时先删老行，审计 `asset.replaced_in_place`（老行缩略图成孤儿，已知欠账）。

### 4.5 什么算照片：`media_kind`（B3）

- 唯一口径 `core_index::media_type_for` / `core_index::media_kind`：扩展名查 `mime_guess` 表，主类型 `image/` 或 `video/`，排除 `NON_MEDIA_IMAGE_TYPES`（svg / svgz / ico）。只看扩展名，大小写不敏感。
- 使用方：监听（`watcher::walk_media`）、收编 / 重建（`rebuild::collect_files`）、对账清存量（`Reconcile::purge_non_media_rows`）、缩略图图 / 视频分流（`media_codec::thumb`）。
- Flow 路径不复检（MIME 由手机给出）。
- 存量：`purge_non_media_rows` 每轮对账都跑（稳态零命中）：按扩展名其实是媒体的只改正 MIME；其余删索引行与缩略图，不动文件，不写墓碑与审计。拍板 2026-10-20。

### 4.6 审计口径

- 四张表 `audit_operation` / `audit_item_evidence` / `audit_tombstone` / `audit_decision`（migration 0006）；写入全部幂等（`INSERT OR IGNORE`）；**没有自动过期**。路由见 `daemon::audit_route::route`。
- 入库审计：`Ingestor::ingest`（监听、旧管线）逐张写 `ingest.new` / `ingest.duplicate`（监听复查已记录文件不写）；`Ingestor::ingest_flow`（Flow）只写两种例外 `asset.relocated`、`asset.replaced_in_place`（B1，拍板 2026-10-20，旧行不迁移）。一轮 Flow 的总结 `flow.round.finished` 由手机经 `flow.audit.submit` 提交，以 `round_id` 幂等。
- 对外展示口径见 §6.4。

## 5 对账与监听

### 5.1 目录监听（WATCH-01）

- `daemon::watcher::LibraryWatcher`，监听 `originals/`：防抖 `DEFAULT_DEBOUNCE`（Reset 窗口），入库并发 `DEFAULT_INGEST_CONCURRENCY`，过滤点开头文件与非媒体。新增 → `Ingestor::ingest`（`src_device` = 本机）→ 缩略图预生成；删除 → `Reconcile::remove_asset` 局部对账。
- 监听启动失败：只 warn，不退出，退回每小时对账兜底。

### 5.2 每小时对账（`daemon::reconcile::Reconcile::run_once`）

顺序：磁盘缺文件的行 → `remove_asset`；`purge_non_media_rows`；`core_index::adopt_orphans`（接了 `with_local_node_id` 才跑）；发 `timeline.invalidated`（不经节流）。单条失败不中断整轮。

- `remove_asset`：删缩略图 → 删行 → 墓碑（`external_delete`，不可恢复）→ 审计 `asset.removed_external`（actor 为空）。
- **墓碑不拦截手机重传**（O-08）：入库与收编都不查墓碑。测试 `core-index/tests/ingest.rs::reupload_of_an_externally_deleted_photo_lands_in_canonical_layout`。

### 5.3 收编孤儿（`adopt_orphans`）

- 补「文件在、索引行没有」的媒体文件；不清表、不改已有行；0 字节文件既不收也不删（`AdoptReport.skipped_empty`）；非规范目录的文件 `src_device` 归本机（2026-08-21）。有收编才写 `index.adopted`。
- 索引丢失后的恢复走这条（`docs/runbook/lost-or-corrupted-index.md`）。`core_index::rebuild` 生产零调用，作为 ADR-006 的可执行证明保留。

### 5.4 启动与周期任务

- 启动顺序（`daemon` 的 `main`）：子命令短路 → 数据目录迁移 → stderr 接管 → 日志 → `Config::load` → 库目录检查 → `purge_legacy_anon_id` → 开库 → 身份 → `claim_single_instance`（同版本退位 exit 0）→ transport bind → 启动回收（`reclaim_inbox`、flow-staging 孤儿）→ 启动对账（`finish_pending_swaps`、`core_index::sweep_ingest_residue`、`reconcile.run_once`）→ 常驻任务。
- `sweep_ingest_residue`（#1047）只在启动跑：删除 `originals/` 下文件名严格匹配 `.ppf-ingest-*.part`、不是符号链接、且没有索引行指向的文件。
- 常驻任务清单：

| 任务 | 周期 | 符号 |
|---|---|---|
| IPC 服务 | 常驻 | `IpcServer::serve` |
| Router（QUIC） | 常驻 | `Router::serve` |
| 目录监听 | 事件驱动 | `LibraryWatcher::spawn` |
| 每小时巡检 | 3600 s（字面量） | 对账、`backup.sweep_sessions`、`backup.reclaim_staging`、`expire_stale_grants`、`sweep_flow_staging_orphans` |
| flow-blobs GC | 60 s（字面量） | `Blobs::open_with_periodic_gc` |
| diag 环清理 | 6 h（字面量） | `DiagAgg::prune_ring` |
| 运行统计 daemon_alive | 24 h（字面量），只写本地日志 | `stats::Event::DaemonAlive` |
| 缩略图预生成 | `PREGEN_WORKERS` 个线程；启动 10 s 后回填一次 | `QueryEngine::start_thumb_pregen` |
| 插电保持唤醒 | 事件驱动 | `awake::ExternalPowerHold` + `watch_external_power` |
| 日志折叠 sweeper | 每 `IDLE_GAP` | `log_guard::DedupGuard::spawn_sweeper`（std 线程） |
| stdin EOF | 常驻读；只在 `--ephemeral` 时 EOF 触发退出 | `main` 内 `eof_tx` |
| 停止信号 | 事件驱动 | `platform::stop_signal`（§8.5） |

### 5.5 缩略图

- `media_codec::thumb`：`THUMB_SIZES` 两档（最长边），JPEG 质量 `JPEG_QUALITY`，路径 `.ppf/thumbs/<hash 前 2 位>/<hash>.{256,1024}.jpg`。失败不在最终路径写任何东西，记 `thumb_state=2`，回内存占位图。
- `thumb.get`（`QueryEngine`）：即时生成预算 `THUMB_BUDGET`，超时回占位图；失败负缓存 `THUMB_RETRY_AFTER`（内存，重启清空）；同 hash 同时只生成一次。
- 预生成（`daemon::thumb_pregen`）：前台 `thumb.get` 生成时让路；启动回填重试 `thumb_state=2` 的行。

### 5.6 运行模型纪律

- 单进程、单 tokio 多线程运行时。常驻任务只有 §5.4 那张表；其余都是来活才 spawn、干完即灭（每个 IPC 连接、每个 QUIC 会话、每次 Flow 拉取 `spawn_fetch_task`）。
- 会等磁盘或吃 CPU 的活（扫盘、批量 stat、缩略图解码、大文件入库、读 stdin）一律 `spawn_blocking`，不压在事件循环上（DESK-13）。
- 有界：入库并发 `DEFAULT_INGEST_CONCURRENCY`；预生成 `PREGEN_WORKERS`；transport 入站连接 `mpsc::channel(16)`；事件总线 64；事件节流 `DEFAULT_THROTTLE_WINDOW`。
- 等待必须带死线，错误串带方法名：daemon 探活对端 800 ms（`ipc.rs` `peer_call`）；壳每次 IPC 读 `IPC_READ_TIMEOUT`（NET-11，事件订阅长连接豁免）；壳等重启 `RESTART_GRACE`；收尾 `SHUTDOWN_DEADLINE`。
- SQLite WAL，读不挡写。
- 新增后台任务时：会等盘 / CPU → `spawn_blocking`；没有并发上限 → 加 `Semaphore` 或有界 channel；有等待 → 死线 + 错误串带标识；事件会爆发 → 走 `Throttle`；常驻任务 → 更新 §5.4 的表；新增业务数字 → 具名常量 + §12 一行 + 测试登记。

## 6 对 UI 暴露的事实

壳只读下面这些字段，不再自己推导。

### 6.1 `status`（`IpcServer::status`）

| 字段 | 含义 |
|---|---|
| `paired_devices` | 设备页主列表行数（含自己断开的），即「已配对 N 台」（B4） |
| `removed_devices` | 业主移除的行数（「已移除」区） |
| `devices` / `revoked` | 全部行数 / 已撤销行数（诊断口径） |
| `pending_pairs` | 待审批数（不含已撤回） |
| `transfer_active` | 任一未撤销设备 `flow_connection` 有值（与设备行「传输中」同一信号） |
| `shell_relation` | 壳传 `shell_version` 时：`same` / `shell_older` / `shell_newer`；没传为 null（§6.5） |
| `low_space_notice` | `{free_bytes}` 或 null（§7.3） |
| `disk_free_bytes` / `disk_total_bytes` | 库所在卷容量，拿不到为 null |
| `state` / `msg_key` | `ONLINE_DIRECT` 或 `PAIRING`（#1053 起只剩这两种） |
| `version` / `pid` / `started_at` / `exe_path` / `library_dir` / `photo_count` / `photo_sources` | 自述 |

### 6.2 时间线

- `Db::timeline_page`：键集分页 `ORDER BY COALESCE(taken_at,0) DESC, hash ASC`，`limit` 夹在 1–1000。前端 `photoWall.js::comparePhotoOrder` 照抄同一排序做局部插入，改排序两边同改。
- 照片墙分组（今天 / 昨天 / 本周 / 本月 / 更早）按本地时区，属展示层。

### 6.3 原图与设备目录

- `asset.original`（`QueryEngine::original`，只走本机 IPC）：MIME 以 `image/` 开头且 ≤ `ORIGINAL_CAP` 才返回字节，否则 NotFound，桌面退到 1024 缩略图。HEIC/RAW 在 WebView 里的解码回退待 #1054。
- `device.folder`：返回 `{path, is_device_dir}`：`originals/<device_dir>` 存在则用它，否则 `originals/`，再否则库根。壳不自己拼存储路径。

### 6.4 审计用户投影（`audit.list`）

- 带 `visibility:"user"`：`Db::list_operations_excluding` 在 SQL 里先排除隐藏项、再截断（壳请求 500 条）。不带为全量（诊断口径）。
- 隐藏：`HIDDEN_KINDS`（`device.connected`、`flow.round.controlled`、`flow.scope.changed`、`flow.epoch.invalidated`、`asset.relocated`、`asset.replaced_in_place`、`asset.superseded`、`index.rebuild`、`index.adopted`、`backup.commit`）与 `HIDDEN_PREFIXES`（`ingest.`、`flow.item.`）。有文案的 kind 在 `USER_KINDS_WITH_COPY`；未知 kind 保持可见、走兜底文案。`DAEMON_WRITTEN_KINDS` 里每个 kind 必须恰好属于两类之一（测试 `every_daemon_written_kind_has_copy_or_is_explicitly_hidden`）。
- `flow.round.finished` 的 `counts` 由 daemon 按 evidence 重算（`audit_projection::round_counts`），不读手机自报。
- 外部删除提醒：前端 `lib/externalDelete.js`，只认 `asset.removed_external`，窗口 `EXTERNAL_DELETE_WINDOW_MS`；关闭状态只在内存。

### 6.5 版本关系（B13）

- 唯一实现 `crates/version-cmp`（壳与 daemon 共用，DAE-01 握手也用它）：按第一个 `-` 切核心与预发布；数字段逐段比，缺段补 0；核心相同时无预发布 > 有预发布；两边都有预发布时只比数字（`test.10 > test.9`，标签名不参与，`rc.1` 与 `test.1` 相等）。
- 壳据 `shell_relation` 决定提示：`shell_newer`（服务旧且壳不旧）显示「重启后台服务」。设置页「关于」分列壳版本与后台服务版本，不一致时标出。
- 风险：若应用版本改为日历版而 test tag 仍是 `0.x.y-test.N`，test 包会被判比正式包旧，内核对账（§8.4）会拒绝「降级」。

### 6.6 事件

- `daemon::events`：`timeline.invalidated`、`pairing.pending_changed`、`status.changed`、`activity.appended`、`device.changed`、`flow.delivered`、`flow.failed`。总线 `broadcast` 容量 64，落后的订阅者丢旧事件，客户端靠全量刷新兜底。
- 入库触发的 `timeline.invalidated` 经 `Throttle`（`DEFAULT_THROTTLE_WINDOW`，节流不是防抖，窗口到点必发）。
- 壳：事件订阅长连接断线 2 s 重连；另有兜底刷新 `FALLBACK_REFRESH_MS`。

### 6.7 daemon 启动失败

- `Db::open` 失败时 stderr 最后一行是 `cli::startup_error_line` 的 JSON `{"error_key", "detail"}`；只有「库 schema 比程序新」带 key `ui.startup_migration_guidance`（`cli::startup_error_key`）。壳 `daemon_startup_error` 转给前端 `startupFailureText`，不再用正则匹配原文。

## 7 健康与低空间

### 7.1 `hello.health`

- 只回给已配对未撤销成员（未配对者零数据握手）：`DesktopHealth{free_bytes, library_writable, index_ok}`（`FlowDelivery::health`）。`free_bytes = null` 表示平台答不出，不是 0；可写探针不建目录。缺字段的旧桌面按健康处理（H-02）。
- 手机据此决定是否开始（H-01）。手机用 hello 的 `pairing_epoch` 判断自己是否仍是成员（Android #1051、iOS #1052），不再借 `backup.begin`。

### 7.2 offer 准入保留量

- `SPACE_RESERVE_BYTES`（§3.1）。手机端 Kotlin / Swift 各有一份同值常量。

### 7.3 桌面低空间通知（H-04，B11）

- `daemon::low_space`：剩余 < `LOW_SPACE_THRESHOLD_BYTES` 通知一次并解除布防；回到 ≥ `LOW_SPACE_REARM_BYTES` 才重新布防。布防状态与待展示项持久化在表 `low_space_notice`（migration 0012），**重开 App 不重弹**（拍板 2026-10-20）。
- 边沿触发：`status.low_space_notice` 带出待展示项，壳弹系统通知后调 `low_space.ack`。读不到剩余空间不推进状态。
- 阈值与手机常量对账：`flow_health::{low_space_threshold_is_exactly_five_gib, low_space_threshold_matches_both_phone_sources}`。注意：只改手机常量的 PR 不触发 Rust lane，这条对账测试此时不跑。
- 桌面系统通知只发低空间；库不可写、索引异常不发桌面通知（H-01 只约束手机侧）。

## 8 常驻、自愈与更新

### 8.1 服务模型

- `HostingAdapter::service_mode`：macOS `LaunchAgent`、Windows `ScheduledTask`，二者 `has_service_manager() = true`；`UserAutostart` 只是兜底实现（无服务管理器）。
- macOS：LaunchAgent `com.p-pass.daemon`，`RunAtLoad` + `KeepAlive{SuccessfulExit=false}`：正常退出（退位 exit 0）不重拉，崩溃 / 被杀重拉；stdout / stderr 落 `<data_dir>/logs/daemon.{out,err}`（#1046）。
- Windows：每用户计划任务 `P-Pass`：登录触发 + 每分钟看门狗（`PT1M`，已在跑就跳过，#957）；旧版 Run 值在登记时清掉。

### 8.2 用户停止标记

- `distribution::USER_STOPPED_MARKER`（数据目录下的文件，独立于 `config.toml`）是区分「崩了」与「用户停了」的唯一依据，跨 App 重开持久。
- `stop_daemon_now`：先落标记（落不下就不停）→ 撤销自启登记 → 停进程 → 等不可达。点「启动服务」或走完向导清标记。
- 停进程（`HostingAdapter::stop_daemon`）：只认可执行文件**完整路径**上的进程（pid 提示先核对文件名）；unix 发 SIGTERM，Windows TerminateProcess 并等待（B7，不再 `pkill -f`）。

### 8.3 自愈与启动对账

- `distribution::self_heal_allowed`：`config.toml` 存在 **且** 非用户停止。
- 新壳启动（`lib.rs::startup_reconcile`，独立线程）：先 `reconcile_autostart_registration`（用户停过只撤残留登记；否则按内容对账：Rewritten #604 / Refreshed #1046 / Repaired #726；Windows 登记缺失时补登记 DESK-60），再 `converge_kernel_on_startup`。
- `converge_kernel_on_startup` 先等 daemon 应答，最长 `RESTART_GRACE`；超时后**只有服务状态为 Unreachable** 才 `self_heal_now`（NotConfigured / Stopped 不拉，以免把用户踢出向导）。
- 前端自愈 `maybeSelfHeal`：只在 `serviceState === "unreachable"` 时调 `self_heal_daemon`，重试冷却 `SELF_HEAL_COOLDOWN_MS`。与启动对账共用 `self_heal_now` 同一道门。
- 服务状态（`service_state::ServiceState`）：`not_configured` / `stopped` / `starting` / `running` / `unreachable`；失败不会把 NotConfigured / Stopped「发明」成 Starting。

### 8.4 内核对账（自动换内核，#667 / #732）

`distribution::kernel_convergence_verdict`：
- 用户停了 / 版本读不到 → 不动。
- 运行中的内核比磁盘上的新 → 不动（**不降级**）。
- 比磁盘旧，或同版本但常驻已登记而运行实例不归服务管理器管 → 需换。
- 需换但 `status.transfer_active` → 推迟，每 `KERNEL_CONVERGE_POLL` 复查；推迟过的要再连续确认一次（共两次，约 20 s）才换。
- 执行 `restart_daemon_process_blocking`：有服务管理器则让野生实例经 `daemon.step_down` 退位、再由服务管理器拉起；否则杀掉后一次性 spawn。之后等应答最长 `RESTART_GRACE`；`restart_outcome` 区分版本已变 / 未变 / 仍在启动。手动「重启后台服务」同一路径。

### 8.5 停止信号与收尾（#1047）

- `platform::stop_signal`：unix 收 SIGTERM / SIGINT / SIGHUP；Windows 收 CTRL_C / CTRL_BREAK / CTRL_CLOSE / CTRL_LOGOFF / CTRL_SHUTDOWN。
- 收到后停接新连接，`transport.close()` 限时 `SHUTDOWN_DEADLINE`；收尾中再收到一次信号立即退出。unix 退出时恢复默认处理并对自己重发同一信号（退出状态是「被信号终止」，launchd 仍会按 KeepAlive 重拉）。
- 被强杀（SIGKILL / TerminateProcess）不经收尾：SQLite WAL + `synchronous=FULL`，落位不留占位文件，残留由启动 `sweep_ingest_residue` 清。

### 8.6 首启向导与 config

- 向导是否出现由 Rust 判（`distribution::show_wizard`）：daemon 在线永不显示；未配置显示；已配置时未登记自启且非用户停止才显示。前端只读 `wizard_state.show_wizard`。
- 两份视图 `Wizard.svelte`（macOS）/ `WizardWindows.svelte` 共用状态机 `lib/wizardFlow.js`；差异只在第 2 步睡眠由谁负责（`platform_ux.sleep_owner`：macOS `user` 引导关闭自动睡眠，Windows `daemon` 插电保持唤醒）。完成后等 daemon 就绪 `READY_POLLS` × `READY_POLL_MS`。
- `config.toml` 由 `daemon config init` / `config set-library` 写；首启模板固定端口 `daemon::config::DESKTOP_BIND_ADDR`（`0.0.0.0:41145`），运行时 `Config.bind_addr` 缺省为系统分配。新建库默认目录名 `P-Pass Library`（不随语言变，B10），父目录由 `pictures_dir()` 回答。`deny_unknown_fields`；退役字段 `rendezvous_url` / `log_level` 接受并忽略。
- 托盘与安装位置对话框初始语言取 `system_locale()`：系统语言明确为中文才用中文，否则英文（B6）。

### 8.7 应用内更新

- 壳经 tauri-plugin-updater 检查 → 下载 → 验签 → 替换 → 重启；清单与通道见 `docs/RELEASING.md` §3.5、§3.6。
- 流程：`pause_daemon_for_update` 停旧 daemon（**不写**用户停止标记、不动登记）→ 替换整包 → `relaunch_shell` 重启壳（macOS 已登记且指向自己时 `kickstart_shell_agent`，否则 `tauri::process::restart`；Windows 由 NSIS 安装器拉起新壳）→ 新壳启动对账（§8.3）拉起新 daemon。旧壳不再负责拉起（`resume_daemon_after_update` 已删，#1046）。
- 安装失败：前端调 `self_heal_daemon`，并显示 `update_failure_key`（Windows「文件被占用」按系统错误码 `is_file_in_use_os_error` 给 key）。

### 8.8 崩溃恢复时长

| 平台 / 环节 | 时长 | 依据 |
|---|---|---|
| macOS daemon 崩溃 → launchd 重拉 | 约 10 s（launchd 默认节流；plist 未设 ThrottleInterval） | `platform::macos` `agent_plist`；系统默认值未在代码里核实 |
| Windows daemon 崩溃 → 看门狗重拉 | ≤ 60 s（下一个整分钟） | 计划任务 `PT1M`（#957 实测） |
| 壳判定重启结果的宽限 | `RESTART_GRACE` | `lib.rs` |
| 壳连接宽限（启动初期失败算 starting） | 15 s（`start_event_stream` 局部变量） | `service_state::failure_state` |
| 优雅退出上限 | `SHUTDOWN_DEADLINE` | daemon `main` |

## 9 诊断与日志

### 9.1 daemon 日志

- 落点 `PlatformAdapter::daemon_log_paths`：`<data_dir>/logs/daemon.log`；macOS 另有 `daemon.out` / `daemon.err`（launchd 接管 stdio，且文件与 stderr 双写），Windows 另有 `daemon.err`（stderr 无人接时 daemon 自己接上，DESK-58）。`PPF_LOG_FILE` 覆盖，打不开 exit 2；平台默认打不开只警告退回 stderr；debug 构建不落盘。
- `log_guard::DedupGuard`：`daemon.log` 超过 `SINK_CAP_BYTES` 轮转为 `daemon.log.1`（只留一代），计数跨运行从现有大小起算；macOS 的 `.err` 同样封顶、超限就地截断。重复行（去时间戳后相同）首条立即写，之后只计数，安静 `IDLE_GAP` 后写一行汇总。落盘前过脱敏。
- 壳自己的日志 `<data_dir>/logs/desktop.log`：超过 `MAX_LOG_BYTES` 轮转一代；同一失败 `FAILURE_LOG_INTERVAL_MS` 内只记一次。

### 9.2 diag 事件环

- 表 `diag_event` 保留 `RING_DAYS_MS`，`DiagAgg::prune_ring` 每 6 h 剪一次。`status.state` 只剩 `ONLINE_DIRECT` / `PAIRING`（`diag::DaemonState`，#1053）。

### 9.3 脱敏与诊断包

- 正本 `daemon::redact`（规则 0 字节数组、1 公网 IP、2 非白名单 URL 主机、3 长不透明串、4 长 hex；导出另有 `redact_export` / `mask_paths` / `scrub_full`）。副本：`transport::redact`（logcat 出口）、Android `Redact.kt`。三份都跑 `assets/privacy/redact-vectors.json`。壳没有副本。
- 诊断包只由 `daemon diag export` 组装（`diag_bundle::build_bundle`，#1042/#1045）：始终有 README / versions / config-summary / log-sources；日志尾部（`daemon.log` 取 `DAEMON_LOG_TAIL`，其余取 `SMALL_LOG_TAIL`）；daemon 在线时经 IPC `logs.export`（超时 `daemon::diag_bundle::IPC_TIMEOUT`）取 diag_events / devices / audit，离线不算失败、不开数据库。`devices.json` 在包边界删名字（`strip_device_names`）。不读 launchd plist。

## 10 平台业务差异登记表

只登记客观差异；其余一律两平台同一实现。

| 能力 | macOS | Windows | 依据 |
|---|---|---|---|
| 常驻模型 | LaunchAgent KeepAlive | 计划任务：登录 + 每分钟看门狗 | §8.1；#957 |
| 崩溃恢复时长 | 约 10 s | ≤ 60 s | §8.8 |
| 首启向导第 2 步（睡眠） | 用户关闭自动睡眠（`disable_auto_sleep` 提权跑 pmset，`power_hint` 读现状）；改为电源事件订阅待 #999 | daemon 插电时保持唤醒（`ExternalPowerHold`），向导不问 | `sleep_owner`；DAE-11 |
| 安装位置闸门 | 只对稳定安装位置做自启对账；只允许从「应用程序」运行待 #998 | 不在安装位置的副本拒绝运行（DESK-68） | `is_install_location` / `autostart_reconcile_allowed` |
| 登记缺失时补登记 | 否 | 是（卸载会删登记，DESK-60） | `autostart_restore_when_missing` |
| 数据目录 | `~/Library/Application Support/P-Pass` | `%LOCALAPPDATA%\com.p-pass.desktop`（老 Roaming 目录在时沿用，迁移见 §11） | `data_dir` |
| 入库文件名 | 不改 | 去非法字符 / 保留名 / 结尾点与空格 | `ingest_file_name_sanitizer` |
| 视频缩略图 | media-codec 用 qlmanage | 系统 `IShellItemImageFactory` | `system_video_thumbnail` |
| 关窗与标题栏 | 不提示藏到托盘；overlay 标题栏 | 提示一次；系统标题栏 | `close_to_tray_hint` / `overlay_titlebar` |
| 更新时文件被占用 | 不适用 | 按系统错误码给 key | `is_file_in_use_os_error` |

Windows 真机验证清单：#1056。

## 11 兼容与退役线

### 11.1 最低支持版本

- 手机：Android ≥ v0.9.0（拍板 2026-10-19）；iOS 无已发布旧版，直接用新协议。
- 待 #990：旧批量管线退役后，最低 Android 版本提到首个带 #1051（成员探针改用 hello）的正式版；更旧的手机只有「已配对状态下重扫码」会被拒，在桌面移除设备后重新配对即可。
- 协议版本 `proto::PROTO_VER` / `proto::MIN_SUPPORTED_VER`；握手 `min_ver` 目前不生效（空机制）。

### 11.2 仍保留的兼容分支与退役条件

| 分支 | 位置 | 退役条件 |
|---|---|---|
| `--post-update` 接受并忽略 | `daemon::cli` | 下一个版本删 |
| config `rendezvous_url` / `log_level` 接受并忽略 | `daemon::config::Config` | 不删（`deny_unknown_fields` 下删字段会让旧 config 失败） |
| Windows 旧 Run 值 `P-Pass` 清理 | `platform::windows` `delete_legacy_run_value` | 另定 |
| Windows Roaming → Local 数据目录迁移 | `platform::data_migration` | 另定 |
| `purge_legacy_anon_id` | `daemon::stats` | 另定 |
| macOS 旧 plist 内容按需重写（Refreshed） | `HostingAdapter::reconcile_autostart` | 另定 |
| 老 daemon 无 `events.subscribe` 时壳退回 30 s status 探针 | 壳 `start_event_stream` | 另定 |
| 旧二维码 `&a=` 解析 | `transport::pair_link::parse_pair_link` | 另定 |
| `device.unpair` 不带 epoch 时无条件撤销 | `Router::handle_unpair` | 随最低手机版本 |
| `PairRequest.ack_then_poll` 字段与 viewer 角色 | `proto::PairRequest` / `storage::Role` | 另定 |
| 旧批量管线 `backup.begin` / `manifest` / `commit`、`ingest_staged`、`note_delivered`、会话与 `.ppf/staging` | `daemon::backup::BackupEngine`、`Router` | #990（`backup.presence` 保留并迁出） |

已退役（不要再加回）：`flow.fetch` / `flow.cancel`、阻塞式 `pair.request`、`Role::Owner`（#1050）；diag 死状态与对应 i18n key（#1053）；UPD-07 换壳链与 daemon 内 `update.rs`、`KeyStore`、stdin y/n 确认器（#1041）；upload 平面 `ppf/upload/1`（#988）。

### 11.3 旧管线与 Flow 的边界

- 桌面：`daemon::flow_delivery` 与 `daemon::backup` 互不调用；Flow 的生产路径只走 `flow.*` 与 blobs 数据面。旧管线只为 #990 之前的老手机保留，不加功能。
- Android：新生产核心在 `backup/flow/`，不得引用旧批量 API，由 `FlowBoundaryTest`（`flow_sources_are_physically_namespaced_and_do_not_reference_legacy_batch_apis`、`legacy_entrypoints_are_explicitly_marked_frozen`）守。旧 `BackupRunner`（#988）与 `DaemonBackupTest` 已删除。
- 产品不变量以 case ID 表述（C-01～C-05、C-09、X-*），不以旧测试的形状表述。

## 12 数字常量总表

- 校验测试：`归属 = daemon` 的行由 `crates/daemon/src/business_rules_table.rs` 校验；`desktop-shell` 由 `apps/desktop/src-tauri/src/business_rules_table.rs`；`desktop-ui` 由 `apps/desktop/src/businessRulesTable.test.js`。每个测试双向比对：表里本归属的每一行都必须在代码里存在且值相等，代码登记的每个常量都必须在表里有一行。daemon 的测试另核对「归属」只用这三个值。
- 「值」是基本单位下的整数（ms、B、个、字符、px）；列表用逗号分隔。
- `main` 里的周期字面量（每小时巡检、flow-blobs GC 60 s、diag 清理 6 h、daemon_alive 24 h、预生成回填延迟 10 s）没有具名常量，不在表内，见 §5.4。

| 符号 | 归属 | 值 | 单位 | 规则 |
|---|---|---|---|---|
| `daemon::pairing::TOKEN_TTL_MS` | daemon | 600000 | ms | 配对令牌有效期 10 min（§2.1） |
| `daemon::pairing::PENDING_TTL_MS` | daemon | 600000 | ms | 待审批有效期（§2.2） |
| `daemon::pairing::MAX_DEVICE_NAME_CHARS` | daemon | 64 | 字符 | 设备名上限（§2.3） |
| `daemon::presence::ONLINE_HEARTBEAT_MS` | daemon | 120000 | ms | 2 min 内见过 = online（§2.7） |
| `daemon::presence::OFFLINE_SENTINEL_MS` | daemon | 432000000 | ms | 5 天没见过 = offline（§2.7） |
| `daemon::presence::BACKUP_ATTENTION_MS` | daemon | 432000000 | ms | 5 天没备份 = needs_attention（§2.7） |
| `daemon::flow_delivery::SPACE_RESERVE_BYTES` | daemon | 268435456 | B | offer 空间预检保留 256 MiB（§3.1） |
| `daemon::flow_delivery::FETCH_BYTE_STALL_LIMIT` | daemon | 60000 | ms | 拉取 60 s 无字节判失败（§3.3） |
| `daemon::flow_delivery::GRANT_RESUME_TTL_MS` | daemon | 259200000 | ms | active grant 3 天无人续传即取消（§3.4） |
| `daemon::backup::STAGING_ORPHAN_GRACE` | daemon | 3600000 | ms | staging 孤儿宽限 1 h（§3.4） |
| `daemon::backup::SESSION_IDLE_TTL` | daemon | 3600000 | ms | 旧管线会话空闲 1 h 回收（§11.2） |
| `core_index::MAX_REGION_BYTES` | daemon | 8388608 | B | supersede 元数据区间上限 8 MiB（§3.6） |
| `daemon::watcher::DEFAULT_DEBOUNCE` | daemon | 500 | ms | 监听防抖（§5.1） |
| `daemon::watcher::DEFAULT_INGEST_CONCURRENCY` | daemon | 4 | 个 | 监听入库并发（§5.1） |
| `daemon::events::DEFAULT_THROTTLE_WINDOW` | daemon | 1000 | ms | `timeline.invalidated` 节流窗口（§6.6） |
| `daemon::PREGEN_WORKERS` | daemon | 1 | 个 | 缩略图预生成线程（§5.5） |
| `media_codec::THUMB_SIZES` | daemon | 256,1024 | px | 缩略图两档最长边（§5.5） |
| `media_codec::JPEG_QUALITY` | daemon | 85 | 个 | 缩略图 JPEG 质量（§5.5） |
| `daemon::query::THUMB_BUDGET` | daemon | 5000 | ms | 即时生成预算（§5.5） |
| `daemon::query::THUMB_RETRY_AFTER` | daemon | 600000 | ms | 失败负缓存 10 min（§5.5） |
| `daemon::query::ORIGINAL_CAP` | daemon | 12582912 | B | 原图 12 MiB 上限（§6.3） |
| `daemon::low_space::LOW_SPACE_THRESHOLD_BYTES` | daemon | 5368709120 | B | 低空间通知 5 GiB（§7.3） |
| `daemon::low_space::LOW_SPACE_REARM_BYTES` | daemon | 6442450944 | B | 回到 6 GiB 重新布防（§7.3） |
| `daemon::SHUTDOWN_DEADLINE` | daemon | 8000 | ms | 收到停止信号后收尾上限（§8.5） |
| `daemon::log_guard::SINK_CAP_BYTES` | daemon | 8388608 | B | daemon 日志 8 MiB 轮转（§9.1） |
| `daemon::log_guard::IDLE_GAP` | daemon | 2000 | ms | 重复行安静 2 s 出汇总（§9.1） |
| `daemon::diag_agg::RING_DAYS_MS` | daemon | 2592000000 | ms | diag_event 保留 30 天（§9.2） |
| `daemon::diag_bundle::DAEMON_LOG_TAIL` | daemon | 1048576 | B | 诊断包 daemon.log 尾部 1 MiB（§9.3） |
| `daemon::diag_bundle::SMALL_LOG_TAIL` | daemon | 262144 | B | 诊断包其余日志尾部 256 KiB（§9.3） |
| `daemon::diag_bundle::IPC_TIMEOUT` | daemon | 10000 | ms | 诊断包经 IPC 取数超时（§9.3） |
| `proto::PROTO_VER` | daemon | 1 | 个 | 协议版本（§11.1） |
| `proto::MIN_SUPPORTED_VER` | daemon | 1 | 个 | 最低协议版本（§11.1） |
| `desktop::RESTART_GRACE` | desktop-shell | 90000 | ms | 重启 / 启动对账等应答宽限（§8.3、§8.4） |
| `desktop::KERNEL_CONVERGE_POLL` | desktop-shell | 10000 | ms | 内核对账推迟后的复查间隔（§8.4） |
| `desktop::ipc::IPC_READ_TIMEOUT` | desktop-shell | 10000 | ms | 壳 → daemon 每次 IPC 读超时（NET-11） |
| `desktop::daemon_cli::PROBE_TIMEOUT` | desktop-shell | 5000 | ms | `--version --json` 探活上限（§8.6） |
| `desktop::daemon_cli::CONFIG_TIMEOUT` | desktop-shell | 30000 | ms | `config` 子命令上限（§8.6） |
| `desktop::daemon_cli::DIAG_TIMEOUT` | desktop-shell | 60000 | ms | `diag export` 子命令上限（§9.3） |
| `desktop::service_state::MAX_LOG_BYTES` | desktop-shell | 2097152 | B | desktop.log 2 MiB 轮转（§9.1） |
| `desktop::service_state::FAILURE_LOG_INTERVAL_MS` | desktop-shell | 30000 | ms | 同一失败 30 s 只记一次（§9.1） |
| `lib/serviceTiming.js::SELF_HEAL_COOLDOWN_MS` | desktop-ui | 30000 | ms | 前端自愈重试冷却（§8.3） |
| `lib/serviceTiming.js::FALLBACK_REFRESH_MS` | desktop-ui | 60000 | ms | 兜底刷新周期（§6.6） |
| `lib/externalDelete.js::EXTERNAL_DELETE_WINDOW_MS` | desktop-ui | 86400000 | ms | 外部删除提醒窗口 24 h（§6.4） |
| `lib/wizardFlow.js::READY_POLLS` | desktop-ui | 20 | 个 | 向导等就绪轮询次数（§8.6） |
| `lib/wizardFlow.js::READY_POLL_MS` | desktop-ui | 500 | ms | 向导等就绪轮询间隔（§8.6） |

## 附：case-matrix ID ↔ 章节

| case ID | 桌面侧规则 |
|---|---|
| O-08 | §3.7、§5.2（墓碑不拦截重传） |
| O-11 | §5.2 |
| R-01 | §3.1（判重未命中 → 拉取） |
| R-02、R-03 | §3.1（判重命中 → 立即 completed） |
| C-01、C-05 | §3.2（suspend 保留 grant 与残片） |
| C-10 | §3.3（桌面 60 s 与手机 3 min 各管一端） |
| C-12 | §3.5 |
| H-01、H-02 | §7.1 |
| H-03 | §3.1、§7.2 |
| H-04 | §7.3 |
| H-05 | §3.4 |
| E-01 | §3.2 |
| P-02 | §2.3、§3.1（epoch 不匹配即拒） |
| X-03 | §3.2（cancel_tuple） |
