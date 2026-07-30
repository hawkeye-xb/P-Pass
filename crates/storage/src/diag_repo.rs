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

impl Db {
    pub async fn append_diag(&self, e: &DiagEvent) -> Result<()> {
        sqlx::query("INSERT INTO diag_event (ts, kind, detail) VALUES (?, ?, ?)")
            .bind(e.ts)
            .bind(&e.kind)
            .bind(&e.detail)
            .execute(self.pool())
            .await?;
        Ok(())
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
}
