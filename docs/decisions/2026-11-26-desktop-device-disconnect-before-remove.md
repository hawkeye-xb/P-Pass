# 桌面端设备管理：已配对设备先断开再允许移除

- 状态：已采纳（产品负责人 2026-11-26 拍板推荐方案）
- 日期：2026-11-26
- 关联：#2079、#1117、#1119、#1575、#1577

## 结论

桌面端「家人与设备」页将原有的单步「移除」拆分为「先断开 → 再移除」两阶段流转：对「已配对」分组的设备仅提供「断开」（经新增 IPC `device.disconnect` 与 Tauri 具名命令 `daemon_device_disconnect` 立即撤销配对授权、关闭连接并将档案记为 `DepartedBy::OwnerDisconnect`，转入「已断开」分组）；仅对处于「已断开」分组的设备提供「移除」（收紧 `device.revoke` 只受理未配对设备，将档案标记为 `DepartedBy::Owner` 进入 `Removal::Removed`）。

## 背景

1. **误触风险（#2079）**：当前 `apps/desktop/src/App.svelte` 对「已配对」与「已断开」两个分组渲染同一按钮 `t("ui.remove")` 并直接调用 `device.revoke`。用户在浏览已配对设备时若误点「移除」并确认，设备会直接被吊销配对并从主列表消失（`Removal::Removed`），缺少「先断开留档观察、确认不再需要后再移除」的缓冲台阶。
2. **既有状态机基础**：`#1117` 与 `#1577` 已建立设备档案（`device_profile`）与配对记录（`pairing`）分离模型，并支持「已断开」分组（`Removal::Disconnected`，原覆盖手机端主动断开 `DepartedBy::Device` 与电脑换身份 `DepartedBy::Identity`）。但 `device_profile.departed_by` 的 `CHECK` 约束仅有 `('device', 'owner', 'identity')`，且桌面端没有独立的主动断开路径。
3. **命中核心路径**：本改动涉及存储迁移与仓库（`+ crates/storage/**`）、解除配对核心模块（`+ crates/daemon/src/unpair.rs`）及桌面能力白名单（`+ apps/desktop/src-tauri/capabilities/**`），均在 `.github/core-paths.txt` 范围内，按流程须先合入已采纳 ADR，再实施代码改动。

## 决定

### 1. 存储层（`crates/storage`）

- **迁移 `0015_device_departed_owner_disconnect.sql`**：将 `device_profile.departed_by` 的 `CHECK` 约束扩展为 `('device', 'owner', 'identity', 'owner_disconnect')`。
  - 因 SQLite 不支持原地修改 `CHECK` 约束，采用「新建临时表 `device_profile_new` → 拷贝全部历史行 → `DROP TABLE device_profile` → `ALTER TABLE device_profile_new RENAME TO device_profile`」重建表，完整保留全部 `device_profile`、`pairing`、`backup_watermark`、`flow_delivery` 与 `asset` 数据及外键关系（不使用 `ALTER TABLE device_profile RENAME TO ...`，避免 SQLite 改写 `pairing(node_id)` 的外键指向；不改动 `pairing` 表，满足架构门禁 B.3）。
  - 因 `sqlx-sqlite` 的 `Migrate::apply` 始终在事务内执行迁移 SQL（而 SQLite 禁止在事务内开关 `PRAGMA foreign_keys`），在 `crates/storage/src/db.rs` 的 `run_migrations` 入口于迁移前在连接上执行 `PRAGMA foreign_keys = OFF`，调用 `MIGRATOR.run(&mut *conn)` 后立即无条件恢复 `PRAGMA foreign_keys = ON`。
- **模型枚举（`crates/storage/src/device_repo.rs`）**：`DepartedBy` 新增 `OwnerDisconnect` 变体，数据库与线上字符串映射为 `"owner_disconnect"`。

### 2. Daemon 业务与 IPC（`crates/daemon`）

- **分组投影（`crates/daemon/src/device_projection.rs`）**：`Removal::of` 将 `Some(DepartedBy::OwnerDisconnect)` 映射为 `Removal::Disconnected`，使其继续留在主列表「已断开」分组且计入 `status.disconnected_devices`，授权记录已删故 `paired = false`、`presence = "offline"`。
- **新增 IPC `device.disconnect`（`crates/daemon/src/ipc.rs`）**：
  - 校验 32 字节 hex `node_id`，调用唯一入口 `crate::unpair::remove_pairing(..., None, DepartedBy::OwnerDisconnect, (self.now)())`（立即删库里配对记录、级联清理水位与交付租约、更新内存授权索引、中断在途 Flow 拉取与备份会话、关闭订阅与 QUIC 连接）。
  - 返回 `Ok(Some(_))` 时：写入 `audit_operation`（`"device.disconnected"`）与 `audit_decision`（`decision_kind = "revoke_authorization"`，`causal_object_ref = node_id`），发射 `events::DEVICE_CHANGED` 与 `events::ACTIVITY_APPENDED`，返回 `{"disconnected": true}`。
  - 返回 `Ok(None)`（设备无配对记录或不存在）时：幂等返回 `{"disconnected": false}`，不覆盖已是 `Removed` 或 `Disconnected` 状态的 `departed_by` / `departed_at`。
- **收紧 IPC `device.revoke`（`crates/daemon/src/ipc.rs`）**：
  - 若目标设备仍持有有效配对（`row.pairing.is_some()` 或 `db.active_pairing` 命中），拒绝请求并返回 `RespError::new(Reason::BadRequest)`，绝不解除其配对或关闭连接。
  - 若设备档案不存在，返回 `{"revoked": false}`；若已为 `DepartedBy::Owner`，幂等返回 `{"revoked": true}`（不覆盖首次 `departed_at`）；若未配对且为其他离开原因（`Device` / `Identity` / `OwnerDisconnect` / `None`），通过 `Db::mark_departed` 记为 `DepartedBy::Owner`（条件 `WHERE node_id NOT IN (SELECT node_id FROM pairing)` 保证并发安全），在 `marked > 0` 时写 `audit_operation`（`"device.revoked"`）并发射 `DEVICE_CHANGED` 与 `ACTIVITY_APPENDED`，返回 `{"revoked": true}`。
- **鉴权面与审计登记**：`IpcClient::Shell` 放行 `device.disconnect`（`IpcClient::Daemon` 拒绝）；`relocating_dispatch` 与 `library_missing_dispatch` 同样以 `Reason::LibraryUnavailable` 拒绝 `device.disconnect`；`crates/daemon/src/audit_projection.rs` 将 `"device.disconnected"` 登记进 `USER_KINDS_WITH_COPY` 与 `DAEMON_WRITTEN_KINDS`。同步更新依赖实时断连行为的测试与冒烟脚本（`tools/dogfood-smoke.sh`、`tools/android-ctrl-smoke.sh`、`tools/win-smoke.ps1` 等）改用 `device.disconnect`。

### 3. 桌面壳与前端（`apps/desktop`、`crates/diag`、`docs/desktop`）

- **Tauri 具名命令与最小权限**：在 `apps/desktop/src-tauri/src/daemon_api.rs` 新增 `daemon_device_disconnect`（转发 `"device.disconnect"`），同步登记到 `apps/desktop/src-tauri/build.rs`（`APP_COMMANDS`）、`apps/desktop/src-tauri/src/lib.rs`（`generate_handler!`）、`apps/desktop/src-tauri/capabilities/default.json`（`"allow-daemon-device-disconnect"`）及 `apps/desktop/src/lib/daemonApi.js`（`"device.disconnect": "daemon_device_disconnect"`）。
- **界面交互与文案**：
  - `apps/desktop/src/App.svelte`：在 `group.key === "paired"` 的设备行渲染「断开」（`t("ui.disconnect")`，`aria-label` 带设备名）并触发 `disconnectDevice` 确认弹窗后调用 `device.disconnect`；仅在非 `paired`（「已断开」）分组行渲染「移除」（`t("ui.remove")`）并触发 `revoke` 确认弹窗后调用 `device.revoke`。
  - 区分两套确认弹窗与提示文案：`ui.disconnect_confirm_title` / `ui.disconnect_confirm_body` 说明断开后立即失去访问权限并移入「已断开」分组；`ui.revoke_confirm_body` 改为准确说明从设备列表移除且保留已备份照片与记录（不再误称「立即失去访问权限」）；更新 `ui.devices_footnote`、`apps/desktop/src/auditProjection.js`（`"device.disconnected"` → `ui.audit_disconnected`），所有新增/调整的 `ui.*` 键同步录入 `apps/desktop/src/i18n/{zh,en}.json` 并在 `crates/diag/src/keys.rs` 注册。
  - 同步更新 `docs/desktop/business-rules.zh-CN.md` §2.5 与 §2.7 描述。

## 理由

- **本质保证**：将「立即终止网络授权（断开）」与「从主列表归档隐去（移除）」在状态机与 IPC 契约层彻底拆开，确保在线设备只能先被安全降级至「已断开」留档核查，既能第一时间阻断备份与访问，又防止误点一步抹去设备在线索列表中的存在；同时服务端 `device.revoke` 拒绝对已配对设备直接生效，使防误操作约束不仅停留在界面层。
- **标准做法对齐**：遵循 SQLite 官方重建表改约束流程（不改写父表引用名、事务外切换 `foreign_keys`）、既有 `unpair::remove_pairing` 单一解除配对入口（#1117 / #1119）以及 Tauri v2 逐命令具名 capability ACL 最小权限模型（#1120）。

## 后果

- **正面**：桌面端已配对设备无法被单步直接移除，断开与移除各有清晰的确认语义、状态归属与活动审计记录（`device.disconnected` / `device.revoked`）。
- **代价与兼容**：
  - 新增 SQLite 迁移 `0015` 后，旧版二进制无法打开已迁移库（符合既有 `is_schema_newer_than_binary` 策略）；
  - 既有冒烟脚本或外部测试若曾直接对已配对设备调用 `device.revoke` 测断连，须改调 `device.disconnect`（`device.revoke` 仅用于已断开设备的移除归档）。

## 备选

- **仅在前端隐藏「已配对」行的移除按钮、复用 `device.revoke` 或在 `devices.list` 加开关**：不采纳。若后端 `device.revoke` 仍接受已配对设备，则 IPC 契约与界面语义分裂，无法在接口层防止误吊销；若仅改 `device.revoke` 行为为先断开再移除（靠前端调用两次同一方法），则会让同一 IPC 方法在不同状态呈现不同语义，破坏幂等性与审计可读性。
