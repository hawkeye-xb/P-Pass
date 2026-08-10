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
    /// DEV-01: reinstall fingerprint (SHA-256(Build.MODEL+ANDROID_ID)
    /// first 8 bytes hex). None = pre-DEV-01 client / hint disabled.
    pub device_hint: Option<String>,
}

impl Db {
    /// Insert or update a device (re-pairing refreshes name/role and
    /// clears nothing — revocation is only ever set via [`Db::revoke`]).
    pub async fn upsert_device(&self, d: &Device) -> Result<()> {
        sqlx::query(
            "INSERT INTO device (node_id, name, role, paired_at, last_seen, revoked, device_hint)
             VALUES (?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(node_id) DO UPDATE SET
               name = excluded.name,
               role = excluded.role,
               last_seen = excluded.last_seen,
               device_hint = excluded.device_hint",
        )
        .bind(&d.node_id)
        .bind(&d.name)
        .bind(d.role.as_str())
        .bind(d.paired_at)
        .bind(d.last_seen)
        .bind(i64::from(d.revoked))
        .bind(&d.device_hint)
        .execute(self.pool())
        .await?;
        Ok(())
    }

    /// All devices, including revoked ones (the roster UI shows both).
    pub async fn list_devices(&self) -> Result<Vec<Device>> {
        let rows = sqlx::query(
            "SELECT node_id, name, role, paired_at, last_seen, revoked, device_hint
             FROM device ORDER BY paired_at ASC",
        )
        .fetch_all(self.pool())
        .await?;
        Ok(rows
            .iter()
            .map(|r| Device {
                node_id: r.get("node_id"),
                name: r.get("name"),
                role: Role::from_db(r.get("role")),
                paired_at: r.get("paired_at"),
                last_seen: r.get("last_seen"),
                revoked: r.get::<i64, _>("revoked") != 0,
                device_hint: r.get("device_hint"),
            })
            .collect())
    }

    /// One device by NodeId — the authz checkpoint's lookup (T-030).
    pub async fn get_device(&self, node_id: &[u8]) -> Result<Option<Device>> {
        let row = sqlx::query(
            "SELECT node_id, name, role, paired_at, last_seen, revoked, device_hint
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
            device_hint: r.get("device_hint"),
        }))
    }

    /// DEV-01: devices sharing a reinstall hint, excluding the given
    /// NodeId and revoked rows — the "replace the old device" candidate
    /// set for a fresh pairing with the same phone.
    pub async fn find_by_hint(&self, hint: &str, exclude: &[u8]) -> Result<Vec<Device>> {
        let rows = sqlx::query(
            "SELECT node_id, name, role, paired_at, last_seen, revoked, device_hint
             FROM device
             WHERE device_hint = ? AND node_id != ? AND revoked = 0
             ORDER BY paired_at ASC",
        )
        .bind(hint)
        .bind(exclude)
        .fetch_all(self.pool())
        .await?;
        Ok(rows
            .iter()
            .map(|r| Device {
                node_id: r.get("node_id"),
                name: r.get("name"),
                role: Role::from_db(r.get("role")),
                paired_at: r.get("paired_at"),
                last_seen: r.get("last_seen"),
                revoked: r.get::<i64, _>("revoked") != 0,
                device_hint: r.get("device_hint"),
            })
            .collect())
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

    /// DEV-01: merge an old device's data into a fresh pairing (owner
    /// chose "替换旧的" in the confirm dialog). Moves asset ownership,
    /// keeps the max backup watermark, then deletes the old row.
    /// Returns the old device's name (for the audit trail).
    pub async fn merge_device(&self, old: &[u8], new: &[u8]) -> Result<String> {
        let old_name: Option<String> =
            sqlx::query_scalar("SELECT name FROM device WHERE node_id = ?")
                .bind(old)
                .fetch_optional(self.pool())
                .await?;
        // Assets the old device uploaded now belong to the new identity.
        sqlx::query("UPDATE asset SET src_device = ? WHERE src_device = ?")
            .bind(new)
            .bind(old)
            .execute(self.pool())
            .await?;
        // Watermark: keep the max of both (the new row may already carry
        // a watermark if the device re-paired in between).
        let old_wm: Option<i64> =
            sqlx::query_scalar("SELECT last_gen FROM backup_watermark WHERE node_id = ?")
                .bind(old)
                .fetch_optional(self.pool())
                .await?;
        let new_wm: Option<i64> =
            sqlx::query_scalar("SELECT last_gen FROM backup_watermark WHERE node_id = ?")
                .bind(new)
                .fetch_optional(self.pool())
                .await?;
        if let Some(wm) = old_wm {
            let merged = new_wm.map_or(wm, |n| n.max(wm));
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            sqlx::query(
                "INSERT INTO backup_watermark (node_id, last_gen, updated_at)
                 VALUES (?, ?, ?)
                 ON CONFLICT(node_id) DO UPDATE SET
                   last_gen = excluded.last_gen,
                   updated_at = excluded.updated_at",
            )
            .bind(new)
            .bind(merged)
            .bind(now)
            .execute(self.pool())
            .await?;
        }
        // Old identity is gone — a hello from it must now be rejected.
        sqlx::query("DELETE FROM backup_watermark WHERE node_id = ?")
            .bind(old)
            .execute(self.pool())
            .await?;
        sqlx::query("DELETE FROM device WHERE node_id = ?")
            .bind(old)
            .execute(self.pool())
            .await?;
        Ok(old_name.unwrap_or_else(|| "未知设备".into()))
    }

    /// Mark a device revoked. Returns whether a row was affected.
    pub async fn revoke(&self, node_id: &[u8]) -> Result<bool> {
        let res = sqlx::query("UPDATE device SET revoked = 1 WHERE node_id = ?")
            .bind(node_id)
            .execute(self.pool())
            .await?;
        Ok(res.rows_affected() > 0)
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
        let rows = sqlx::query(
            "SELECT d.node_id, d.name, w.updated_at,
                    (SELECT COUNT(*) FROM asset a WHERE a.src_device = d.node_id) AS asset_count
             FROM device d
             LEFT JOIN backup_watermark w ON w.node_id = d.node_id
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
                last_backup_at: r.get("updated_at"),
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
            device_hint: None,
        }
    }

    #[tokio::test]
    async fn upsert_list_and_revoke_is_reflected() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Owner)).await.unwrap();
        db.upsert_device(&device(2, Role::Viewer)).await.unwrap();

        let devices = db.list_devices().await.unwrap();
        assert_eq!(devices.len(), 2);
        assert!(devices.iter().all(|d| !d.revoked));

        assert!(db.revoke(&[2u8; 32]).await.unwrap());
        let devices = db.list_devices().await.unwrap();
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

        let devices = db.list_devices().await.unwrap();
        assert_eq!(devices[0].name, "renamed");
        assert!(devices[0].revoked, "upsert must not silently un-revoke");
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

    #[tokio::test]
    async fn revoked_device_is_excluded_from_watermarks() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&device(1, Role::Member)).await.unwrap();
        db.revoke(&[1u8; 32]).await.unwrap();
        db.insert_asset(&asset(&[1u8; 32], 9)).await.unwrap();

        let wm = db.list_device_watermarks().await.unwrap();
        assert!(wm.is_empty(), "revoked 设备不出现");
    }

    // ── DEV-01: reinstall hint + merge ──

    fn hinted(n: u8, hint: &str) -> Device {
        let mut d = device(n, Role::Member);
        d.device_hint = Some(hint.into());
        d
    }

    #[tokio::test]
    async fn find_by_hint_matches_active_only_and_excludes_self() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&hinted(1, "abc")).await.unwrap();
        db.upsert_device(&hinted(2, "def")).await.unwrap();
        // Same hint but revoked — must not surface as a merge candidate.
        let mut revoked = hinted(3, "abc");
        db.upsert_device(&revoked).await.unwrap();
        db.revoke(&[3u8; 32]).await.unwrap();

        let hits = db.find_by_hint("abc", &[1u8; 32]).await.unwrap();
        assert!(hits.is_empty(), "exclude=self + revoked excluded");

        let hits = db.find_by_hint("abc", &[9u8; 32]).await.unwrap();
        assert_eq!(hits.len(), 1, "only the active same-hint device");
        assert_eq!(hits[0].node_id, vec![1u8; 32]);
    }

    #[tokio::test]
    async fn merge_moves_assets_takes_max_watermark_and_removes_old() {
        let db = Db::open_in_memory().await.unwrap();
        db.upsert_device(&hinted(1, "abc")).await.unwrap(); // old
        db.upsert_device(&hinted(2, "abc")).await.unwrap(); // new
                                                            // Old contributed assets + watermark 300; new has watermark 100.
        db.insert_asset(&asset(&[1u8; 32], 1)).await.unwrap();
        db.insert_asset(&asset(&[1u8; 32], 2)).await.unwrap();
        db.set_watermark(&[1u8; 32], 300, 1_000).await.unwrap();
        db.set_watermark(&[2u8; 32], 100, 1_000).await.unwrap();

        let name = db.merge_device(&[1u8; 32], &[2u8; 32]).await.unwrap();
        assert_eq!(name, "device-1");

        // Assets re-owned by the new identity.
        let count = db.count_assets().await.unwrap();
        assert_eq!(count, 2);
        let rows = sqlx::query("SELECT src_device FROM asset")
            .fetch_all(db.pool())
            .await
            .unwrap();
        assert!(
            rows.iter()
                .all(|r| r.get::<Vec<u8>, _>("src_device") == vec![2u8; 32]),
            "all assets now belong to the new NodeId"
        );
        // Watermark = max(300, 100).
        assert_eq!(db.get_watermark(&[2u8; 32]).await.unwrap(), Some(300));
        // Old identity gone — hello from it must be rejected downstream.
        assert!(db.get_device(&[1u8; 32]).await.unwrap().is_none());
        assert!(db.get_watermark(&[1u8; 32]).await.unwrap().is_none());
    }
}
