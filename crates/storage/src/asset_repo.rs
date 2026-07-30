//! Asset repository: insert/get + cursor-paged timeline.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use sqlx::Row;

use crate::{Db, Result, StorageError};

/// One indexed photo/video. Mirrors the `asset` table (§5 v1.1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Asset {
    /// BLAKE3 content hash, 32 bytes (same domain as iroh-blobs).
    pub hash: Vec<u8>,
    /// Path relative to the library root, e.g. `originals/dev/2026/07/x.heic`.
    pub rel_path: String,
    pub media_type: String,
    pub bytes: i64,
    /// EXIF capture time, mtime fallback (unix ms). The timeline key.
    /// T-011's ingest always sets it; `None` only for degenerate rows.
    pub taken_at: Option<i64>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    /// Uploader NodeId (32 bytes).
    pub src_device: Vec<u8>,
    pub added_at: i64,
    /// 0 = pending, 1 = done, 2 = failed (placeholder thumb served).
    pub thumb_state: i64,
}

/// One timeline page, newest first.
#[derive(Debug)]
pub struct TimelinePage {
    pub assets: Vec<Asset>,
    /// Pass back to `timeline_page` for the next page; `None` = no more.
    pub next_cursor: Option<String>,
}

impl Db {
    /// Insert a new asset row. Duplicate hash is an error — dedup decisions
    /// (T-011) check `get_asset` first; a violation here means a logic bug.
    pub async fn insert_asset(&self, a: &Asset) -> Result<()> {
        sqlx::query(
            "INSERT INTO asset (hash, rel_path, media_type, bytes, taken_at, width, height,
                                src_device, added_at, thumb_state)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&a.hash)
        .bind(&a.rel_path)
        .bind(&a.media_type)
        .bind(a.bytes)
        .bind(a.taken_at)
        .bind(a.width)
        .bind(a.height)
        .bind(&a.src_device)
        .bind(a.added_at)
        .bind(a.thumb_state)
        .execute(self.pool())
        .await?;
        Ok(())
    }

    /// Wipe every asset row. Only the index rebuild (T-012, ADR-006) may
    /// call this — the table is derived data, re-scannable from `originals/`.
    pub async fn clear_assets(&self) -> Result<u64> {
        let done = sqlx::query("DELETE FROM asset")
            .execute(self.pool())
            .await?;
        Ok(done.rows_affected())
    }

    /// Record the thumbnail pipeline's verdict for one asset
    /// (0 pending / 1 done / 2 failed-placeholder, T-013/T-033).
    pub async fn set_thumb_state(&self, hash: &[u8], state: i64) -> Result<()> {
        sqlx::query("UPDATE asset SET thumb_state = ? WHERE hash = ?")
            .bind(state)
            .bind(hash)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    pub async fn get_asset(&self, hash: &[u8]) -> Result<Option<Asset>> {
        let row = sqlx::query(
            "SELECT hash, rel_path, media_type, bytes, taken_at, width, height,
                    src_device, added_at, thumb_state
             FROM asset WHERE hash = ?",
        )
        .bind(hash)
        .fetch_optional(self.pool())
        .await?;
        Ok(row.map(|r| asset_from_row(&r)))
    }

    /// Newest-first timeline, keyset-paged on the `(taken_at, hash)`
    /// composite key (契约). `cursor: None` = first page. `NULL taken_at`
    /// sorts as 0 (oldest); ties on `taken_at` break by ascending hash, so
    /// the order is total and pages never overlap or skip.
    pub async fn timeline_page(&self, cursor: Option<&str>, limit: u32) -> Result<TimelinePage> {
        let limit = limit.clamp(1, 1000);
        // Fetch limit+1 to learn whether another page exists without a
        // second query (and without ever handing out an empty last page).
        let probe = i64::from(limit) + 1;

        let rows = match cursor {
            None => {
                sqlx::query(
                    "SELECT hash, rel_path, media_type, bytes, taken_at, width, height,
                            src_device, added_at, thumb_state
                     FROM asset
                     ORDER BY COALESCE(taken_at, 0) DESC, hash ASC
                     LIMIT ?",
                )
                .bind(probe)
                .fetch_all(self.pool())
                .await?
            }
            Some(c) => {
                let (taken_at, hash) = decode_cursor(c)?;
                sqlx::query(
                    "SELECT hash, rel_path, media_type, bytes, taken_at, width, height,
                            src_device, added_at, thumb_state
                     FROM asset
                     WHERE COALESCE(taken_at, 0) < ?1
                        OR (COALESCE(taken_at, 0) = ?1 AND hash > ?2)
                     ORDER BY COALESCE(taken_at, 0) DESC, hash ASC
                     LIMIT ?3",
                )
                .bind(taken_at)
                .bind(hash.as_slice())
                .bind(probe)
                .fetch_all(self.pool())
                .await?
            }
        };

        let mut assets: Vec<Asset> = rows.iter().map(asset_from_row).collect();
        let next_cursor = if assets.len() > limit as usize {
            assets.truncate(limit as usize);
            let last = assets.last().expect("limit >= 1");
            Some(encode_cursor(last.taken_at.unwrap_or(0), &last.hash))
        } else {
            None
        };
        Ok(TimelinePage {
            assets,
            next_cursor,
        })
    }
}

fn asset_from_row(r: &sqlx::sqlite::SqliteRow) -> Asset {
    Asset {
        hash: r.get("hash"),
        rel_path: r.get("rel_path"),
        media_type: r.get("media_type"),
        bytes: r.get("bytes"),
        taken_at: r.get("taken_at"),
        width: r.get("width"),
        height: r.get("height"),
        src_device: r.get("src_device"),
        added_at: r.get("added_at"),
        thumb_state: r.get("thumb_state"),
    }
}

/// Cursor wire format: base64url(8-byte BE taken_at ++ 32-byte hash).
fn encode_cursor(taken_at: i64, hash: &[u8]) -> String {
    let mut buf = Vec::with_capacity(8 + hash.len());
    buf.extend_from_slice(&taken_at.to_be_bytes());
    buf.extend_from_slice(hash);
    URL_SAFE_NO_PAD.encode(buf)
}

fn decode_cursor(cursor: &str) -> Result<(i64, Vec<u8>)> {
    let bytes = URL_SAFE_NO_PAD
        .decode(cursor)
        .map_err(|_| StorageError::InvalidCursor)?;
    if bytes.len() != 8 + 32 {
        return Err(StorageError::InvalidCursor);
    }
    let taken_at = i64::from_be_bytes(bytes[..8].try_into().expect("8 bytes"));
    Ok((taken_at, bytes[8..].to_vec()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn asset(n: u8, taken_at: Option<i64>) -> Asset {
        Asset {
            hash: {
                let mut h = vec![0u8; 32];
                h[0] = n;
                h
            },
            rel_path: format!("originals/dev/2026/07/IMG_{n:03}.jpg"),
            media_type: "image/jpeg".into(),
            bytes: 1000 + i64::from(n),
            taken_at,
            width: Some(4032),
            height: Some(3024),
            src_device: vec![9u8; 32],
            added_at: 1_753_770_000_000,
            thumb_state: 0,
        }
    }

    #[tokio::test]
    async fn migration_runs_from_zero_and_tables_exist() {
        let db = Db::open_in_memory().await.expect("open + migrate");
        for table in [
            "asset",
            "device",
            "backup_watermark",
            "diag_event",
            "audit_log",
        ] {
            let n: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?",
            )
            .bind(table)
            .fetch_one(db.pool())
            .await
            .expect("query sqlite_master");
            assert_eq!(n, 1, "table {table} must exist after migration");
        }
    }

    #[tokio::test]
    async fn insert_get_roundtrip_and_duplicate_rejected() {
        let db = Db::open_in_memory().await.unwrap();
        let a = asset(1, Some(1_700_000_000_000));
        db.insert_asset(&a).await.expect("first insert");
        let back = db.get_asset(&a.hash).await.unwrap().expect("row exists");
        assert_eq!(back, a);
        assert!(
            db.insert_asset(&a).await.is_err(),
            "duplicate hash must be rejected by the PRIMARY KEY"
        );
        assert!(db.get_asset(&[0u8; 32]).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn timeline_pages_100_rows_no_dup_no_miss() {
        let db = Db::open_in_memory().await.unwrap();
        // 100 rows: shared taken_at values (hash tiebreak), one NULL.
        for n in 0..100u8 {
            let taken_at = match n {
                7 => None,
                _ => Some(1_700_000_000_000 + i64::from(n / 3) * 60_000),
            };
            db.insert_asset(&asset(n, taken_at)).await.unwrap();
        }

        let mut seen: Vec<Vec<u8>> = Vec::new();
        let mut cursor: Option<String> = None;
        let mut pages = 0;
        loop {
            let page = db.timeline_page(cursor.as_deref(), 7).await.unwrap();
            assert!(!page.assets.is_empty(), "no empty pages are handed out");
            seen.extend(page.assets.iter().map(|a| a.hash.clone()));
            pages += 1;
            assert!(pages <= 20, "runaway pagination");
            match page.next_cursor {
                Some(c) => cursor = Some(c),
                None => break,
            }
        }

        assert_eq!(seen.len(), 100, "no missed rows");
        let unique: std::collections::HashSet<_> = seen.iter().cloned().collect();
        assert_eq!(unique.len(), 100, "no duplicated rows");
        assert_eq!(pages, 15, "100 rows / 7 per page");
    }

    #[tokio::test]
    async fn timeline_order_is_newest_first_and_total() {
        let db = Db::open_in_memory().await.unwrap();
        for n in 0..20u8 {
            db.insert_asset(&asset(n, Some(1_700_000_000_000 + i64::from(n % 5))))
                .await
                .unwrap();
        }
        let page = db.timeline_page(None, 20).await.unwrap();
        let keys: Vec<(i64, Vec<u8>)> = page
            .assets
            .iter()
            .map(|a| (a.taken_at.unwrap_or(0), a.hash.clone()))
            .collect();
        let mut expected = keys.clone();
        // Newest first; ties broken by ascending hash.
        expected.sort_by(|(ta, ha), (tb, hb)| tb.cmp(ta).then(ha.cmp(hb)));
        assert_eq!(
            keys, expected,
            "ORDER BY must match (taken_at DESC, hash ASC)"
        );
    }

    #[tokio::test]
    async fn invalid_cursor_is_an_error_not_a_panic() {
        let db = Db::open_in_memory().await.unwrap();
        assert!(matches!(
            db.timeline_page(Some("not-a-cursor!!"), 10).await,
            Err(StorageError::InvalidCursor)
        ));
        assert!(matches!(
            db.timeline_page(Some("AAAA"), 10).await,
            Err(StorageError::InvalidCursor)
        ));
    }
}
