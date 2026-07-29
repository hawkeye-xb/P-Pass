//! Audit log repository (§5 v1.1, human decision 2026-07-29).
//!
//! Every operation through the product path is recorded to device
//! granularity. External changes (the user touching files directly)
//! are recorded as *detection* events with `actor = None` — the
//! filesystem cannot attribute "who", and the log never pretends to.
//! Long-term retention: unlike `diag_event`, nothing trims this table.

use sqlx::Row;

use crate::{Db, Result};

/// A new audit entry to append.
#[derive(Debug, Clone)]
pub struct AuditEntry {
    /// When (unix ms).
    pub ts: i64,
    /// Acting device NodeId; `None` for external/unattributable changes.
    pub actor: Option<Vec<u8>>,
    /// e.g. `backup.commit`, `pair`, `revoke`, `external.delete`.
    pub action: String,
    /// Asset hash the action touched, when applicable.
    pub target_hash: Option<Vec<u8>>,
    /// Free-form context (relative path, error code, …).
    pub detail: Option<String>,
}

/// A stored audit row (entry + assigned id).
#[derive(Debug, Clone)]
pub struct AuditRecord {
    pub id: i64,
    pub entry: AuditEntry,
}

impl Db {
    pub async fn append_audit(&self, e: &AuditEntry) -> Result<()> {
        sqlx::query(
            "INSERT INTO audit_log (ts, actor, action, target_hash, detail)
             VALUES (?, ?, ?, ?, ?)",
        )
        .bind(e.ts)
        .bind(&e.actor)
        .bind(&e.action)
        .bind(&e.target_hash)
        .bind(&e.detail)
        .execute(self.pool())
        .await?;
        Ok(())
    }

    /// Most recent entries first.
    pub async fn list_audit(&self, limit: u32) -> Result<Vec<AuditRecord>> {
        let rows = sqlx::query(
            "SELECT id, ts, actor, action, target_hash, detail
             FROM audit_log ORDER BY ts DESC, id DESC LIMIT ?",
        )
        .bind(i64::from(limit.clamp(1, 10_000)))
        .fetch_all(self.pool())
        .await?;
        Ok(rows
            .iter()
            .map(|r| AuditRecord {
                id: r.get("id"),
                entry: AuditEntry {
                    ts: r.get("ts"),
                    actor: r.get("actor"),
                    action: r.get("action"),
                    target_hash: r.get("target_hash"),
                    detail: r.get("detail"),
                },
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn append_and_list_newest_first() {
        let db = Db::open_in_memory().await.unwrap();

        // App-path action: attributed to a device.
        db.append_audit(&AuditEntry {
            ts: 1_753_770_000_000,
            actor: Some(vec![1u8; 32]),
            action: "backup.commit".into(),
            target_hash: Some(vec![7u8; 32]),
            detail: Some("originals/dev/2026/07/IMG_001.jpg".into()),
        })
        .await
        .unwrap();

        // External change: detected, not attributed.
        db.append_audit(&AuditEntry {
            ts: 1_753_770_001_000,
            actor: None,
            action: "external.delete".into(),
            target_hash: Some(vec![7u8; 32]),
            detail: Some("originals/dev/2026/07/IMG_001.jpg".into()),
        })
        .await
        .unwrap();

        let log = db.list_audit(10).await.unwrap();
        assert_eq!(log.len(), 2);
        assert_eq!(log[0].entry.action, "external.delete", "newest first");
        assert_eq!(
            log[0].entry.actor, None,
            "external change stays unattributed"
        );
        assert_eq!(log[1].entry.actor, Some(vec![1u8; 32]));
        assert!(log[0].id > log[1].id);
    }
}
