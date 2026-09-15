# NET-13 桌面「设备」列表：备份状态误报、缺 ID 列、缺打开目录、在线态未独立成列（L1）

> 🟢 状态：已完成（代码合并 + 本机全绿），待真机/真实多设备场景回归观察
> 级别：**L1**（跨端根因修复 + 桌面 UI 改动）· 阻塞：无

## 问题（用户 2026-09-15 报告，四件套）

1. **状态误报（真 bug，非展示口径问题）**：设备明明已经通过 Flow 备份过
   （`asset_count` 在涨），桌面「家人与设备」页却显示"还没备份过"。
   根因：`device.watermarks` 的 `last_backup_at` 只读
   `backup_watermark.updated_at`，这张表只由**遗留批量扫描路径**
   `backup.commit`（`crates/daemon/src/backup.rs:521 set_watermark`）写入。
   现在生产用的是 **Flow（offer/fetch）路径**
   （`crates/daemon/src/flow_delivery.rs::run_fetch_body`）——它会真的
   `ingest()` 落地资产，但从未调用 `set_watermark`。于是走 Flow 备份的
   设备水位表永远是空的，UI 与 `asset_count` 已增长的事实脱节。
2. 设备列表缺一列显示设备 ID。
3. 缺"打开该设备存储目录"的操作。
4. 在线状态原本塞在设备名下面一行的文案里，要求拆成独立的固定位置
   （视觉上像单独一列），不做成真表格（用户拍板：改动小，风格不变）。

## 期望行为 / 拍板记录（clarify 三问，2026-09-15）

- 第 1 条 bug：**现在一起修**，不单开卡、不留给用户想（用户明确选择）。
- 设备 ID 列：**8 位短指纹**（跟 `auditProjection.js` 的 `#xxxxxxx` 风格
  一致），鼠标悬停（`title` 原生 tooltip）看全量 64 位 hex。
- "移到单独一列"：**不做真表格**，保留现有卡片式列表，只把在线状态从
  行内文案挪到右侧固定宽度位置，视觉上像一列。

## 根因修复（第 1 条）

`crates/storage/src/device_repo.rs::list_device_watermarks` 原来只读
`backup_watermark` 左连接。改为同时读 `asset` 表按 `src_device` 分组的
`MAX(added_at)`（= 真实 ingest 落地时间，Flow 与遗留批量路径都会写这张
表），`last_backup_at` 取两个来源的较大值（`NULLIF(MAX(COALESCE(...,0),
COALESCE(...,0)), 0)`，避免 SQLite 多参 `MAX()` 遇 NULL 即整体 NULL 的
坑）。两个新增测试锁死这个语义：

- `watermark_falls_back_to_latest_asset_ingest_time_without_legacy_scan_row`：
  只有 Flow ingest（无 `backup_watermark` 行）时，`last_backup_at` 必须
  取 `asset.added_at` 的最大值，不能是 None。
- `watermark_prefers_the_more_recent_of_scan_and_ingest_times`：两个来源
  都存在时取较大者（旧扫描水位更新 / Flow 之后又落了一条新资产，两种
  顺序都要对）。

未改动：`backup_watermark` 表本身、`set_watermark`/`get_watermark`
（仍服务于 Android MediaStore generation 的服务端防重，与"展示口径"
是两件事，不混着改）；IPC 层 `device.watermarks` 响应形状不变。

## UI 改动（第 2/3/4 条）

`apps/desktop/src/App.svelte` 设备行（`page === "devices"`）：

- 新增设备 ID 列：`#{node_id.slice(0,8)}`，等宽字体，`title={node_id}`
  悬停看全量。
- 在线状态（原 `row.sub`）从设备名下面挪到固定宽度列（`w-[168px]`），
  与"最近备份"（`row.right`，`w-[140px]`）并排，视觉两列。
- 新增"打开文件夹"图标按钮（`FolderOpenIcon` + `revealItemInDir`），
  目标 `<library_dir>/originals/<node_id 全量 hex>/`——与 ingest 落位
  口径完全一致（`core-index/src/ingest.rs::device_dir`：node_id 字节逐位
  hex；`devices.list` 返回的 `node_id` 已经是同一份 hex 字符串）。该
  设备还没落过任何照片时目录不存在，退回打开 `originals/` 根目录，不
  假装有内容（与 `openLibrary()` 同一套退路模式）。

新增 i18n key（中英对称，`crates/diag/src/keys.rs` 注册表同步更新，
`ALL.len()` 断言 100→102）：`ui.device_open_folder`、
`ui.device_open_folder_failed`。

## 验收标准

- [x] RED 先行：`device_repo.rs` 两个新测试改前跑一个真红
      （`watermark_falls_back_to_latest_asset_ingest_time_without_legacy_scan_row`
      panic，实测日志见下）。
- [x] GREEN：`cargo test -p storage --lib device_repo` 11 passed / 0 failed。
- [x] `cargo test -p storage -p daemon`：98+32+... 全部通过（无回归）。
- [x] `cd apps/desktop && pnpm run build` 成功；`pnpm test`（vitest）
      10 files / 62 tests 全过。
- [x] `just ci` 全绿（含 `cargo fmt --check`、clippy `-D warnings`、
      nextest 全量、arch-check、queue-sync、diag i18n key 全量匹配）。
- [ ] 真机/真实多设备场景回归：至少一台已走 Flow 路径备份过的设备，
      桌面「家人与设备」页应显示真实"最近备份"时间而非"还没备份过"；
      验证 ID 列短指纹/悬停全量、打开文件夹按钮实际揭示该设备目录。

## 范围

- 只准动：`crates/storage/src/device_repo.rs`（`list_device_watermarks`
  SQL + 两个新测试）、`apps/desktop/src/App.svelte`（设备行渲染 +
  `openDeviceFolder`）、`assets/i18n/{zh,en}.json`（两个新 key）、
  `crates/diag/src/keys.rs`（注册表同步）。
- 不准动：`backup_watermark` 表结构、`set_watermark`/`get_watermark`
  语义、`device.watermarks` IPC 响应字段形状、`devices.list` 返回结构、
  改名/移除设备的既有逻辑。

## 阻塞与依赖

无前置。与 NET-06（Flow 202 异步化）并列但不冲突——本卡只改
`list_device_watermarks` 的读取来源，不涉及 Flow 交付状态机。

---

## 实施记录

- 2026-09-15：`cargo test -p storage --lib device_repo` 改前红：
  `thread 'device_repo::tests::watermark_falls_back_to_latest_asset_ingest_time_without_legacy_scan_row'
  panicked ... test result: FAILED. 10 passed; 1 failed`；改后绿：
  `test result: ok. 11 passed; 0 failed`。
- `cargo test -p storage -p daemon` 全绿（98 + 32 + 其余集成测试文件，
  均 0 failed）；`cargo test -p diag` 修复 key 注册表后 8 passed。
- `apps/desktop`：`pnpm run build` 成功（`vite build` 468 modules，
  已有的 a11y/state 警告为改动前既存，与本卡无关）；`pnpm test`
  10 files / 62 tests 全过。
- `just ci` 全绿：`cargo fmt --check` + clippy `-D warnings` + nextest
  全量 + arch-check（B.1/B.2）+ queue-sync + tokens 校验。
