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

/// One backup-activity batch (T-090 `activity.list`): a run of assets
/// from one device whose arrival times never gap past the window.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivityBatch {
    /// Uploader NodeId (32 bytes).
    pub node_id: Vec<u8>,
    /// Device display name; `None` when the uploader is not (or no
    /// longer) in the device roster.
    pub name: Option<String>,
    /// Batch timestamp = newest `added_at` inside the batch (unix ms).
    pub at: i64,
    pub asset_count: i64,
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

    /// All (hash, rel_path) pairs — SYNC-01 启动对账的数据源：磁盘 ↔ 索引
    /// diff 靠它枚举索引侧全集（不需要完整 Asset，省内存）。
    pub async fn list_asset_paths(&self) -> Result<Vec<(Vec<u8>, String)>> {
        let rows = sqlx::query("SELECT hash, rel_path FROM asset")
            .fetch_all(self.pool())
            .await?;
        Ok(rows
            .iter()
            .map(|r| (r.get("hash"), r.get("rel_path")))
            .collect())
    }

    /// Remove one asset row — SYNC-01 外部删除对账（索引是派生数据，
    /// 磁盘文件没了，行就没有存在意义）。
    pub async fn delete_asset(&self, hash: &[u8]) -> Result<u64> {
        Ok(sqlx::query("DELETE FROM asset WHERE hash = ?")
            .bind(hash)
            .execute(self.pool())
            .await?
            .rows_affected())
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

    /// Total number of indexed assets — `status.photo_count` (T-090).
    /// Read-only; the count is over the whole library regardless of
    /// which device contributed the asset.
    pub async fn count_assets(&self) -> Result<i64> {
        Ok(sqlx::query_scalar("SELECT COUNT(*) FROM asset")
            .fetch_one(self.pool())
            .await?)
    }

    /// Backup activity batches, newest first (T-090 `activity.list`).
    /// Read-only aggregation over the existing `asset` table — no new
    /// tables, no write path.
    ///
    /// 聚合口径（与 IPC 契约一致，改动需双方同步）：
    /// - 时间基准是 `added_at`（资产落库时刻）——activity 回答的是
    ///   “备份什么时候发生”，不是照片拍摄时间（`taken_at`）。
    /// - 批次 = 同一 `src_device` 内按 `added_at` 升序排列后，相邻
    ///   间隔 ≤ `gap_ms` 的连续段；间隔 > `gap_ms` 即断开为新批次。
    ///   （SQL 里用 LAG 标记断点，再前缀和编号；断点判定用严格大于，
    ///   所以 `gap_ms = 0` 时相同时间戳仍同批、任何递增即断批。）
    /// - 批次时间 `at` = 段内最大 `added_at`；结果按 `at` 倒序，
    ///   同刻按 `src_device` 升序保证输出确定。
    /// - 设备名 LEFT JOIN 自 `device` 表；不在名册的上传者名为 NULL。
    pub async fn list_activity(&self, gap_ms: i64, limit: u32) -> Result<Vec<ActivityBatch>> {
        let limit = i64::from(limit.clamp(1, 1000));
        let rows = sqlx::query(
            "WITH flagged AS (
               SELECT src_device, added_at,
                      CASE WHEN LAG(added_at) OVER w IS NULL
                             OR added_at - LAG(added_at) OVER w > ?1
                           THEN 1 ELSE 0 END AS is_new
               FROM asset
               WINDOW w AS (PARTITION BY src_device ORDER BY added_at)
             ),
             batched AS (
               -- Default RANGE frame on purpose: added_at ties are peers
               -- and must land in the same batch regardless of LAG's
               -- (arbitrary) ordering among them.
               SELECT src_device, added_at,
                      SUM(is_new) OVER (PARTITION BY src_device
                                        ORDER BY added_at) AS batch_no
               FROM flagged
             )
             SELECT b.src_device, d.name, MAX(b.added_at) AS at,
                    COUNT(*) AS asset_count
             FROM batched b LEFT JOIN device d ON d.node_id = b.src_device
             GROUP BY b.src_device, b.batch_no
             ORDER BY at DESC, b.src_device ASC
             LIMIT ?2",
        )
        .bind(gap_ms)
        .bind(limit)
        .fetch_all(self.pool())
        .await?;
        Ok(rows
            .iter()
            .map(|r| ActivityBatch {
                node_id: r.get("src_device"),
                name: r.get("name"),
                at: r.get("at"),
                asset_count: r.get("asset_count"),
            })
            .collect())
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

    // ── T-090: photo_count + activity aggregation ──

    fn asset_at(src: u8, hash_byte: u8, added_at: i64) -> Asset {
        let mut a = asset(hash_byte, Some(added_at));
        a.src_device = vec![src; 32];
        a.added_at = added_at;
        a
    }

    #[tokio::test]
    async fn count_assets_matches_rows() {
        let db = Db::open_in_memory().await.unwrap();
        assert_eq!(db.count_assets().await.unwrap(), 0);
        for n in 0..5u8 {
            db.insert_asset(&asset(n, Some(1))).await.unwrap();
        }
        assert_eq!(db.count_assets().await.unwrap(), 5);
    }

    #[tokio::test]
    async fn activity_batches_split_on_gap_and_partition_by_device() {
        let db = Db::open_in_memory().await.unwrap();
        let t0 = 1_700_000_000_000i64;
        let min = 60_000i64;
        // Device 1: three assets 1 min apart (one batch), then two more
        // after a 30-min silence (second batch).
        db.insert_asset(&asset_at(1, 1, t0)).await.unwrap();
        db.insert_asset(&asset_at(1, 2, t0 + min)).await.unwrap();
        db.insert_asset(&asset_at(1, 3, t0 + 2 * min))
            .await
            .unwrap();
        db.insert_asset(&asset_at(1, 4, t0 + 32 * min))
            .await
            .unwrap();
        db.insert_asset(&asset_at(1, 5, t0 + 33 * min))
            .await
            .unwrap();
        // Device 2: one asset inside device 1's first window — still its
        // own batch (partitioned per device).
        db.insert_asset(&asset_at(2, 6, t0 + min)).await.unwrap();

        let gap = 10 * min;
        let batches = db.list_activity(gap, 50).await.unwrap();
        assert_eq!(batches.len(), 3, "two device-1 batches + one device-2");
        // Newest first: d1 batch2 (t0+33m), d1 batch1 (t0+2m), d2 (t0+1m).
        assert_eq!(batches[0].node_id, vec![1u8; 32]);
        assert_eq!(batches[0].at, t0 + 33 * min);
        assert_eq!(batches[0].asset_count, 2);
        assert_eq!(batches[1].node_id, vec![1u8; 32]);
        assert_eq!(batches[1].at, t0 + 2 * min);
        assert_eq!(batches[1].asset_count, 3);
        assert_eq!(batches[2].node_id, vec![2u8; 32]);
        assert_eq!(batches[2].asset_count, 1);
        // Uploader not in the device roster → name is NULL, batch stays.
        assert_eq!(batches[0].name, None);

        // limit truncates from the newest end.
        let top = db.list_activity(gap, 1).await.unwrap();
        assert_eq!(top.len(), 1);
        assert_eq!(top[0].at, t0 + 33 * min);

        // gap 0 = any strictly increasing added_at breaks the batch:
        // 6 distinct timestamps → 6 batches (aggregation really works).
        let split = db.list_activity(0, 50).await.unwrap();
        assert_eq!(split.len(), 6);
    }

    #[tokio::test]
    async fn activity_ties_stay_in_one_batch_and_names_join() {
        let db = Db::open_in_memory().await.unwrap();
        // Two assets at the exact same instant: one batch even at gap 0.
        db.insert_asset(&asset_at(3, 1, 42)).await.unwrap();
        db.insert_asset(&asset_at(3, 2, 42)).await.unwrap();
        let batches = db.list_activity(0, 50).await.unwrap();
        assert_eq!(batches.len(), 1, "identical timestamps never split");
        assert_eq!(batches[0].asset_count, 2);

        // A rostered device contributes its display name.
        db.upsert_device(&crate::Device {
            device_hint: None,
            node_id: vec![3u8; 32],
            name: "妈妈的手机".into(),
            role: crate::Role::Member,
            paired_at: 1,
            last_seen: None,
            revoked: false,
        })
        .await
        .unwrap();
        let batches = db.list_activity(0, 50).await.unwrap();
        assert_eq!(batches[0].name.as_deref(), Some("妈妈的手机"));
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
