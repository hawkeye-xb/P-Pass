//! #851: 用原图替换旧副本——索引侧的原子一步与别名查询。

use crate::{Asset, Db, Result};

/// 一次尚未换完文件的替换（见 migrations/0011）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingSwap {
    pub new_hash: Vec<u8>,
    pub rel_path: String,
    pub staged_path: String,
}

impl Db {
    /// 一个事务里：删旧行、插新行（同一个 rel_path）、记别名（并把指向旧指纹的旧别名改指新指纹）、
    /// 记一条待换文件。任何一步失败整体回滚，索引不会出现「旧行没了、新行没进来」。
    pub async fn supersede_asset(
        &self,
        old_hash: &[u8],
        new: &Asset,
        staged_path: &str,
        now_ms: i64,
    ) -> Result<()> {
        let mut tx = self.pool().begin().await?;
        sqlx::query("DELETE FROM asset WHERE hash = ?")
            .bind(old_hash)
            .execute(&mut *tx)
            .await?;
        sqlx::query(
            "INSERT INTO asset (hash, rel_path, media_type, bytes, taken_at, width, height,
                                src_device, added_at, thumb_state)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&new.hash)
        .bind(&new.rel_path)
        .bind(&new.media_type)
        .bind(new.bytes)
        .bind(new.taken_at)
        .bind(new.width)
        .bind(new.height)
        .bind(&new.src_device)
        .bind(new.added_at)
        .bind(new.thumb_state)
        .execute(&mut *tx)
        .await?;
        sqlx::query("UPDATE asset_alias SET new_hash = ? WHERE new_hash = ?")
            .bind(&new.hash)
            .bind(old_hash)
            .execute(&mut *tx)
            .await?;
        sqlx::query("INSERT OR REPLACE INTO asset_alias (old_hash, new_hash, superseded_at) VALUES (?, ?, ?)")
            .bind(old_hash)
            .bind(&new.hash)
            .bind(now_ms)
            .execute(&mut *tx)
            .await?;
        sqlx::query("INSERT OR REPLACE INTO asset_swap_pending (new_hash, rel_path, staged_path) VALUES (?, ?, ?)")
            .bind(&new.hash)
            .bind(&new.rel_path)
            .bind(staged_path)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(())
    }

    /// 这个指纹被替换成了哪个（没有替换过 = `None`）。
    pub async fn alias_target(&self, old_hash: &[u8]) -> Result<Option<Vec<u8>>> {
        let row: Option<(Vec<u8>,)> =
            sqlx::query_as("SELECT new_hash FROM asset_alias WHERE old_hash = ?")
                .bind(old_hash)
                .fetch_optional(self.pool())
                .await?;
        Ok(row.map(|r| r.0))
    }

    pub async fn pending_swaps(&self) -> Result<Vec<PendingSwap>> {
        let rows: Vec<(Vec<u8>, String, String)> =
            sqlx::query_as("SELECT new_hash, rel_path, staged_path FROM asset_swap_pending")
                .fetch_all(self.pool())
                .await?;
        Ok(rows
            .into_iter()
            .map(|(new_hash, rel_path, staged_path)| PendingSwap {
                new_hash,
                rel_path,
                staged_path,
            })
            .collect())
    }

    pub async fn clear_pending_swap(&self, new_hash: &[u8]) -> Result<()> {
        sqlx::query("DELETE FROM asset_swap_pending WHERE new_hash = ?")
            .bind(new_hash)
            .execute(self.pool())
            .await?;
        Ok(())
    }
}
