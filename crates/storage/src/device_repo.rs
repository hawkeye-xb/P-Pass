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

    /// All devices, including revoked ones (the roster UI shows both).
    pub async fn list_devices(&self) -> Result<Vec<Device>> {
        let rows = sqlx::query(
            "SELECT node_id, name, role, paired_at, last_seen, revoked
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
}
