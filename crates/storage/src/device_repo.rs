//! Device repository: pairing roster, revocation, backup watermarks.

use sqlx::Row;

use crate::{Db, Result};

/// Device role (§5 CHECK constraint mirrors this enum).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Owner,
    Member,
    Viewer,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Owner => "owner",
            Role::Member => "member",
            Role::Viewer => "viewer",
        }
    }

    fn from_db(s: &str) -> Role {
        match s {
            "owner" => Role::Owner,
            "member" => Role::Member,
            // The CHECK constraint admits exactly three values; anything
            // else cannot have been inserted through this repo.
            _ => Role::Viewer,
        }
    }
}

/// One paired device. Mirrors the `device` table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    /// 32-byte NodeId.
    pub node_id: Vec<u8>,
    pub name: String,
    pub role: Role,
    pub paired_at: i64,
    pub last_seen: Option<i64>,
    pub revoked: bool,
    /// DEV-03：被吊销的时刻；未吊销为 None。
    pub revoked_at: Option<i64>,
    /// DEV-03：**谁**让它离开的。区分这两者是本卡的全部意义——
    /// 设备自己断开该留在列表里标「已断开」，业主主动移除才该消失。
    pub revoked_by: Option<RevokedBy>,
}

/// DEV-03：设备离开的两种方式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RevokedBy {
    /// 手机侧点了「断开与这台电脑的连接」。
    Device,
    /// 业主在桌面点了「移除设备」。
    Owner,
}

impl RevokedBy {
    pub fn as_str(self) -> &'static str {
        match self {
            RevokedBy::Device => "device",
            RevokedBy::Owner => "owner",
        }
    }

    /// 历史行没有来源信息（本列是 DEV-03 才加的）。读不出来就当业主移除——
    /// 保守方向：宁可让一台老设备不出现在列表里，也不要凭空冒出来一台
    /// 业主早就移除掉的。
    fn from_db(raw: Option<String>) -> Option<Self> {
        match raw.as_deref() {
            Some("device") => Some(RevokedBy::Device),
            Some("owner") => Some(RevokedBy::Owner),
            Some(_) | None => None,
        }
    }
}

/// 两处列表查询共用一份行映射——分两份写，下次加列必然漏一处。
fn row_to_device(r: &sqlx::sqlite::SqliteRow) -> Device {
    Device {
        node_id: r.get("node_id"),
        name: r.get("name"),
        role: Role::from_db(r.get("role")),
        paired_at: r.get("paired_at"),
        last_seen: r.get("last_seen"),
        revoked: r.get::<i64, _>("revoked") != 0,
        revoked_at: r.get("revoked_at"),
        revoked_by: RevokedBy::from_db(r.get("revoked_by")),
    }
}

impl Db {
    /// Insert or update a device (re-pairing refreshes name/role and
    /// clears nothing — revocation is only ever set via [`Db::revoke`]).
    pub async fn upsert_device(&self, d: &Device) -> Result<()> {
        sqlx::query(
            "INSERT INTO device (node_id, name, role, paired_at, last_seen, revoked)
             VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT(node_id) DO UPDATE SET
               name = excluded.name,
               role = excluded.role,
               last_seen = excluded.last_seen",
        )
        .bind(&d.node_id)
        .bind(&d.name)
        .bind(d.role.as_str())
        .bind(d.paired_at)
        .bind(d.last_seen)
        .bind(i64::from(d.revoked))
        .execute(self.pool())
        .await?;
        Ok(())
    }

    /// PRES-01: 心跳落点——更新设备 last_seen（revoked 设备不碰，
    /// 被吊销者的心跳不该刷新任何展示）。无行 = 未配对/未知设备，
    /// 静默成功（hello 对未配对节点本就允许，不产生副作用）。
    pub async fn touch_last_seen(&self, node_id: &[u8], ts: i64) -> Result<()> {
        sqlx::query("UPDATE device SET last_seen = ? WHERE node_id = ? AND revoked = 0")
            .bind(ts)
            .bind(node_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    /// DESK-02②: 默认过滤已吊销/移除设备——列表只展示在用设备
    /// （审计流有 device.revoked/unpaired 历史可查）。内部统计
    /// （status.devices/revoked、export_logs）传 include_revoked=true。
    pub async fn list_devices(&self, include_revoked: bool) -> Result<Vec<Device>> {
        let sql = if include_revoked {
            "SELECT node_id, name, role, paired_at, last_seen, revoked, revoked_at, revoked_by
             FROM device ORDER BY paired_at ASC"
        } else {
            "SELECT node_id, name, role, paired_at, last_seen, revoked, revoked_at, revoked_by
             FROM device WHERE revoked = 0 ORDER BY paired_at ASC"
        };
        let rows = sqlx::query(sql).fetch_all(self.pool()).await?;
        Ok(rows.iter().map(row_to_device).collect())
    }

    /// One device by NodeId — the authz checkpoint's lookup (T-030).
    pub async fn get_device(&self, node_id: &[u8]) -> Result<Option<Device>> {
        let row = sqlx::query(
            "SELECT node_id, name, role, paired_at, last_seen, revoked, revoked_at, revoked_by
             FROM device WHERE node_id = ?",
        )
        .bind(node_id)
        .fetch_optional(self.pool())
        .await?;
        Ok(row.as_ref().map(row_to_device))
    }

    /// Explicitly reinstate a revoked device — ONLY the pairing flow may
    /// call this (owner confirmation = renewed trust). `upsert_device`
    /// intentionally never clears the flag (防误触, T-010 test).
    pub async fn unrevoke(&self, node_id: &[u8]) -> Result<bool> {
        // DEV-03：复位 revoked 时一并清掉来源——否则一台「曾被业主移除、
        // 现已重新授权」的设备会一直带着 revoked_by='owner'，下次它自己
        // 断开时又会从列表里消失。
        let res = sqlx::query(
            "UPDATE device SET revoked = 0, revoked_at = NULL, revoked_by = NULL WHERE node_id = ?",
        )
        .bind(node_id)
        .execute(self.pool())
        .await?;
        Ok(res.rows_affected() > 0)
    }

    /// Mark a device revoked. Returns whether a row was affected.
    /// DEV-03：吊销必须记下**是谁干的**和**什么时候**。
    ///
    /// 只写 `revoked = 1` 的旧写法让「手机自己断开」和「业主移除」在事后
    /// 无从分辨，于是「家人与设备」只能一刀切过滤，手机一断开设备就凭空
    /// 消失——业主看不到它什么时候断的，设备改过名时更无从确认是哪一台。
    pub async fn revoke(&self, node_id: &[u8], by: RevokedBy, at_ms: i64) -> Result<bool> {
        let res = sqlx::query(
            "UPDATE device SET revoked = 1, revoked_at = ?, revoked_by = ? WHERE node_id = ?",
        )
        .bind(at_ms)
        .bind(by.as_str())
        .bind(node_id)
        .execute(self.pool())
        .await?;
        Ok(res.rows_affected() > 0)
    }

    /// DEV-03：从审计流回填历史吊销行的来源。
    ///
    /// 与 migration `0008` 里那段 SQL 是同一份判据——提成方法是为了能被
    /// 测试直接调用（迁移只跑一次，没法在单测里重放）。
    ///
    /// `device.unpaired` 的 actor 是**设备自己**（`router.handle_unpair`
    /// 记的是 peer），`device.revoked` 的 actor 是 NULL（业主经本机 IPC
    /// 操作）。所以只认前者。查不到记录的保持 NULL，展示层按「业主移除」
    /// 处理。
    pub async fn backfill_revocation_provenance(&self) -> Result<u64> {
        let res = sqlx::query(
            "UPDATE device
             SET revoked_by = 'device',
                 revoked_at = (
                   SELECT MAX(occurred_at) FROM audit_operation
                   WHERE kind = 'device.unpaired' AND actor = device.node_id
                 )
             WHERE revoked = 1
               AND revoked_by IS NULL
               AND EXISTS (
                 SELECT 1 FROM audit_operation
                 WHERE kind = 'device.unpaired' AND actor = device.node_id
               )",
        )
        .execute(self.pool())
        .await?;
        Ok(res.rows_affected())
    }

    /// DEV-03：「家人与设备」的列表口径。
    ///
    /// - 在用的：列
    /// - **设备自己断开的：列**，标「已断开」——它不是业主的意图，业主有权
    ///   知道这台什么时候断的、是哪一台（可能被改过名）
    /// - 业主主动移除的：**不列**——那正是业主的意图，不该再摆在眼前
    ///
    /// 来源未知的历史行按「业主移除」处理（保守方向，见 [`RevokedBy::from_db`]）。
    pub async fn list_devices_for_family_view(&self) -> Result<Vec<Device>> {
        let rows = sqlx::query(
            "SELECT node_id, name, role, paired_at, last_seen, revoked, revoked_at, revoked_by
             FROM device
             WHERE revoked = 0 OR revoked_by = 'device'
             ORDER BY paired_at ASC",
        )
        .fetch_all(self.pool())
        .await?;
        Ok(rows.iter().map(row_to_device).collect())
    }

    /// NAME-01: 改显示名（ID 与显示名分离——decisions ②）。返回旧名，
    /// 供调用方写审计（device.renamed 旧名→新名）。设备不存在 = 无行
    /// 受影响 → None（IPC 层答 NOT_FOUND 语义）。
    pub async fn rename_device(&self, node_id: &[u8], new_name: &str) -> Result<Option<String>> {
        // 先取旧名——UPDATE 本身不返回旧值。
        let old: Option<String> = sqlx::query_scalar("SELECT name FROM device WHERE node_id = ?")
            .bind(node_id)
            .fetch_optional(self.pool())
            .await?;
        let Some(old_name) = old else {
            return Ok(None);
        };
        sqlx::query("UPDATE device SET name = ? WHERE node_id = ?")
            .bind(new_name)
            .bind(node_id)
            .execute(self.pool())
            .await?;
        Ok(Some(old_name))
    }

    /// Advance a device's incremental-backup watermark (server-side
    /// dedup guard; `last_gen` = Android MediaStore generation).
    pub async fn set_watermark(
        &self,
        node_id: &[u8],
        last_gen: i64,
        updated_at: i64,
    ) -> Result<()> {
        sqlx::query(
            "INSERT INTO backup_watermark (node_id, last_gen, updated_at)
             VALUES (?, ?, ?)
             ON CONFLICT(node_id) DO UPDATE SET
               last_gen = excluded.last_gen,
               updated_at = excluded.updated_at",
        )
        .bind(node_id)
        .bind(last_gen)
        .bind(updated_at)
        .execute(self.pool())
        .await?;
        Ok(())
    }

    pub async fn get_watermark(&self, node_id: &[u8]) -> Result<Option<i64>> {
        let row = sqlx::query("SELECT last_gen FROM backup_watermark WHERE node_id = ?")
            .bind(node_id)
            .fetch_optional(self.pool())
            .await?;
        Ok(row.and_then(|r| r.get("last_gen")))
    }

    /// Per-device backup watermarks for non-revoked devices (DOG-01):
    /// `ipc device.watermarks` data source — dogfood daily reports, desktop
    /// activity log, phone-side "last success" all read the same table.
    pub async fn list_device_watermarks(&self) -> Result<Vec<DeviceWatermark>> {
        // NET-13: `backup_watermark.updated_at` is written only by the
        // legacy batch-scan path (`backup.commit` → `set_watermark`,
        // `crates/daemon/src/backup.rs`). The Flow delivery path
        // (`flow_delivery.rs::run_fetch_body`) never touches that table —
        // it only inserts an `asset` row. A device that only ever backed up
        // via Flow therefore had `last_backup_at = NULL` forever, and the
        // desktop showed "从未备份过" even while `asset_count` kept
        // climbing. Fold in `MAX(asset.added_at)` per device (real ingest
        // fact, works for both paths) and take the greater of the two
        // sources so a still-newer legacy scan timestamp is never
        // regressed by an older asset row.
        let rows = sqlx::query(
            "SELECT d.node_id, d.name,
                    NULLIF(MAX(COALESCE(w.updated_at, 0), COALESCE(la.last_added_at, 0)), 0)
                        AS last_backup_at,
                    COALESCE(la.asset_count, 0) AS asset_count
             FROM device d
             LEFT JOIN backup_watermark w ON w.node_id = d.node_id
             LEFT JOIN (
                 SELECT src_device, MAX(added_at) AS last_added_at, COUNT(*) AS asset_count
                 FROM asset
                 GROUP BY src_device
             ) la ON la.src_device = d.node_id
             WHERE d.revoked = 0
             ORDER BY d.paired_at ASC",
        )
        .fetch_all(self.pool())
        .await?;
        Ok(rows
            .iter()
            .map(|r| DeviceWatermark {
                node_id: r.get("node_id"),
                name: r.get("name"),
                last_backup_at: r.get("last_backup_at"),
                asset_count: r.get("asset_count"),
            })
            .collect())
    }
}

/// One row of the DOG-01 per-device watermark view.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceWatermark {
    pub node_id: Vec<u8>,
    pub name: String,
    /// Last committed backup (backup_watermark.updated_at); None if the
    /// device never completed one.
    pub last_backup_at: Option<i64>,
    /// Assets this device contributed (asset.src_device count).
    pub asset_count: i64,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device(n: u8, role: Role) -> Device {
        Device {
            node_id: vec![n; 32],
            name: format!("device-{n}"),
            role,
            paired_at: 1_753_770_000_000 + i64::from(n),
            last_seen: None,
            revoked: false,
            revoked_at: None,
            revoked_by: None,
        }
    }

    #[tokio::test]
    async fn upsert_list_and_revoke_is_reflected() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Owner)).await.unwrap();
        db.upsert_device(&device(2, Role::Viewer)).await.unwrap();

        let devices = db.list_devices(true).await.unwrap();
        assert_eq!(devices.len(), 2);
        assert!(devices.iter().all(|d| !d.revoked));

        assert!(db
            .revoke(&[2u8; 32], RevokedBy::Owner, 1_700_000_000_000)
            .await
            .unwrap());
        let devices = db.list_devices(true).await.unwrap();
        let d2 = devices.iter().find(|d| d.node_id == vec![2u8; 32]).unwrap();
        assert!(d2.revoked, "revocation must be reflected in list_devices");
        let d1 = devices.iter().find(|d| d.node_id == vec![1u8; 32]).unwrap();
        assert!(!d1.revoked, "other devices stay untouched");

        assert!(
            !db.revoke(&[9u8; 32], RevokedBy::Owner, 1_700_000_000_000)
                .await
                .unwrap(),
            "unknown id: no rows"
        );
    }

    #[tokio::test]
    async fn upsert_updates_but_never_unrevokes() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Member)).await.unwrap();
        db.revoke(&[1u8; 32], RevokedBy::Owner, 1_700_000_000_000)
            .await
            .unwrap();

        // Re-pair attempt with revoked=false must NOT clear the flag.
        let mut again = device(1, Role::Member);
        again.name = "renamed".into();
        db.upsert_device(&again).await.unwrap();

        let devices = db.list_devices(true).await.unwrap();
        assert_eq!(devices[0].name, "renamed");
        assert!(devices[0].revoked, "upsert must not silently un-revoke");
    }

    #[tokio::test]
    async fn list_devices_filters_revoked_by_default() {
        // DESK-02②: 家人与设备列表只展示在用设备——被移除/吊销的设备
        // 不再挂着（审计流有 device.revoked/unpaired 历史可查）。
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Owner)).await.unwrap();
        db.upsert_device(&device(2, Role::Viewer)).await.unwrap();
        assert!(db
            .revoke(&[2u8; 32], RevokedBy::Owner, 1_700_000_000_000)
            .await
            .unwrap());

        // 默认（include_revoked=false）：只剩在用设备。
        let active = db.list_devices(false).await.unwrap();
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].node_id, vec![1u8; 32]);

        // include_revoked=true：全量（status/export_logs 等内部统计用）。
        let all = db.list_devices(true).await.unwrap();
        assert_eq!(all.len(), 2);
        assert!(all.iter().any(|d| d.revoked));
    }

    /// DEV-03：两种离开方式必须分得开，且「家人与设备」口径按此分流。
    ///
    /// 旧实现两条路都只写 `revoked = 1`，于是列表只能一刀切按
    /// `WHERE revoked = 0` 过滤——手机一断开设备就从列表凭空消失。
    #[tokio::test]
    async fn the_family_view_keeps_self_disconnected_devices_and_hides_owner_removed_ones() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Owner)).await.unwrap();
        db.upsert_device(&device(2, Role::Member)).await.unwrap();
        db.upsert_device(&device(3, Role::Member)).await.unwrap();

        // 手机自己断开。
        assert!(db
            .revoke(&[2u8; 32], RevokedBy::Device, 1_700_000_000_000)
            .await
            .unwrap());
        // 业主主动移除。
        assert!(db
            .revoke(&[3u8; 32], RevokedBy::Owner, 1_700_000_001_000)
            .await
            .unwrap());

        let view = db.list_devices_for_family_view().await.unwrap();
        let ids: Vec<_> = view.iter().map(|d| d.node_id[0]).collect();
        assert_eq!(
            ids,
            vec![1, 2],
            "在用的 + 自己断开的要在列表里；业主移除的不该在"
        );

        let disconnected = view.iter().find(|d| d.node_id[0] == 2).unwrap();
        assert!(disconnected.revoked, "它确实是断开状态，不是在用");
        assert_eq!(disconnected.revoked_by, Some(RevokedBy::Device));
        assert_eq!(
            disconnected.revoked_at,
            Some(1_700_000_000_000),
            "业主要能答「它什么时候断的」"
        );

        // 全量口径不变：诊断/统计仍看得到被移除的那台。
        assert_eq!(db.list_devices(true).await.unwrap().len(), 3);
    }

    /// DEV-03：升级迁移要从审计流回填历史吊销行的来源。
    ///
    /// 不回填的话，升级前就已断开的设备要等到「下次重连」或「下次再断一遍」
    /// 才会正确出现——而这正是本卡要修的症状，等于让用户再忍一轮。
    /// （本机那台 SM-S9210 升级后就正好落在这个处境里。）
    #[tokio::test]
    async fn the_migration_backfills_provenance_from_the_audit_trail() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Member)).await.unwrap();
        db.upsert_device(&device(2, Role::Member)).await.unwrap();
        // 一台自己断开过（审计里有 device.unpaired，actor = 它自己）。
        db.append_audit(&crate::AuditEntry::local(
            1_700_000_005_000,
            Some(vec![1u8; 32]),
            "device.unpaired",
            None,
            None,
        ))
        .await
        .unwrap();
        // 模拟「迁移之前就已吊销」：只写位，不带来源。
        for n in [1u8, 2] {
            sqlx::query("UPDATE device SET revoked = 1 WHERE node_id = ?")
                .bind(vec![n; 32])
                .execute(db.pool())
                .await
                .unwrap();
        }

        assert_eq!(db.backfill_revocation_provenance().await.unwrap(), 1);

        let one = db.get_device(&[1u8; 32]).await.unwrap().unwrap();
        assert_eq!(
            one.revoked_by,
            Some(RevokedBy::Device),
            "审计里有自我断开记录就该回填成 device"
        );
        assert_eq!(one.revoked_at, Some(1_700_000_005_000), "断开时刻也要回填");

        let two = db.get_device(&[2u8; 32]).await.unwrap().unwrap();
        assert_eq!(two.revoked_by, None, "查不到记录的保持未知");

        let view = db.list_devices_for_family_view().await.unwrap();
        assert_eq!(view.len(), 1, "回填之后，自己断开的那台才出现在列表里");
        assert_eq!(view[0].node_id[0], 1);
    }

    /// DEV-03：来源未知的历史行（本列是 DEV-03 才加的）按「业主移除」处理。
    /// 保守方向——宁可让一台老设备不出现，也不要凭空冒出一台业主早就移除的。
    #[tokio::test]
    async fn a_legacy_revoked_row_without_provenance_stays_hidden() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Member)).await.unwrap();
        sqlx::query("UPDATE device SET revoked = 1 WHERE node_id = ?")
            .bind(vec![1u8; 32])
            .execute(db.pool())
            .await
            .unwrap();

        assert!(db.list_devices_for_family_view().await.unwrap().is_empty());
        let all = db.list_devices(true).await.unwrap();
        assert_eq!(all[0].revoked_by, None, "历史行读出来没有来源");
    }

    /// DEV-03：重新授权必须把吊销痕迹清干净。
    ///
    /// 不清的话，一台「曾被业主移除、现已重新授权」的设备会一直带着
    /// `revoked_by='owner'`，下次它**自己**断开时又会从列表里消失。
    #[tokio::test]
    async fn reinstating_a_device_clears_its_revocation_provenance() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Member)).await.unwrap();
        db.revoke(&[1u8; 32], RevokedBy::Owner, 1_700_000_000_000)
            .await
            .unwrap();

        db.unrevoke(&[1u8; 32]).await.unwrap();

        let d = db.get_device(&[1u8; 32]).await.unwrap().unwrap();
        assert!(!d.revoked);
        assert_eq!(d.revoked_by, None, "痕迹没清干净");
        assert_eq!(d.revoked_at, None, "痕迹没清干净");

        // 复位之后它自己断开，应当留在列表里。
        db.revoke(&[1u8; 32], RevokedBy::Device, 1_700_000_002_000)
            .await
            .unwrap();
        assert_eq!(db.list_devices_for_family_view().await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn rename_updates_name_and_returns_old() {
        // NAME-01: 改名返回旧名（audit 用），devices.list 出新名；
        // 未知设备 = None（NOT_FOUND 语义）。
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Member)).await.unwrap();

        let old = db.rename_device(&[1u8; 32], "爸爸的手机").await.unwrap();
        assert_eq!(old.as_deref(), Some("device-1"));

        let devices = db.list_devices(false).await.unwrap();
        assert_eq!(devices[0].name, "爸爸的手机");
        // ID 不变——改名只动显示名（decisions ②：一切逻辑仍按 node_id）。
        assert_eq!(devices[0].node_id, vec![1u8; 32]);

        assert_eq!(
            db.rename_device(&[9u8; 32], "幽灵").await.unwrap(),
            None,
            "unknown id: None",
        );
    }

    #[tokio::test]
    async fn watermark_roundtrip_and_advance() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Owner)).await.unwrap();

        assert_eq!(db.get_watermark(&[1u8; 32]).await.unwrap(), None);
        db.set_watermark(&[1u8; 32], 100, 1_753_770_000_000)
            .await
            .unwrap();
        assert_eq!(db.get_watermark(&[1u8; 32]).await.unwrap(), Some(100));
        db.set_watermark(&[1u8; 32], 250, 1_753_770_100_000)
            .await
            .unwrap();
        assert_eq!(db.get_watermark(&[1u8; 32]).await.unwrap(), Some(250));
    }

    // ── DOG-01: per-device watermark view ──
    fn asset(src: &[u8], hash_byte: u8) -> crate::asset_repo::Asset {
        crate::asset_repo::Asset {
            hash: vec![hash_byte; 32],
            rel_path: format!("originals/{hash_byte:02x}.jpg"),
            media_type: "image/jpeg".into(),
            bytes: 100,
            taken_at: Some(1),
            width: None,
            height: None,
            src_device: src.to_vec(),
            added_at: 1,
            thumb_state: 0,
        }
    }

    #[tokio::test]
    async fn watermarks_report_name_time_and_asset_count() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Member)).await.unwrap();
        db.upsert_device(&device(2, Role::Member)).await.unwrap();
        db.set_watermark(&[1u8; 32], 500, 1_753_770_500_000)
            .await
            .unwrap();
        // 设备 1 贡献 3 个资产；设备 2 还没备份过（无水位、无资产）。
        db.insert_asset(&asset(&[1u8; 32], 1)).await.unwrap();
        db.insert_asset(&asset(&[1u8; 32], 2)).await.unwrap();
        db.insert_asset(&asset(&[1u8; 32], 3)).await.unwrap();

        let wm = db.list_device_watermarks().await.unwrap();
        assert_eq!(wm.len(), 2, "revoked=0 设备都要列出");
        let d1 = wm.iter().find(|w| w.node_id == [1u8; 32]).unwrap();
        assert_eq!(d1.name, "device-1");
        assert_eq!(d1.last_backup_at, Some(1_753_770_500_000));
        assert_eq!(d1.asset_count, 3);
        let d2 = wm.iter().find(|w| w.node_id == [2u8; 32]).unwrap();
        assert_eq!(d2.last_backup_at, None);
        assert_eq!(d2.asset_count, 0);
    }

    /// NET-13 RED: Flow 交付路径（flow_delivery.rs::run_fetch_body）从不
    /// 调用 `set_watermark`——那是遗留批量扫描口径（Android MediaStore
    /// generation），Flow 路径只会真的 `ingest()` 一条 asset 行。改前
    /// `last_backup_at` 对这种设备永远是 None，desktop 显示「还没备份
    /// 过」，即便 asset_count 已经在涨——用户明确报告的状态不对就是这个。
    /// 水位应取 `backup_watermark.updated_at` 与该设备最新 `asset.added_at`
    /// 两者较大值，不能只认前者。
    #[tokio::test]
    async fn watermark_falls_back_to_latest_asset_ingest_time_without_legacy_scan_row() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Member)).await.unwrap();
        // 没有调用 set_watermark——模拟纯 Flow 路径设备：从未跑过旧批量扫描。
        let mut a = asset(&[1u8; 32], 1);
        a.added_at = 1_800_000_000_000;
        db.insert_asset(&a).await.unwrap();

        let wm = db.list_device_watermarks().await.unwrap();
        let d1 = wm.iter().find(|w| w.node_id == [1u8; 32]).unwrap();
        assert_eq!(
            d1.last_backup_at,
            Some(1_800_000_000_000),
            "Flow 路径入库的资产必须让设备显示已备份，不能因为没有旧扫描水位行就报 None"
        );
        assert_eq!(d1.asset_count, 1);
    }

    /// 两个来源都存在时取较大值——旧扫描水位比最新资产还新（例如刚跑完一次
    /// 空扫描更新了 generation，但没有新照片）时不能倒退成更旧的资产时间。
    #[tokio::test]
    async fn watermark_prefers_the_more_recent_of_scan_and_ingest_times() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Member)).await.unwrap();
        db.set_watermark(&[1u8; 32], 500, 2_000_000_000_000)
            .await
            .unwrap();
        let mut a = asset(&[1u8; 32], 1);
        a.added_at = 1_000_000_000_000; // 早于扫描水位
        db.insert_asset(&a).await.unwrap();

        let wm = db.list_device_watermarks().await.unwrap();
        let d1 = wm.iter().find(|w| w.node_id == [1u8; 32]).unwrap();
        assert_eq!(d1.last_backup_at, Some(2_000_000_000_000));
    }

    #[tokio::test]
    async fn revoked_device_is_excluded_from_watermarks() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Member)).await.unwrap();
        db.revoke(&[1u8; 32], RevokedBy::Owner, 1_700_000_000_000)
            .await
            .unwrap();
        db.insert_asset(&asset(&[1u8; 32], 9)).await.unwrap();

        let wm = db.list_device_watermarks().await.unwrap();
        assert!(wm.is_empty(), "revoked 设备不出现");
    }

    // ── DEV-02: 设备与身份 1:1 ──

    /// 同一个 NodeId 回来 = 同一行复用（正面证据）。DEV-02 删掉「替换旧
    /// 身份」之后，「重装后续上旧账目」这件事不再存在；剩下的唯一续接
    /// 语义就是这一条——密钥没变，行就没变，备份水位留在原处。
    #[tokio::test]
    async fn re_upserting_the_same_node_id_reuses_one_row_and_keeps_the_watermark() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Member)).await.unwrap();
        db.set_watermark(&[1u8; 32], 300, 1_000).await.unwrap();
        db.revoke(&[1u8; 32], RevokedBy::Owner, 1_700_000_000_000)
            .await
            .unwrap();

        // 重新配对：名字可能改过（「妈妈的手机」），身份没变。
        let mut renamed = device(1, Role::Member);
        renamed.name = "妈妈的手机".into();
        db.upsert_device(&renamed).await.unwrap();
        // upsert 故意不清吊销位——只有配对流程有权恢复信任。
        assert!(db.get_device(&[1u8; 32]).await.unwrap().unwrap().revoked);
        assert!(db.unrevoke(&[1u8; 32]).await.unwrap());

        let all = db.list_devices(true).await.unwrap();
        assert_eq!(all.len(), 1, "同一个 NodeId 不得生出第二行：{all:?}");
        assert_eq!(all[0].name, "妈妈的手机");
        assert!(!all[0].revoked);
        assert_eq!(
            db.get_watermark(&[1u8; 32]).await.unwrap(),
            Some(300),
            "水位留在原处 = 照片不重传",
        );
    }
}
