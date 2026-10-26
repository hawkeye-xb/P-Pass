//! Diag event repository: the 30-day ring of diagnostic events (§5).
//!
//! Minimal write/read surface for T-030's authz checkpoint; the full
//! DaemonState aggregation and ring-pruning policy land with T-034.

use sqlx::Row;

use crate::{Db, Result};

/// One diagnostic event row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagEvent {
    pub ts: i64,
    /// Event kind, e.g. `authz.denied`.
    pub kind: String,
    /// Free-form detail (JSON by convention).
    pub detail: Option<String>,
}

/// #1122：诊断记录最多保留这么多条（除了 30 天的时间环之外再加一道条数上限），
/// 超出时丢最旧的。任何对端都无法靠反复触发诊断写入把磁盘撑满。
pub const DIAG_MAX_ROWS: i64 = 10_000;

impl Db {
    pub async fn append_diag(&self, e: &DiagEvent) -> Result<()> {
        sqlx::query("INSERT INTO diag_event (ts, kind, detail) VALUES (?, ?, ?)")
            .bind(e.ts)
            .bind(&e.kind)
            .bind(&e.detail)
            .execute(self.pool())
            .await?;
        self.cap_diag(DIAG_MAX_ROWS).await
    }

    /// 只留最新的 `keep` 条（按插入顺序）。
    pub(crate) async fn cap_diag(&self, keep: i64) -> Result<()> {
        sqlx::query(
            "DELETE FROM diag_event WHERE rowid <=
               (SELECT rowid FROM diag_event ORDER BY rowid DESC LIMIT 1 OFFSET ?)",
        )
        .bind(keep)
        .execute(self.pool())
        .await?;
        Ok(())
    }

    /// Drop diag events older than `before_ts` — the 30-day ring (§5).
    /// Returns how many rows were pruned.
    pub async fn prune_diag(&self, before_ts: i64) -> Result<u64> {
        let done = sqlx::query("DELETE FROM diag_event WHERE ts < ?")
            .bind(before_ts)
            .execute(self.pool())
            .await?;
        Ok(done.rows_affected())
    }

    /// Newest-first diag events.
    pub async fn list_diag(&self, limit: u32) -> Result<Vec<DiagEvent>> {
        let rows = sqlx::query(
            "SELECT ts, kind, detail FROM diag_event ORDER BY ts DESC, rowid DESC LIMIT ?",
        )
        .bind(i64::from(limit.clamp(1, 1000)))
        .fetch_all(self.pool())
        .await?;
        Ok(rows
            .iter()
            .map(|r| DiagEvent {
                ts: r.get("ts"),
                kind: r.get("kind"),
                detail: r.get("detail"),
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn append_and_list_roundtrip() {
        let db = Db::open_in_memory().await.unwrap();
        for i in 0..3i64 {
            db.append_diag(&DiagEvent {
                ts: i,
                kind: "authz.denied".into(),
                detail: Some(format!("{{\"n\":{i}}}")),
            })
            .await
            .unwrap();
        }
        let got = db.list_diag(2).await.unwrap();
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].ts, 2, "newest first");
        assert_eq!(got[0].kind, "authz.denied");
    }

    /// #1122：条数上限——经 `append_diag` 写超上限时丢最旧的，最新的照常在。
    /// 反证：append_diag 不调 cap_diag，总数超过 DIAG_MAX_ROWS ⇒ 变红。
    #[tokio::test]
    async fn diag_rows_are_capped_dropping_the_oldest() {
        let db = Db::open_in_memory().await.unwrap();
        for i in 0..(DIAG_MAX_ROWS + 5) {
            db.append_diag(&DiagEvent {
                ts: i,
                kind: "k".into(),
                detail: None,
            })
            .await
            .unwrap();
        }
        let n: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM diag_event")
            .fetch_one(db.pool())
            .await
            .unwrap();
        assert_eq!(n, DIAG_MAX_ROWS);
        let newest = db.list_diag(1).await.unwrap();
        assert_eq!(newest[0].ts, DIAG_MAX_ROWS + 4, "最新的还在");
        let oldest: i64 = sqlx::query_scalar("SELECT MIN(ts) FROM diag_event")
            .fetch_one(db.pool())
            .await
            .unwrap();
        assert_eq!(oldest, 5, "最旧的 5 条被丢");
    }
}
