//! AUDIT-04 canonical audit core: `audit_operation`, `audit_item_evidence`,
//! `audit_tombstone`, `audit_decision`. This directly replaces AUDIT-01's
//! catch-all `audit_event` table (card decision #9) — no migration, no
//! historical v1/v2 event rows carried forward or faked as canonical facts.
//!
//! Routing summary (see `crates/daemon/src/router.rs::route_flow_audit_event`
//! for the authoritative dispatch):
//! - Flow round terminal summaries (`flow.round.finished`) → `audit_operation`,
//!   keyed by the phone's persistent `round_id` as `operation_id` (never a
//!   fresh daemon-minted id — the round IS the operation).
//! - Per-item facts (`flow.item.confirmed`/`source_missing`/`attention`,
//!   and a `flow.reconciliation.resolved` with disposition `NEEDS_DECISION`)
//!   → `audit_item_evidence`.
//! - A `flow.reconciliation.resolved` with disposition `UNRECOVERABLE` →
//!   `audit_tombstone`.
//! - User/local decisions (`flow.round.controlled`, `flow.scope.changed`,
//!   `flow.epoch.invalidated`, `flow.round.discarded`) → `audit_decision`.
//! - Everything else (pairing, device management, ingest, index rebuild,
//!   external-delete reconciliation) keeps writing through the
//!   [`AuditEntry`]/[`append_audit`] compatibility facade onto
//!   `audit_operation`, unchanged in call-site shape from AUDIT-01 — those
//!   are still one-shot operations with no item evidence (card decision #1
//!   explicitly scopes strict evidence/causal fields to backup rounds).
//!
//! `*_id` fields are idempotency keys everywhere: a phone-side outbox event
//! and a daemon retry both write the identical id; every append is
//! `INSERT OR IGNORE`, so replay is a no-op rather than a duplicate row.

use sqlx::Row;

use crate::{Db, Result};

// ── Compatibility facade (pairing/device/ingest/rebuild call sites) ────

/// A new audit entry to append — the AUDIT-01 shape, preserved so
/// non-Flow call sites (pairing, device management, ingest, rebuild) need
/// no changes. Internally these land in `audit_operation` (card decision
/// #1's "security operation" category).
#[derive(Debug, Clone)]
pub struct AuditEntry {
    /// Idempotency key. `operation_id` under the hood.
    pub event_id: String,
    /// When (unix ms).
    pub ts: i64,
    /// Acting device NodeId; `None` for external/unattributable changes.
    pub actor: Option<Vec<u8>>,
    /// e.g. `pair.accepted`, `asset.removed_external`.
    pub kind: String,
    /// Causal Flow round id, when this event belongs to one.
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
            event_id: fresh_id(),
            ts,
            actor,
            kind: kind.into(),
            round_id: None,
            target_hash,
            payload,
        }
    }
}

/// A stored audit row (entry + assigned id) — the AUDIT-01 read shape,
/// preserved for `audit.list`/`logs.export` consumers.
#[derive(Debug, Clone)]
pub struct AuditRecord {
    pub id: i64,
    pub entry: AuditEntry,
}

// ── Canonical operation ─────────────────────────────────────────────

/// One `audit_operation` row to append.
#[derive(Debug, Clone, Default)]
pub struct AuditOperationEntry {
    /// Idempotency key. For a Flow backup round this IS the phone's
    /// persistent `round_id` — the round is the operation, not a
    /// separately-minted id.
    pub operation_id: String,
    pub occurred_at: i64,
    /// When Desktop durably confirmed the operation (unix ms).
    pub confirmed_at: Option<i64>,
    pub actor: Option<Vec<u8>>,
    pub actor_name: Option<String>,
    pub kind: String,
    pub trigger: Option<String>,
    pub round_id: Option<String>,
    pub target_hash: Option<Vec<u8>>,
    pub scope_summary: Option<String>,
    pub final_counts: Option<String>,
    /// Object evidence collection digest — for Flow rounds this is
    /// recomputed from `audit_item_evidence`, never blindly copied from
    /// the origin's self-reported counts (card acceptance criterion #2).
    pub evidence_summary: Option<String>,
    pub causal_ref: Option<String>,
    pub payload: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AuditOperationRecord {
    pub id: i64,
    pub entry: AuditOperationEntry,
}

// ── Canonical item evidence ─────────────────────────────────────────

#[derive(Debug, Clone, Default)]
pub struct ItemEvidenceEntry {
    pub evidence_id: String,
    pub operation_id: Option<String>,
    pub item_ref: String,
    pub source_version: Option<String>,
    pub content_hash: Option<Vec<u8>>,
    pub receipt_ref: Option<String>,
    pub asset_ref: Option<Vec<u8>>,
    /// confirmed | duplicate | failed | source_missing | remote_missing
    pub outcome: String,
    pub occurred_at: i64,
    pub payload: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ItemEvidenceRecord {
    pub id: i64,
    pub entry: ItemEvidenceEntry,
}

// ── Canonical tombstone ──────────────────────────────────────────────

#[derive(Debug, Clone, Default)]
pub struct TombstoneEntry {
    pub tombstone_id: String,
    pub item_ref: Option<String>,
    /// The asset hash that left. Never a FK — a tombstone must outlive
    /// the deletion of its `asset` row (card decision #3).
    pub asset_ref: Vec<u8>,
    pub evidence_ref: Option<String>,
    /// external_delete | product_delete | unrecoverable
    pub reason: String,
    /// `None` = system/filesystem detected it; unattributable by design.
    pub discoverer: Option<Vec<u8>>,
    pub occurred_at: i64,
    pub recoverable: bool,
    pub payload: Option<String>,
}

#[derive(Debug, Clone)]
pub struct TombstoneRecord {
    pub id: i64,
    pub entry: TombstoneEntry,
}

// ── Canonical decision ───────────────────────────────────────────────

#[derive(Debug, Clone, Default)]
pub struct DecisionEntry {
    pub decision_id: String,
    /// cancel | restore | give_up_recovery | scope_changed |
    /// revoke_authorization | pause | continue | retry
    pub decision_kind: String,
    pub actor: Option<Vec<u8>>,
    pub causal_operation_id: Option<String>,
    pub causal_object_ref: Option<String>,
    pub occurred_at: i64,
    pub payload: Option<String>,
}

#[derive(Debug, Clone)]
pub struct DecisionRecord {
    pub id: i64,
    pub entry: DecisionEntry,
}

impl Db {
    // ── Compatibility facade over audit_operation ──────────────────

    /// Idempotent append: a repeated `event_id` (phone outbox retransmit,
    /// daemon-side retry) is a no-op, never a second row. Returns whether a
    /// new row was actually inserted (false = it already existed).
    pub async fn append_audit(&self, e: &AuditEntry) -> Result<bool> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO audit_operation
                (operation_id, occurred_at, actor, kind, round_id, target_hash, payload)
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

    /// Most recent entries first. Reads across the whole `audit_operation`
    /// table — this is the facade `audit.list`/`logs.export` still uses.
    pub async fn list_audit(&self, limit: u32) -> Result<Vec<AuditRecord>> {
        let rows = sqlx::query(
            "SELECT id, operation_id, occurred_at, actor, kind, round_id, target_hash, payload
             FROM audit_operation ORDER BY occurred_at DESC, id DESC LIMIT ?",
        )
        .bind(i64::from(limit.clamp(1, 10_000)))
        .fetch_all(self.pool())
        .await?;
        Ok(rows
            .iter()
            .map(|r| AuditRecord {
                id: r.get("id"),
                entry: AuditEntry {
                    event_id: r.get("operation_id"),
                    ts: r.get("occurred_at"),
                    actor: r.get("actor"),
                    kind: r.get("kind"),
                    round_id: r.get("round_id"),
                    target_hash: r.get("target_hash"),
                    payload: r.get("payload"),
                },
            })
            .collect())
    }

    // ── Canonical operation ─────────────────────────────────────────

    pub async fn append_operation(&self, e: &AuditOperationEntry) -> Result<bool> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO audit_operation
                (operation_id, occurred_at, confirmed_at, actor, actor_name, kind, trigger,
                 round_id, target_hash, scope_summary, final_counts, evidence_summary,
                 causal_ref, payload)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&e.operation_id)
        .bind(e.occurred_at)
        .bind(e.confirmed_at)
        .bind(&e.actor)
        .bind(&e.actor_name)
        .bind(&e.kind)
        .bind(&e.trigger)
        .bind(&e.round_id)
        .bind(&e.target_hash)
        .bind(&e.scope_summary)
        .bind(&e.final_counts)
        .bind(&e.evidence_summary)
        .bind(&e.causal_ref)
        .bind(&e.payload)
        .execute(self.pool())
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn get_operation(&self, operation_id: &str) -> Result<Option<AuditOperationRecord>> {
        let row = sqlx::query(
            "SELECT id, operation_id, occurred_at, confirmed_at, actor, actor_name, kind,
                    trigger, round_id, target_hash, scope_summary, final_counts,
                    evidence_summary, causal_ref, payload
             FROM audit_operation WHERE operation_id = ?",
        )
        .bind(operation_id)
        .fetch_optional(self.pool())
        .await?;
        Ok(row.map(|r| operation_from_row(&r)))
    }

    pub async fn list_operations(&self, limit: u32) -> Result<Vec<AuditOperationRecord>> {
        let rows = sqlx::query(
            "SELECT id, operation_id, occurred_at, confirmed_at, actor, actor_name, kind,
                    trigger, round_id, target_hash, scope_summary, final_counts,
                    evidence_summary, causal_ref, payload
             FROM audit_operation ORDER BY occurred_at DESC, id DESC LIMIT ?",
        )
        .bind(i64::from(limit.clamp(1, 10_000)))
        .fetch_all(self.pool())
        .await?;
        Ok(rows.iter().map(operation_from_row).collect())
    }

    // ── Canonical item evidence ──────────────────────────────────────

    pub async fn append_item_evidence(&self, e: &ItemEvidenceEntry) -> Result<bool> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO audit_item_evidence
                (evidence_id, operation_id, item_ref, source_version, content_hash,
                 receipt_ref, asset_ref, outcome, occurred_at, payload)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&e.evidence_id)
        .bind(&e.operation_id)
        .bind(&e.item_ref)
        .bind(&e.source_version)
        .bind(&e.content_hash)
        .bind(&e.receipt_ref)
        .bind(&e.asset_ref)
        .bind(&e.outcome)
        .bind(e.occurred_at)
        .bind(&e.payload)
        .execute(self.pool())
        .await?;
        Ok(result.rows_affected() == 1)
    }

    /// Every item evidence row belonging to one operation (Flow round) —
    /// how `audit_operation.evidence_summary` is recomputed, and how a
    /// UI/support case answers "what proved this operation's outcome".
    pub async fn list_item_evidence_for_operation(
        &self,
        operation_id: &str,
    ) -> Result<Vec<ItemEvidenceRecord>> {
        let rows = sqlx::query(
            "SELECT id, evidence_id, operation_id, item_ref, source_version, content_hash,
                    receipt_ref, asset_ref, outcome, occurred_at, payload
             FROM audit_item_evidence WHERE operation_id = ? ORDER BY id ASC",
        )
        .bind(operation_id)
        .fetch_all(self.pool())
        .await?;
        Ok(rows.iter().map(item_evidence_from_row).collect())
    }

    /// Item evidence for one asset — survives the asset row's own
    /// deletion (card decision #3: evidence/tombstone outlive `asset`).
    pub async fn list_item_evidence_for_asset(
        &self,
        asset_ref: &[u8],
    ) -> Result<Vec<ItemEvidenceRecord>> {
        let rows = sqlx::query(
            "SELECT id, evidence_id, operation_id, item_ref, source_version, content_hash,
                    receipt_ref, asset_ref, outcome, occurred_at, payload
             FROM audit_item_evidence WHERE asset_ref = ? ORDER BY id ASC",
        )
        .bind(asset_ref)
        .fetch_all(self.pool())
        .await?;
        Ok(rows.iter().map(item_evidence_from_row).collect())
    }

    // ── Canonical tombstone ───────────────────────────────────────────

    pub async fn append_tombstone(&self, e: &TombstoneEntry) -> Result<bool> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO audit_tombstone
                (tombstone_id, item_ref, asset_ref, evidence_ref, reason, discoverer,
                 occurred_at, recoverable, payload)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&e.tombstone_id)
        .bind(&e.item_ref)
        .bind(&e.asset_ref)
        .bind(&e.evidence_ref)
        .bind(&e.reason)
        .bind(&e.discoverer)
        .bind(e.occurred_at)
        .bind(i64::from(e.recoverable))
        .bind(&e.payload)
        .execute(self.pool())
        .await?;
        Ok(result.rows_affected() == 1)
    }

    /// Tombstones for one asset hash. Deliberately independent of the
    /// `asset` table's own lifecycle — deleting the asset row must never
    /// delete these (card decision #3; the reverse-proof lives in
    /// `crates/daemon/tests/sync_flow.rs`).
    pub async fn list_tombstones_for_asset(
        &self,
        asset_ref: &[u8],
    ) -> Result<Vec<TombstoneRecord>> {
        let rows = sqlx::query(
            "SELECT id, tombstone_id, item_ref, asset_ref, evidence_ref, reason, discoverer,
                    occurred_at, recoverable, payload
             FROM audit_tombstone WHERE asset_ref = ? ORDER BY occurred_at DESC, id DESC",
        )
        .bind(asset_ref)
        .fetch_all(self.pool())
        .await?;
        Ok(rows.iter().map(tombstone_from_row).collect())
    }

    pub async fn list_tombstones(&self, limit: u32) -> Result<Vec<TombstoneRecord>> {
        let rows = sqlx::query(
            "SELECT id, tombstone_id, item_ref, asset_ref, evidence_ref, reason, discoverer,
                    occurred_at, recoverable, payload
             FROM audit_tombstone ORDER BY occurred_at DESC, id DESC LIMIT ?",
        )
        .bind(i64::from(limit.clamp(1, 10_000)))
        .fetch_all(self.pool())
        .await?;
        Ok(rows.iter().map(tombstone_from_row).collect())
    }

    // ── Canonical decision ────────────────────────────────────────────

    pub async fn append_decision(&self, e: &DecisionEntry) -> Result<bool> {
        let result = sqlx::query(
            "INSERT OR IGNORE INTO audit_decision
                (decision_id, decision_kind, actor, causal_operation_id, causal_object_ref,
                 occurred_at, payload)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&e.decision_id)
        .bind(&e.decision_kind)
        .bind(&e.actor)
        .bind(&e.causal_operation_id)
        .bind(&e.causal_object_ref)
        .bind(e.occurred_at)
        .bind(&e.payload)
        .execute(self.pool())
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn get_decision(&self, decision_id: &str) -> Result<Option<DecisionRecord>> {
        let row = sqlx::query(
            "SELECT id, decision_id, decision_kind, actor, causal_operation_id,
                    causal_object_ref, occurred_at, payload
             FROM audit_decision WHERE decision_id = ?",
        )
        .bind(decision_id)
        .fetch_optional(self.pool())
        .await?;
        Ok(row.map(|r| decision_from_row(&r)))
    }

    pub async fn list_decisions(&self, limit: u32) -> Result<Vec<DecisionRecord>> {
        let rows = sqlx::query(
            "SELECT id, decision_id, decision_kind, actor, causal_operation_id,
                    causal_object_ref, occurred_at, payload
             FROM audit_decision ORDER BY occurred_at DESC, id DESC LIMIT ?",
        )
        .bind(i64::from(limit.clamp(1, 10_000)))
        .fetch_all(self.pool())
        .await?;
        Ok(rows.iter().map(decision_from_row).collect())
    }
}

fn operation_from_row(r: &sqlx::sqlite::SqliteRow) -> AuditOperationRecord {
    AuditOperationRecord {
        id: r.get("id"),
        entry: AuditOperationEntry {
            operation_id: r.get("operation_id"),
            occurred_at: r.get("occurred_at"),
            confirmed_at: r.get("confirmed_at"),
            actor: r.get("actor"),
            actor_name: r.get("actor_name"),
            kind: r.get("kind"),
            trigger: r.get("trigger"),
            round_id: r.get("round_id"),
            target_hash: r.get("target_hash"),
            scope_summary: r.get("scope_summary"),
            final_counts: r.get("final_counts"),
            evidence_summary: r.get("evidence_summary"),
            causal_ref: r.get("causal_ref"),
            payload: r.get("payload"),
        },
    }
}

fn item_evidence_from_row(r: &sqlx::sqlite::SqliteRow) -> ItemEvidenceRecord {
    ItemEvidenceRecord {
        id: r.get("id"),
        entry: ItemEvidenceEntry {
            evidence_id: r.get("evidence_id"),
            operation_id: r.get("operation_id"),
            item_ref: r.get("item_ref"),
            source_version: r.get("source_version"),
            content_hash: r.get("content_hash"),
            receipt_ref: r.get("receipt_ref"),
            asset_ref: r.get("asset_ref"),
            outcome: r.get("outcome"),
            occurred_at: r.get("occurred_at"),
            payload: r.get("payload"),
        },
    }
}

fn tombstone_from_row(r: &sqlx::sqlite::SqliteRow) -> TombstoneRecord {
    TombstoneRecord {
        id: r.get("id"),
        entry: TombstoneEntry {
            tombstone_id: r.get("tombstone_id"),
            item_ref: r.get("item_ref"),
            asset_ref: r.get("asset_ref"),
            evidence_ref: r.get("evidence_ref"),
            reason: r.get("reason"),
            discoverer: r.get("discoverer"),
            occurred_at: r.get("occurred_at"),
            recoverable: r.get::<i64, _>("recoverable") != 0,
            payload: r.get("payload"),
        },
    }
}

fn decision_from_row(r: &sqlx::sqlite::SqliteRow) -> DecisionRecord {
    DecisionRecord {
        id: r.get("id"),
        entry: DecisionEntry {
            decision_id: r.get("decision_id"),
            decision_kind: r.get("decision_kind"),
            actor: r.get("actor"),
            causal_operation_id: r.get("causal_operation_id"),
            causal_object_ref: r.get("causal_object_ref"),
            occurred_at: r.get("occurred_at"),
            payload: r.get("payload"),
        },
    }
}

fn fresh_id() -> String {
    let mut bytes = [0u8; 16];
    // Daemon-local audit facts are advisory only if randomness fails —
    // falling back to a fixed-zero id would collide across writes and
    // silently drop them via INSERT OR IGNORE, which is worse than the
    // extremely unlikely getrandom failure this guards against.
    getrandom::fill(&mut bytes).expect("OS randomness for audit id");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn append_and_list_newest_first() {
        let db = Db::open_in_memory().await.unwrap();

        db.append_audit(&AuditEntry::local(
            1_753_770_000_000,
            Some(vec![1u8; 32]),
            "backup.commit",
            Some(vec![7u8; 32]),
            Some("{\"path\":\"originals/dev/2026/07/IMG_001.jpg\"}".into()),
        ))
        .await
        .unwrap();

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

    // AUDIT-04: idempotency carries over unchanged from AUDIT-01 — a
    // retransmitted phone outbox event (or a daemon retry) does not
    // duplicate the audit_operation row.
    #[tokio::test]
    async fn repeated_event_id_is_idempotent() {
        let db = Db::open_in_memory().await.unwrap();
        let entry = AuditEntry {
            event_id: "fixed-event-id".into(),
            ts: 1_000,
            actor: None,
            kind: "pair.accepted".into(),
            round_id: None,
            target_hash: None,
            payload: Some("{\"detail\":\"x\"}".into()),
        };

        let first = db.append_audit(&entry).await.unwrap();
        let second = db.append_audit(&entry).await.unwrap();

        assert!(first, "the first write must actually insert");
        assert!(!second, "a repeated event_id must not insert a second row");
        assert_eq!(db.list_audit(10).await.unwrap().len(), 1);
    }

    // ── AUDIT-04 canonical core ──────────────────────────────────────

    fn operation(id: &str, round_id: Option<&str>) -> AuditOperationEntry {
        AuditOperationEntry {
            operation_id: id.into(),
            occurred_at: 1_000,
            confirmed_at: Some(1_100),
            actor: Some(vec![1u8; 32]),
            actor_name: Some("小米 14".into()),
            kind: "flow.round.finished".into(),
            trigger: Some("flow".into()),
            round_id: round_id.map(str::to_string),
            target_hash: None,
            scope_summary: None,
            final_counts: Some("{\"confirmed\":\"3\"}".into()),
            evidence_summary: None,
            causal_ref: None,
            payload: None,
        }
    }

    fn evidence(id: &str, operation_id: &str, outcome: &str) -> ItemEvidenceEntry {
        ItemEvidenceEntry {
            evidence_id: id.into(),
            operation_id: Some(operation_id.into()),
            item_ref: format!("item-{id}"),
            source_version: Some("v1".into()),
            content_hash: Some(vec![9u8; 32]),
            receipt_ref: Some(format!("receipt-{id}")),
            asset_ref: Some(vec![9u8; 32]),
            outcome: outcome.into(),
            occurred_at: 1_050,
            payload: None,
        }
    }

    #[tokio::test]
    async fn operation_is_idempotent_and_queryable_by_id() {
        let db = Db::open_in_memory().await.unwrap();
        let op = operation("round-1", Some("round-1"));

        assert!(db.append_operation(&op).await.unwrap());
        assert!(
            !db.append_operation(&op).await.unwrap(),
            "replay must not duplicate the operation row"
        );

        let got = db.get_operation("round-1").await.unwrap().unwrap();
        assert_eq!(got.entry.kind, "flow.round.finished");
        assert_eq!(got.entry.actor_name.as_deref(), Some("小米 14"));
    }

    #[tokio::test]
    async fn item_evidence_links_to_its_operation_and_survives_asset_deletion() {
        let db = Db::open_in_memory().await.unwrap();
        db.append_operation(&operation("round-2", Some("round-2")))
            .await
            .unwrap();
        db.append_item_evidence(&evidence("e1", "round-2", "confirmed"))
            .await
            .unwrap();
        db.append_item_evidence(&evidence("e2", "round-2", "confirmed"))
            .await
            .unwrap();

        let for_op = db
            .list_item_evidence_for_operation("round-2")
            .await
            .unwrap();
        assert_eq!(for_op.len(), 2, "both items link to the round operation");

        // Card decision #3: deleting the asset row must not touch evidence.
        db.insert_asset(&crate::asset_repo::Asset {
            hash: vec![9u8; 32],
            rel_path: "originals/x.jpg".into(),
            media_type: "image/jpeg".into(),
            bytes: 1,
            taken_at: Some(1),
            width: None,
            height: None,
            src_device: vec![1u8; 32],
            added_at: 1,
            thumb_state: 0,
        })
        .await
        .unwrap();
        db.delete_asset(&[9u8; 32]).await.unwrap();
        let for_asset = db.list_item_evidence_for_asset(&[9u8; 32]).await.unwrap();
        assert_eq!(
            for_asset.len(),
            2,
            "evidence must outlive the deleted asset row"
        );
    }

    #[tokio::test]
    async fn tombstone_outlives_asset_row_deletion() {
        let db = Db::open_in_memory().await.unwrap();
        db.insert_asset(&crate::asset_repo::Asset {
            hash: vec![7u8; 32],
            rel_path: "originals/deleted.jpg".into(),
            media_type: "image/jpeg".into(),
            bytes: 1,
            taken_at: Some(1),
            width: None,
            height: None,
            src_device: vec![1u8; 32],
            added_at: 1,
            thumb_state: 0,
        })
        .await
        .unwrap();
        db.delete_asset(&[7u8; 32]).await.unwrap();

        db.append_tombstone(&TombstoneEntry {
            tombstone_id: "t1".into(),
            item_ref: Some("item-1".into()),
            asset_ref: vec![7u8; 32],
            evidence_ref: None,
            reason: "external_delete".into(),
            discoverer: None,
            occurred_at: 2_000,
            recoverable: false,
            payload: None,
        })
        .await
        .unwrap();

        assert!(db.get_asset(&[7u8; 32]).await.unwrap().is_none());
        let tombstones = db.list_tombstones_for_asset(&[7u8; 32]).await.unwrap();
        assert_eq!(tombstones.len(), 1, "tombstone survives asset removal");
        assert_eq!(tombstones[0].entry.reason, "external_delete");
        assert!(tombstones[0].entry.discoverer.is_none(), "unattributable");
    }

    #[tokio::test]
    async fn decision_references_its_causal_operation() {
        let db = Db::open_in_memory().await.unwrap();
        db.append_operation(&operation("round-3", Some("round-3")))
            .await
            .unwrap();

        db.append_decision(&DecisionEntry {
            decision_id: "d1".into(),
            decision_kind: "cancel".into(),
            actor: Some(vec![1u8; 32]),
            causal_operation_id: Some("round-3".into()),
            causal_object_ref: None,
            occurred_at: 1_200,
            payload: Some("{\"action\":\"cancel\"}".into()),
        })
        .await
        .unwrap();

        let decisions = db.list_decisions(10).await.unwrap();
        assert_eq!(decisions.len(), 1);
        assert_eq!(
            decisions[0].entry.causal_operation_id.as_deref(),
            Some("round-3")
        );
        assert_eq!(decisions[0].entry.decision_kind, "cancel");
    }

    #[tokio::test]
    async fn decision_id_is_idempotent() {
        let db = Db::open_in_memory().await.unwrap();
        let d = DecisionEntry {
            decision_id: "fixed-decision".into(),
            decision_kind: "restore".into(),
            actor: None,
            causal_operation_id: None,
            causal_object_ref: None,
            occurred_at: 1,
            payload: None,
        };
        assert!(db.append_decision(&d).await.unwrap());
        assert!(!db.append_decision(&d).await.unwrap());
        assert_eq!(db.list_decisions(10).await.unwrap().len(), 1);
    }
}
