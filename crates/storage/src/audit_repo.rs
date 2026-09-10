//! Audit event repository v2 (AUDIT-01, card decision #1): the sole
//! long-term audit source. `audit_log`'s free-text `action`/`detail`
//! projection is eliminated outright — no migration, no historical v1
//! rows carried forward or faked as v2 facts.
//!
//! `event_id` is the idempotency key. A phone-side Flow outbox event and a
//! daemon that retries/re-delivers it write the identical `event_id`;
//! `record_event` is `INSERT OR IGNORE`, so replay is a no-op rather than a
//! duplicate row. Daemon-originated events (pairing, revoke, external
//! delete — single local writer, no retry path) mint a fresh random
//! `event_id` per write via [`AuditEntry::local`].

use sqlx::Row;

use crate::{Db, Result};

/// A new audit entry to append.
#[derive(Debug, Clone)]
pub struct AuditEntry {
    /// Idempotency key. Externally supplied for phone-originated Flow
    /// events (the ledger outbox's event id); freshly minted for
    /// daemon-local writes via [`AuditEntry::local`].
    pub event_id: String,
    /// When (unix ms).
    pub ts: i64,
    /// Acting device NodeId; `None` for external/unattributable changes.
    pub actor: Option<Vec<u8>>,
    /// e.g. `flow.round.finished`, `pair.accepted`, `asset.removed_external`.
    pub kind: String,
    /// Persistent Flow window id, when this event belongs to one.
    pub round_id: Option<String>,
    /// Asset hash the action touched, when applicable.
    pub target_hash: Option<Vec<u8>>,
    /// Structured payload (JSON object, arbitrary per-kind fields).
    pub payload: Option<String>,
}

impl AuditEntry {
    /// A daemon-local write: this process is the sole writer for this fact
    /// (no phone-side retry can ever resend it), so a fresh random id is
    /// exactly as good as one generated anywhere else.
    pub fn local(
        ts: i64,
        actor: Option<Vec<u8>>,
        kind: impl Into<String>,
        target_hash: Option<Vec<u8>>,
        payload: Option<String>,
    ) -> Self {
        Self {
            event_id: fresh_event_id(),
            ts,
            actor,
            kind: kind.into(),
            round_id: None,
            target_hash,
            payload,
        }
    }
}

/// A stored audit row (entry + assigned id).
#[derive(Debug, Clone)]
pub struct AuditRecord {
    pub id: i64,
    pub entry: AuditEntry,
}

impl Db {
    /// Idempotent append: a repeated `event_id` (phone outbox retransmit,
    /// daemon-side retry) is a no-op, never a second row. Returns whether a
    /// new row was actually inserted (false = it already existed).
    pub async fn append_audit(&self, e: &AuditEntry) -> Result<bool> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO audit_event (event_id, ts, actor, kind, round_id, target_hash, payload)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&e.event_id)
        .bind(e.ts)
        .bind(&e.actor)
        .bind(&e.kind)
        .bind(&e.round_id)
        .bind(&e.target_hash)
        .bind(&e.payload)
        .execute(self.pool())
        .await?;
        Ok(result.rows_affected() == 1)
    }

    /// Most recent entries first.
    pub async fn list_audit(&self, limit: u32) -> Result<Vec<AuditRecord>> {
        let rows = sqlx::query(
            "SELECT id, event_id, ts, actor, kind, round_id, target_hash, payload
             FROM audit_event ORDER BY ts DESC, id DESC LIMIT ?",
        )
        .bind(i64::from(limit.clamp(1, 10_000)))
        .fetch_all(self.pool())
        .await?;
        Ok(rows
            .iter()
            .map(|r| AuditRecord {
                id: r.get("id"),
                entry: AuditEntry {
                    event_id: r.get("event_id"),
                    ts: r.get("ts"),
                    actor: r.get("actor"),
                    kind: r.get("kind"),
                    round_id: r.get("round_id"),
                    target_hash: r.get("target_hash"),
                    payload: r.get("payload"),
                },
            })
            .collect())
    }

    /// PRES-01: 某 actor 最近一次指定 kind 的时间（unix ms）；从未
    /// 发生过 → None。device.connected 的 10 分钟去重靠它。
    pub async fn last_audit_ts(&self, actor: &[u8], kind: &str) -> Result<Option<i64>> {
        let row = sqlx::query("SELECT MAX(ts) AS ts FROM audit_event WHERE actor = ? AND kind = ?")
            .bind(actor)
            .bind(kind)
            .fetch_one(self.pool())
            .await?;
        Ok(row.get::<Option<i64>, _>("ts"))
    }
}

fn fresh_event_id() -> String {
    let mut bytes = [0u8; 16];
    // Daemon-local audit facts are advisory only if randomness fails —
    // falling back to a fixed-zero id would collide across writes and
    // silently drop them via INSERT OR IGNORE, which is worse than the
    // extremely unlikely getrandom failure this guards against.
    getrandom::fill(&mut bytes).expect("OS randomness for audit event id");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn append_and_list_newest_first() {
        let db = Db::open_in_memory().await.unwrap();

        // App-path action: attributed to a device.
        db.append_audit(&AuditEntry::local(
            1_753_770_000_000,
            Some(vec![1u8; 32]),
            "backup.commit",
            Some(vec![7u8; 32]),
            Some("{\"path\":\"originals/dev/2026/07/IMG_001.jpg\"}".into()),
        ))
        .await
        .unwrap();

        // External change: detected, not attributed.
        db.append_audit(&AuditEntry::local(
            1_753_770_001_000,
            None,
            "asset.removed_external",
            Some(vec![7u8; 32]),
            Some("{\"path\":\"originals/dev/2026/07/IMG_001.jpg\"}".into()),
        ))
        .await
        .unwrap();

        let log = db.list_audit(10).await.unwrap();
        assert_eq!(log.len(), 2);
        assert_eq!(log[0].entry.kind, "asset.removed_external", "newest first");
        assert_eq!(
            log[0].entry.actor, None,
            "external change stays unattributed"
        );
        assert_eq!(log[1].entry.actor, Some(vec![1u8; 32]));
        assert!(log[0].id > log[1].id);
    }

    // AUDIT-01 RED: the whole point of the unique event_id is that a
    // retransmitted phone outbox event (or a daemon retry) does not
    // duplicate the audit row.
    #[tokio::test]
    async fn repeated_event_id_is_idempotent() {
        let db = Db::open_in_memory().await.unwrap();
        let entry = AuditEntry {
            event_id: "fixed-event-id".into(),
            ts: 1_000,
            actor: None,
            kind: "flow.round.finished".into(),
            round_id: Some("round-1".into()),
            target_hash: None,
            payload: Some("{\"confirmed\":\"3\"}".into()),
        };

        let first = db.append_audit(&entry).await.unwrap();
        let second = db.append_audit(&entry).await.unwrap();

        assert!(first, "the first write must actually insert");
        assert!(!second, "a repeated event_id must not insert a second row");
        assert_eq!(db.list_audit(10).await.unwrap().len(), 1);
    }
}
