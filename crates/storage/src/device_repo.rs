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
            "SELECT node_id, name, role, paired_at, last_seen, revoked
             FROM device ORDER BY paired_at ASC"
        } else {
            "SELECT node_id, name, role, paired_at, last_seen, revoked
             FROM device WHERE revoked = 0 ORDER BY paired_at ASC"
        };
        let rows = sqlx::query(sql).fetch_all(self.pool()).await?;
        Ok(rows
            .iter()
            .map(|r| Device {
                node_id: r.get("node_id"),
                name: r.get("name"),
                role: Role::from_db(r.get("role")),
                paired_at: r.get("paired_at"),
                last_seen: r.get("last_seen"),
                revoked: r.get::<i64, _>("revoked") != 0,
            })
            .collect())
    }

    /// One device by NodeId — the authz checkpoint's lookup (T-030).
    pub async fn get_device(&self, node_id: &[u8]) -> Result<Option<Device>> {
        let row = sqlx::query(
            "SELECT node_id, name, role, paired_at, last_seen, revoked
             FROM device WHERE node_id = ?",
        )
        .bind(node_id)
        .fetch_optional(self.pool())
        .await?;
        Ok(row.map(|r| Device {
            node_id: r.get("node_id"),
            name: r.get("name"),
            role: Role::from_db(r.get("role")),
            paired_at: r.get("paired_at"),
            last_seen: r.get("last_seen"),
            revoked: r.get::<i64, _>("revoked") != 0,
        }))
    }

    /// Explicitly reinstate a revoked device — ONLY the pairing flow may
    /// call this (owner confirmation = renewed trust). `upsert_device`
    /// intentionally never clears the flag (防误触, T-010 test).
    pub async fn unrevoke(&self, node_id: &[u8]) -> Result<bool> {
        let res = sqlx::query("UPDATE device SET revoked = 0 WHERE node_id = ?")
            .bind(node_id)
            .execute(self.pool())
            .await?;
        Ok(res.rows_affected() > 0)
    }

    /// Mark a device revoked. Returns whether a row was affected.
    pub async fn revoke(&self, node_id: &[u8]) -> Result<bool> {
        let res = sqlx::query("UPDATE device SET revoked = 1 WHERE node_id = ?")
            .bind(node_id)
            .execute(self.pool())
            .await?;
        Ok(res.rows_affected() > 0)
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

        assert!(db.revoke(&[2u8; 32]).await.unwrap());
        let devices = db.list_devices(true).await.unwrap();
        let d2 = devices.iter().find(|d| d.node_id == vec![2u8; 32]).unwrap();
        assert!(d2.revoked, "revocation must be reflected in list_devices");
        let d1 = devices.iter().find(|d| d.node_id == vec![1u8; 32]).unwrap();
        assert!(!d1.revoked, "other devices stay untouched");

        assert!(!db.revoke(&[9u8; 32]).await.unwrap(), "unknown id: no rows");
    }

    #[tokio::test]
    async fn upsert_updates_but_never_unrevokes() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Member)).await.unwrap();
        db.revoke(&[1u8; 32]).await.unwrap();

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
        assert!(db.revoke(&[2u8; 32]).await.unwrap());

        // 默认（include_revoked=false）：只剩在用设备。
        let active = db.list_devices(false).await.unwrap();
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].node_id, vec![1u8; 32]);

        // include_revoked=true：全量（status/export_logs 等内部统计用）。
        let all = db.list_devices(true).await.unwrap();
        assert_eq!(all.len(), 2);
        assert!(all.iter().any(|d| d.revoked));
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
        db.revoke(&[1u8; 32]).await.unwrap();
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
        db.revoke(&[1u8; 32]).await.unwrap();

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
