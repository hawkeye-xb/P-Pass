//! #1117：设备档案（永不删除）与配对记录（可物理删除）。
//!
//! 对齐 HomeKit / 蓝牙 / Matter 的 pairing list：长期公钥（NodeId）即身份，
//! 配对记录只存「对方公钥 + 权限」，解除配对 = 删除这一条；设备历史另存。
//!
//! - **档案** `device_profile`：名字、首次出现、最后在线、最近一次离开。审计
//!   与照片来源挂 NodeId，所以档案永不删除。
//! - **配对记录** `pairing`：断开、撤销、换身份时物理删除。它的 id 取代旧的
//!   pairing_epoch；备份水位与交付租约外键 `ON DELETE CASCADE` 挂在它上面，
//!   随它一起删（依赖每个连接都打开 `foreign_keys`，见 `db.rs`）。

use sqlx::Row;

use crate::{Db, Result, VaultAlignment};

/// Device role. #1050: `Owner` is retired — no code path ever created an
/// owner pairing (the owner acts through the desktop UI/IPC, not as a network
/// peer).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Member,
    Viewer,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Member => "member",
            Role::Viewer => "viewer",
        }
    }

    fn from_db(s: &str) -> Role {
        match s {
            "member" => Role::Member,
            // Least privilege for anything else.
            _ => Role::Viewer,
        }
    }
}

/// 配对记录为什么被删（记在档案上，决定列表怎么展示；审计另记）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DepartedBy {
    /// 手机侧点了「断开与这台电脑的连接」。
    Device,
    /// 业主在桌面点了「移除设备」。
    Owner,
    /// #1109：这台电脑换了身份，全部配对作废，手机需要重新扫码。
    Identity,
}

impl DepartedBy {
    pub fn as_str(self) -> &'static str {
        match self {
            DepartedBy::Device => "device",
            DepartedBy::Owner => "owner",
            DepartedBy::Identity => "identity",
        }
    }

    fn from_db(raw: Option<String>) -> Option<Self> {
        match raw.as_deref() {
            Some("device") => Some(DepartedBy::Device),
            Some("owner") => Some(DepartedBy::Owner),
            Some("identity") => Some(DepartedBy::Identity),
            _ => None,
        }
    }
}

/// 设备档案：它是谁。永不删除。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceProfile {
    /// 32-byte NodeId（手机长期公钥）。
    pub node_id: Vec<u8>,
    /// 当前名字（业主改名优先于手机自报，DEV-04）。
    pub name: String,
    /// 第一次配对成功的时间。
    pub first_seen_at: i64,
    /// 最后一次 hello（只在有配对记录时刷新）。
    pub last_seen_at: Option<i64>,
    /// 最近一次配对记录被删的时间与原因；重新配对时清空。
    pub departed_at: Option<i64>,
    pub departed_by: Option<DepartedBy>,
}

/// 配对记录：它现在凭什么能连。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pairing {
    /// 配对记录 id（线上字段 `pairing_id`）。
    pub id: String,
    pub node_id: Vec<u8>,
    pub role: Role,
    pub paired_at: i64,
}

/// 设备列表的一行：档案 + 当前配对记录（没有 = 未配对 / 已离开）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceRow {
    pub profile: DeviceProfile,
    pub pairing: Option<Pairing>,
}

const ROW_COLUMNS: &str = "d.node_id, d.name, d.first_seen_at, d.last_seen_at, d.departed_at, \
     d.departed_by, p.id AS pairing_id, p.role, p.paired_at";

fn row_to_device_row(r: &sqlx::sqlite::SqliteRow) -> DeviceRow {
    let node_id: Vec<u8> = r.get("node_id");
    let pairing_id: Option<String> = r.get("pairing_id");
    DeviceRow {
        pairing: pairing_id.map(|id| Pairing {
            id,
            node_id: node_id.clone(),
            role: Role::from_db(r.get("role")),
            paired_at: r.get("paired_at"),
        }),
        profile: DeviceProfile {
            node_id,
            name: r.get("name"),
            first_seen_at: r.get("first_seen_at"),
            last_seen_at: r.get("last_seen_at"),
            departed_at: r.get("departed_at"),
            departed_by: DepartedBy::from_db(r.get("departed_by")),
        },
    }
}

fn row_to_pairing(r: &sqlx::sqlite::SqliteRow) -> Pairing {
    Pairing {
        id: r.get("id"),
        node_id: r.get("node_id"),
        role: Role::from_db(r.get("role")),
        paired_at: r.get("paired_at"),
    }
}

impl Db {
    /// 配对落定，一个事务：
    /// - 档案不存在则以 `name` 建档；已存在则**保留原名**（业主改名优先，DEV-04）
    ///   并清掉 `departed_*`（这台设备回来了）。
    /// - 删掉它此前的配对记录（若有；连同挂在上面的水位与租约），插入新记录。
    ///   新记录拿新 id，旧 id 上的状态不被继承。
    pub async fn accept_pairing(
        &self,
        node_id: &[u8],
        name: &str,
        pairing: &Pairing,
    ) -> Result<()> {
        let _serial = self.pairing_write_guard().await;
        debug_assert_eq!(pairing.node_id, node_id);
        let mut tx = self.pool().begin().await?;
        sqlx::query(
            "INSERT INTO device_profile (node_id, name, first_seen_at)
             VALUES (?, ?, ?)
             ON CONFLICT(node_id) DO UPDATE SET departed_at = NULL, departed_by = NULL",
        )
        .bind(node_id)
        .bind(name)
        .bind(pairing.paired_at)
        .execute(&mut *tx)
        .await?;
        sqlx::query("DELETE FROM pairing WHERE node_id = ?")
            .bind(node_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("INSERT INTO pairing (id, node_id, role, paired_at) VALUES (?, ?, ?, ?)")
            .bind(&pairing.id)
            .bind(node_id)
            .bind(pairing.role.as_str())
            .bind(pairing.paired_at)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        // #1115：镜像行先落库（外键要它），再写正本；正本写不进去就撤掉镜像行，
        // 内存副本不动 ⇒ 没有授权。顺序与崩溃收敛见 pairing_vault.rs。
        if self.has_vault() {
            let p = pairing.clone();
            if let Err(e) = self.vault_call(move |v| v.insert(&p)).await {
                let _ = sqlx::query("DELETE FROM pairing WHERE id = ?")
                    .bind(&pairing.id)
                    .execute(self.pool())
                    .await;
                return Err(e);
            }
        }
        self.index_write().insert(node_id.to_vec(), pairing.clone());
        Ok(())
    }

    /// 删除这台设备的配对记录（水位、交付租约与回执级联删除），并在档案上记下
    /// 离开时间与原因。`expect_id` 给出时只删 id 一致的那条（#565：迟到的「我
    /// 断开了」不许删掉之后的新配对）。返回被删的记录；没有则 `None`、什么都不改。
    pub async fn remove_pairing(
        &self,
        node_id: &[u8],
        expect_id: Option<&str>,
        by: DepartedBy,
        at_ms: i64,
    ) -> Result<Option<Pairing>> {
        let _serial = self.pairing_write_guard().await;
        if self.has_vault() {
            // #1115：正本说了算——先看内存副本（= 正本）里有没有这一条，先删正本、
            // 立即撤掉授权，再收拾镜像。
            let Some(current) = self.active_pairing(node_id) else {
                return Ok(None);
            };
            if expect_id.is_some_and(|id| id != current.id) {
                return Ok(None);
            }
            let key = node_id.to_vec();
            self.vault_call(move |v| v.delete(&key)).await?;
            self.index_write().remove(node_id);
            let mut tx = self.pool().begin().await?;
            sqlx::query("DELETE FROM pairing WHERE node_id = ?")
                .bind(node_id)
                .execute(&mut *tx)
                .await?;
            sqlx::query(
                "UPDATE device_profile SET departed_at = ?, departed_by = ? WHERE node_id = ?",
            )
            .bind(at_ms)
            .bind(by.as_str())
            .bind(node_id)
            .execute(&mut *tx)
            .await?;
            tx.commit().await?;
            return Ok(Some(current));
        }
        let mut tx = self.pool().begin().await?;
        let removed = sqlx::query(
            "DELETE FROM pairing WHERE node_id = ?1 AND (?2 IS NULL OR id = ?2)
             RETURNING id, node_id, role, paired_at",
        )
        .bind(node_id)
        .bind(expect_id)
        .fetch_optional(&mut *tx)
        .await?
        .map(|r| row_to_pairing(&r));
        if removed.is_some() {
            sqlx::query(
                "UPDATE device_profile SET departed_at = ?, departed_by = ? WHERE node_id = ?",
            )
            .bind(at_ms)
            .bind(by.as_str())
            .bind(node_id)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        if removed.is_some() {
            self.index_write().remove(node_id);
        }
        Ok(removed)
    }

    /// 删除全部配对记录（#1109 换身份）。档案与审计保留，档案上记下离开原因。
    /// 一个事务：要么全删，要么都不动。返回被删的记录。
    pub async fn remove_all_pairings(&self, by: DepartedBy, at_ms: i64) -> Result<Vec<Pairing>> {
        let _serial = self.pairing_write_guard().await;
        // #1115：有正本时先清正本、立即撤掉全部授权，再收拾镜像。
        let from_vault = if self.has_vault() {
            let current: Vec<Pairing> = self
                .pairing_index()
                .read()
                .unwrap_or_else(|e| e.into_inner())
                .values()
                .cloned()
                .collect();
            self.vault_call(|v| v.delete_all()).await?;
            self.index_write().clear();
            Some(current)
        } else {
            None
        };
        let mut tx = self.pool().begin().await?;
        sqlx::query(
            "UPDATE device_profile SET departed_at = ?, departed_by = ?
             WHERE node_id IN (SELECT node_id FROM pairing)",
        )
        .bind(at_ms)
        .bind(by.as_str())
        .execute(&mut *tx)
        .await?;
        let removed = sqlx::query("DELETE FROM pairing RETURNING id, node_id, role, paired_at")
            .fetch_all(&mut *tx)
            .await?;
        tx.commit().await?;
        self.index_write().clear();
        Ok(from_vault.unwrap_or_else(|| removed.iter().map(row_to_pairing).collect()))
    }

    /// #1115：启动时以正本为准对齐镜像（单向）。见 `pairing_vault.rs`「启动对齐」。
    pub(crate) async fn align_mirror(&self, authority: &[Pairing]) -> Result<VaultAlignment> {
        let mirror = self.list_pairings().await?;
        let mut out = VaultAlignment::default();
        let mut tx = self.pool().begin().await?;
        for m in &mirror {
            let kept = authority
                .iter()
                .any(|a| a.node_id == m.node_id && a.id == m.id);
            if !kept {
                sqlx::query("DELETE FROM pairing WHERE id = ?")
                    .bind(&m.id)
                    .execute(&mut *tx)
                    .await?;
                out.removed_from_mirror
                    .push((m.node_id.clone(), m.id.clone()));
            }
        }
        for a in authority {
            let present = mirror
                .iter()
                .any(|m| m.node_id == a.node_id && m.id == a.id);
            if present {
                continue;
            }
            // 没有档案就建占位档案（名字未知；手机下次 hello 时显示名照常更新）。
            sqlx::query(
                "INSERT INTO device_profile (node_id, name, first_seen_at) VALUES (?, ?, ?)
                 ON CONFLICT(node_id) DO NOTHING",
            )
            .bind(&a.node_id)
            .bind("")
            .bind(a.paired_at)
            .execute(&mut *tx)
            .await?;
            sqlx::query("INSERT INTO pairing (id, node_id, role, paired_at) VALUES (?, ?, ?, ?)")
                .bind(&a.id)
                .bind(&a.node_id)
                .bind(a.role.as_str())
                .bind(a.paired_at)
                .execute(&mut *tx)
                .await?;
            out.restored_to_mirror
                .push((a.node_id.clone(), a.id.clone()));
        }
        tx.commit().await?;
        Ok(out)
    }

    /// 授权判定用：这台设备当前的配对记录，读内存副本，不查库。
    pub fn active_pairing(&self, node_id: &[u8]) -> Option<Pairing> {
        self.pairing_index()
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .get(node_id)
            .cloned()
    }

    fn index_write(
        &self,
    ) -> std::sync::RwLockWriteGuard<'_, std::collections::HashMap<Vec<u8>, Pairing>> {
        self.pairing_index()
            .write()
            .unwrap_or_else(|e| e.into_inner())
    }

    /// 全部有效配对记录——授权内存副本的加载源。
    pub async fn list_pairings(&self) -> Result<Vec<Pairing>> {
        let rows = sqlx::query("SELECT id, node_id, role, paired_at FROM pairing")
            .fetch_all(self.pool())
            .await?;
        Ok(rows.iter().map(row_to_pairing).collect())
    }

    /// 一台设备的档案与当前配对记录。
    pub async fn get_device(&self, node_id: &[u8]) -> Result<Option<DeviceRow>> {
        let row = sqlx::query(&format!(
            "SELECT {ROW_COLUMNS} FROM device_profile d
             LEFT JOIN pairing p ON p.node_id = d.node_id
             WHERE d.node_id = ?"
        ))
        .bind(node_id)
        .fetch_optional(self.pool())
        .await?;
        Ok(row.as_ref().map(row_to_device_row))
    }

    /// 全部档案（含已离开的），按首次出现排序。展示口径（哪些列在主列表）由
    /// daemon 的投影决定。
    pub async fn list_devices(&self) -> Result<Vec<DeviceRow>> {
        let rows = sqlx::query(&format!(
            "SELECT {ROW_COLUMNS} FROM device_profile d
             LEFT JOIN pairing p ON p.node_id = d.node_id
             ORDER BY d.first_seen_at ASC, d.node_id ASC"
        ))
        .fetch_all(self.pool())
        .await?;
        Ok(rows.iter().map(row_to_device_row).collect())
    }

    /// PRES-01：心跳落点。只刷新**有配对记录**的设备——已离开者的心跳不该
    /// 刷新任何展示。没有档案 / 没有配对 = 静默成功。
    pub async fn touch_last_seen(&self, node_id: &[u8], ts: i64) -> Result<()> {
        sqlx::query(
            "UPDATE device_profile SET last_seen_at = ?
             WHERE node_id = ? AND EXISTS (SELECT 1 FROM pairing WHERE node_id = ?)",
        )
        .bind(ts)
        .bind(node_id)
        .bind(node_id)
        .execute(self.pool())
        .await?;
        Ok(())
    }

    /// NAME-01：改显示名（档案上）。返回旧名供审计；没有档案 = `None`。
    pub async fn rename_device(&self, node_id: &[u8], new_name: &str) -> Result<Option<String>> {
        let old: Option<String> =
            sqlx::query_scalar("SELECT name FROM device_profile WHERE node_id = ?")
                .bind(node_id)
                .fetch_optional(self.pool())
                .await?;
        let Some(old_name) = old else {
            return Ok(None);
        };
        sqlx::query("UPDATE device_profile SET name = ? WHERE node_id = ?")
            .bind(new_name)
            .bind(node_id)
            .execute(self.pool())
            .await?;
        Ok(Some(old_name))
    }

    /// 推进一次配对的增量备份水位（`last_gen` = Android MediaStore generation）。
    pub async fn set_watermark(
        &self,
        pairing_id: &str,
        last_gen: i64,
        updated_at: i64,
    ) -> Result<()> {
        sqlx::query(
            "INSERT INTO backup_watermark (pairing_id, last_gen, updated_at)
             VALUES (?, ?, ?)
             ON CONFLICT(pairing_id) DO UPDATE SET
               last_gen = excluded.last_gen,
               updated_at = excluded.updated_at",
        )
        .bind(pairing_id)
        .bind(last_gen)
        .bind(updated_at)
        .execute(self.pool())
        .await?;
        Ok(())
    }

    pub async fn get_watermark(&self, pairing_id: &str) -> Result<Option<i64>> {
        let row = sqlx::query("SELECT last_gen FROM backup_watermark WHERE pairing_id = ?")
            .bind(pairing_id)
            .fetch_optional(self.pool())
            .await?;
        Ok(row.and_then(|r| r.get("last_gen")))
    }

    /// 已配对设备的备份水位视图（DOG-01）。NET-13：Flow 路径从不写水位表，只插
    /// asset 行，所以把每台设备的 `MAX(asset.added_at)` 一并折进来取较大者。
    pub async fn list_device_watermarks(&self) -> Result<Vec<DeviceWatermark>> {
        let rows = sqlx::query(
            "SELECT d.node_id, d.name,
                    NULLIF(MAX(COALESCE(w.updated_at, 0), COALESCE(la.last_added_at, 0)), 0)
                        AS last_backup_at,
                    COALESCE(la.asset_count, 0) AS asset_count
             FROM pairing p
             JOIN device_profile d ON d.node_id = p.node_id
             LEFT JOIN backup_watermark w ON w.pairing_id = p.id
             LEFT JOIN (
                 SELECT src_device, MAX(added_at) AS last_added_at, COUNT(*) AS asset_count
                 FROM asset
                 GROUP BY src_device
             ) la ON la.src_device = d.node_id
             ORDER BY d.first_seen_at ASC, d.node_id ASC",
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
    /// Last committed backup; None if the device never completed one.
    pub last_backup_at: Option<i64>,
    /// Assets this device contributed (asset.src_device count).
    pub asset_count: i64,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pairing(n: u8, id: &str, role: Role, at: i64) -> Pairing {
        Pairing {
            id: id.into(),
            node_id: vec![n; 32],
            role,
            paired_at: at,
        }
    }

    async fn pair(db: &Db, n: u8, id: &str) -> Pairing {
        let p = pairing(n, id, Role::Member, 1_000 + i64::from(n));
        db.accept_pairing(&p.node_id, &format!("device-{n}"), &p)
            .await
            .unwrap();
        p
    }

    async fn count(db: &Db, sql: &str) -> i64 {
        sqlx::query_scalar(sql).fetch_one(db.pool()).await.unwrap()
    }

    async fn seed_lease(db: &Db, pairing_id: &str) {
        sqlx::query(
            "INSERT INTO flow_delivery (pairing_id, queue_sequence, lease_token, content_hash,
               file_name, media_type, provider, state)
             VALUES (?, 1, 'l', x'00', 'a.jpg', 'image/jpeg', 'p', 'completed')",
        )
        .bind(pairing_id)
        .execute(db.pool())
        .await
        .unwrap();
    }

    /// #1115 防篡改：同一用户直接往库里插一行配对记录——当下不授权；重启后被对齐删掉。
    /// 这正是本卡要堵的攻击（库同用户可写）。
    /// 反证：授权读镜像、或启动从镜像加载 ⇒ 两处断言都红。
    #[tokio::test]
    async fn a_row_written_straight_into_the_library_never_authorizes() {
        let dir = tempfile::tempdir().unwrap();
        let vault = std::sync::Arc::new(crate::MemoryVault::default());
        let (db, _) = Db::open_with_vault(&dir.path().join("index.sqlite"), vault.clone())
            .await
            .unwrap();
        let evil = pairing(9, "evil", Role::Member, 0);
        sqlx::query("INSERT INTO device_profile (node_id, name, first_seen_at) VALUES (?, 'x', 0)")
            .bind(&evil.node_id)
            .execute(db.pool())
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO pairing (id, node_id, role, paired_at) VALUES ('evil', ?, 'member', 0)",
        )
        .bind(&evil.node_id)
        .execute(db.pool())
        .await
        .unwrap();
        assert_eq!(db.active_pairing(&evil.node_id), None, "运行中不认库里的行");
        drop(db);

        let (db, aligned) = Db::open_with_vault(&dir.path().join("index.sqlite"), vault.clone())
            .await
            .unwrap();
        assert_eq!(db.active_pairing(&evil.node_id), None, "重启后也不认");
        assert_eq!(
            aligned.removed_from_mirror,
            vec![(evil.node_id.clone(), "evil".to_string())]
        );
        assert!(db.list_pairings().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn accept_creates_profile_and_pairing() {
        let db = Db::open_in_memory().await.unwrap();
        let p = pair(&db, 1, "p1").await;
        let row = db.get_device(&[1u8; 32]).await.unwrap().unwrap();
        assert_eq!(row.pairing, Some(p));
        assert_eq!(row.profile.name, "device-1");
        assert_eq!(row.profile.first_seen_at, 1_001);
        assert_eq!(db.list_pairings().await.unwrap().len(), 1);
    }

    /// 删配对记录：水位与交付租约 / 回执级联删除，档案保留并记下离开原因。
    /// 反证：去掉 migration 里的 ON DELETE CASCADE（或 FK 开关），水位与租约
    /// 断言变红；去掉档案的 departed 更新，最后两条变红。
    #[tokio::test]
    async fn removing_a_pairing_cascades_transport_state_and_keeps_the_profile() {
        let db = Db::open_in_memory().await.unwrap();
        let p = pair(&db, 1, "p1").await;
        db.set_watermark(&p.id, 42, 5).await.unwrap();
        seed_lease(&db, &p.id).await;

        let removed = db
            .remove_pairing(&[1u8; 32], None, DepartedBy::Owner, 77)
            .await
            .unwrap();
        assert_eq!(removed, Some(p));
        assert_eq!(count(&db, "SELECT COUNT(*) FROM pairing").await, 0);
        assert_eq!(count(&db, "SELECT COUNT(*) FROM backup_watermark").await, 0);
        assert_eq!(count(&db, "SELECT COUNT(*) FROM flow_delivery").await, 0);
        let row = db.get_device(&[1u8; 32]).await.unwrap().unwrap();
        assert_eq!(row.pairing, None);
        assert_eq!(row.profile.departed_at, Some(77));
        assert_eq!(row.profile.departed_by, Some(DepartedBy::Owner));
    }

    /// #565：指定 id 时只删那一条；id 不符什么都不改。
    #[tokio::test]
    async fn removal_with_a_stale_id_changes_nothing() {
        let db = Db::open_in_memory().await.unwrap();
        pair(&db, 1, "old").await;
        let current = pair(&db, 1, "new").await;
        let removed = db
            .remove_pairing(&[1u8; 32], Some("old"), DepartedBy::Device, 9)
            .await
            .unwrap();
        assert_eq!(removed, None);
        let row = db.get_device(&[1u8; 32]).await.unwrap().unwrap();
        assert_eq!(row.pairing, Some(current));
        assert_eq!(row.profile.departed_by, None);
    }

    /// 重新配对：复用原档案（保留业主改的名字、清掉 departed），配对记录新建一行、
    /// 新 id；旧 id 上的水位与租约不被继承。
    /// 反证：accept_pairing 不删旧记录而是 UPDATE 原行沿用旧 id，水位断言变红；
    /// 不清 departed，departed 断言变红。
    #[tokio::test]
    async fn repairing_reuses_the_profile_with_a_fresh_pairing() {
        let db = Db::open_in_memory().await.unwrap();
        let old = pair(&db, 1, "p-old").await;
        db.rename_device(&[1u8; 32], "妈妈的手机").await.unwrap();
        db.set_watermark(&old.id, 42, 5).await.unwrap();
        seed_lease(&db, &old.id).await;
        db.remove_pairing(&[1u8; 32], None, DepartedBy::Device, 50)
            .await
            .unwrap();

        let new = pairing(1, "p-new", Role::Viewer, 2_000);
        db.accept_pairing(&new.node_id, "Pixel 8", &new)
            .await
            .unwrap();

        let row = db.get_device(&[1u8; 32]).await.unwrap().unwrap();
        assert_eq!(row.pairing, Some(new.clone()));
        assert_eq!(row.profile.name, "妈妈的手机", "业主改的名字优先");
        assert_eq!(row.profile.first_seen_at, 1_001, "首次出现不变");
        assert_eq!(row.profile.departed_at, None);
        assert_eq!(row.profile.departed_by, None);
        assert_eq!(count(&db, "SELECT COUNT(*) FROM device_profile").await, 1);
        assert_eq!(db.get_watermark(&new.id).await.unwrap(), None);
        assert_eq!(db.get_watermark(&old.id).await.unwrap(), None);
        assert_eq!(count(&db, "SELECT COUNT(*) FROM flow_delivery").await, 0);
    }

    /// 已配对时再次配对：旧记录（连同挂在上面的状态）被替换，不并存；当前记录
    /// 是新 id，旧 id 上的水位不被继承。
    /// 反证：accept_pairing 改成在原记录上 UPSERT（沿用旧 id），后三条断言变红。
    #[tokio::test]
    async fn accepting_while_paired_replaces_the_old_pairing() {
        let db = Db::open_in_memory().await.unwrap();
        let old = pair(&db, 1, "a").await;
        db.set_watermark(&old.id, 1, 1).await.unwrap();
        let new = pair(&db, 1, "b").await;
        assert_eq!(count(&db, "SELECT COUNT(*) FROM pairing").await, 1);
        assert_eq!(db.active_pairing(&[1u8; 32]), Some(new.clone()));
        assert_eq!(db.list_pairings().await.unwrap(), vec![new]);
        assert_eq!(count(&db, "SELECT COUNT(*) FROM backup_watermark").await, 0);
    }

    /// #1109：换身份删全部配对；档案全部保留并标 identity；审计表不动。
    /// 反证：remove_all_pairings 不写 departed，档案断言变红。
    #[tokio::test]
    async fn remove_all_keeps_every_profile_and_the_audit() {
        let db = Db::open_in_memory().await.unwrap();
        let a = pair(&db, 1, "a").await;
        pair(&db, 2, "b").await;
        db.set_watermark(&a.id, 1, 1).await.unwrap();
        let audit_before = count(&db, "SELECT COUNT(*) FROM audit_operation").await;

        let removed = db
            .remove_all_pairings(DepartedBy::Identity, 99)
            .await
            .unwrap();
        assert_eq!(removed.len(), 2);
        assert_eq!(count(&db, "SELECT COUNT(*) FROM pairing").await, 0);
        assert_eq!(count(&db, "SELECT COUNT(*) FROM backup_watermark").await, 0);
        let rows = db.list_devices().await.unwrap();
        assert_eq!(rows.len(), 2);
        assert!(rows
            .iter()
            .all(|r| r.profile.departed_by == Some(DepartedBy::Identity)));
        assert_eq!(
            count(&db, "SELECT COUNT(*) FROM audit_operation").await,
            audit_before
        );
        // 幂等：再来一次是 0 条、什么都不坏。
        assert!(db
            .remove_all_pairings(DepartedBy::Identity, 100)
            .await
            .unwrap()
            .is_empty());
    }

    /// 级联依赖每个连接都打开 foreign_keys（SQLite 按连接生效）。用一个**新开的**
    /// 文件库句柄（新连接池、新连接）删配对记录，水位与租约仍被级联删除。
    /// 反证：`db.rs` 去掉 `.foreign_keys(true)`，这里变红。
    #[tokio::test]
    async fn cascade_holds_on_a_freshly_opened_connection() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.sqlite");
        {
            let db = Db::open(&path).await.unwrap();
            let p = pair(&db, 1, "p1").await;
            db.set_watermark(&p.id, 42, 5).await.unwrap();
            seed_lease(&db, &p.id).await;
            db.pool().close().await;
        }
        let db = Db::open(&path).await.unwrap();
        let fk: i64 = sqlx::query_scalar("PRAGMA foreign_keys")
            .fetch_one(db.pool())
            .await
            .unwrap();
        assert_eq!(fk, 1, "新连接也必须打开 foreign_keys");
        db.remove_pairing(&[1u8; 32], None, DepartedBy::Owner, 1)
            .await
            .unwrap();
        assert_eq!(count(&db, "SELECT COUNT(*) FROM backup_watermark").await, 0);
        assert_eq!(count(&db, "SELECT COUNT(*) FROM flow_delivery").await, 0);
    }

    /// 授权内存副本跟着三个写方法走，重新打开库时从库加载。
    /// 反证：accept / remove 不更新副本，对应断言变红；open 不加载，最后一条变红。
    #[tokio::test]
    async fn the_in_memory_index_follows_every_write_and_reloads_on_open() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.sqlite");
        let db = Db::open(&path).await.unwrap();
        let clone = db.clone();
        let p1 = pair(&db, 1, "p1").await;
        pair(&db, 2, "p2").await;
        assert_eq!(
            clone.active_pairing(&[1u8; 32]),
            Some(p1.clone()),
            "克隆共享同一份"
        );
        db.remove_pairing(&[2u8; 32], None, DepartedBy::Owner, 1)
            .await
            .unwrap();
        assert_eq!(clone.active_pairing(&[2u8; 32]), None);
        db.pool().close().await;

        let reopened = Db::open(&path).await.unwrap();
        assert_eq!(reopened.active_pairing(&[1u8; 32]), Some(p1));
        reopened
            .remove_all_pairings(DepartedBy::Identity, 2)
            .await
            .unwrap();
        assert_eq!(reopened.active_pairing(&[1u8; 32]), None);
    }

    #[tokio::test]
    async fn last_seen_only_moves_while_paired() {
        let db = Db::open_in_memory().await.unwrap();
        pair(&db, 1, "p1").await;
        db.touch_last_seen(&[1u8; 32], 10).await.unwrap();
        db.remove_pairing(&[1u8; 32], None, DepartedBy::Device, 11)
            .await
            .unwrap();
        db.touch_last_seen(&[1u8; 32], 20).await.unwrap();
        db.touch_last_seen(&[9u8; 32], 20).await.unwrap();
        let row = db.get_device(&[1u8; 32]).await.unwrap().unwrap();
        assert_eq!(row.profile.last_seen_at, Some(10));
    }

    #[tokio::test]
    async fn rename_is_on_the_profile_and_unknown_is_none() {
        let db = Db::open_in_memory().await.unwrap();
        pair(&db, 1, "p1").await;
        assert_eq!(
            db.rename_device(&[1u8; 32], "x").await.unwrap().as_deref(),
            Some("device-1")
        );
        assert_eq!(db.rename_device(&[9u8; 32], "x").await.unwrap(), None);
    }

    #[tokio::test]
    async fn watermarks_list_only_paired_devices() {
        let db = Db::open_in_memory().await.unwrap();
        let a = pair(&db, 1, "a").await;
        pair(&db, 2, "b").await;
        db.set_watermark(&a.id, 7, 500).await.unwrap();
        db.remove_pairing(&[2u8; 32], None, DepartedBy::Owner, 1)
            .await
            .unwrap();
        let w = db.list_device_watermarks().await.unwrap();
        assert_eq!(w.len(), 1);
        assert_eq!(w[0].node_id, vec![1u8; 32]);
        assert_eq!(w[0].last_backup_at, Some(500));
        db.set_watermark(&a.id, 8, 600).await.unwrap();
        assert_eq!(db.get_watermark(&a.id).await.unwrap(), Some(8));
    }
}
