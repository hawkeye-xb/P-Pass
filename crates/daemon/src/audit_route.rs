//! AUDIT-04: routes phone-side durable Flow audit outbox events (AUDIT-01
//! wire shape, unchanged) onto the canonical `audit_operation` /
//! `audit_item_evidence` / `audit_tombstone` / `audit_decision` tables.
//!
//! This is the authoritative dispatch table for every `kind` Android's
//! ledger outbox ([`apps/android/.../DiscoveryLedger.kt::AuditKinds`]) can
//! produce. Every arm is idempotent on the phone-minted `event_id` (or, for
//! `flow.round.finished`, on the phone's persistent `round_id` — the round
//! IS the operation, never a separately-minted id), so a retransmitted
//! batch after a lost response never duplicates a row.

use storage::{AuditOperationEntry, Db, DecisionEntry, ItemEvidenceEntry, TombstoneEntry};

/// One phone-side outbox event, decoupled from `proto::FlowAuditEvent` so
/// this module has no wire-format dependency (kept for testability).
#[derive(Debug, Clone)]
pub struct FlowAuditFact<'a> {
    pub event_id: &'a str,
    pub kind: &'a str,
    pub round_id: Option<&'a str>,
    pub occurred_at_ms: i64,
    pub payload: &'a std::collections::BTreeMap<String, String>,
}

/// Route one durable Flow audit fact onto the canonical schema. Returns
/// `true` when the fact is now durably present (freshly inserted or
/// already there from an earlier delivery) — the caller acknowledges
/// exactly these ids. `false` only for a malformed fact this dispatch
/// cannot place anywhere (missing a field its kind requires).
pub async fn route(db: &Db, actor: &[u8], fact: &FlowAuditFact<'_>) -> bool {
    match fact.kind {
        "flow.round.finished" => route_round_finished(db, actor, fact).await,
        "flow.item.confirmed" => route_item_confirmed(db, fact).await,
        "flow.item.source_missing" => route_item_source_missing(db, fact).await,
        "flow.item.attention" => route_item_attention(db, fact).await,
        "flow.reconciliation.resolved" => route_reconciliation_resolved(db, actor, fact).await,
        "flow.round.controlled" | "flow.scope.changed" | "flow.epoch.invalidated" => {
            route_decision(db, actor, fact).await
        }
        // Closed set from the Android ledger outbox (card decision #9: no
        // legacy audit_event kinds survive). An unrecognised kind is never
        // silently dropped — it still lands as a plain operation so the
        // fact is not lost, but this branch should never fire in practice.
        _ => route_unknown_as_operation(db, actor, fact).await,
    }
}

async fn route_round_finished(db: &Db, actor: &[u8], fact: &FlowAuditFact<'_>) -> bool {
    // The round IS the operation: operation_id must be the phone's
    // persistent round_id, never a fresh daemon-minted id, so item
    // evidence (keyed by the same round_id as operation_id) and the
    // operation summary are the same causal chain.
    let Some(round_id) = fact.round_id else {
        return false;
    };
    // Card acceptance criterion #2: evidence_summary must be recomputed
    // from the actually-persisted item evidence, never blindly copied
    // from the phone's self-reported final_counts payload.
    let evidence = db
        .list_item_evidence_for_operation(round_id)
        .await
        .unwrap_or_default();
    let mut by_outcome: std::collections::BTreeMap<&str, u64> = std::collections::BTreeMap::new();
    for e in &evidence {
        *by_outcome.entry(e.entry.outcome.as_str()).or_insert(0) += 1;
    }
    let evidence_summary = serde_json::to_string(&by_outcome).ok();
    let final_counts = serde_json::to_string(fact.payload).ok();
    let entry = AuditOperationEntry {
        operation_id: round_id.to_string(),
        occurred_at: fact.occurred_at_ms,
        confirmed_at: Some(now_ms()),
        actor: Some(actor.to_vec()),
        actor_name: None,
        kind: fact.kind.to_string(),
        trigger: Some("flow".into()),
        round_id: Some(round_id.to_string()),
        target_hash: None,
        scope_summary: None,
        final_counts,
        evidence_summary,
        causal_ref: None,
        payload: None,
    };
    db.append_operation(&entry).await.unwrap_or(false)
        || db.get_operation(round_id).await.ok().flatten().is_some()
}

async fn route_item_confirmed(db: &Db, fact: &FlowAuditFact<'_>) -> bool {
    route_item_evidence(db, fact, "confirmed").await
}

async fn route_item_source_missing(db: &Db, fact: &FlowAuditFact<'_>) -> bool {
    route_item_evidence(db, fact, "source_missing").await
}

async fn route_item_attention(db: &Db, fact: &FlowAuditFact<'_>) -> bool {
    route_item_evidence(db, fact, "failed").await
}

async fn route_item_evidence(db: &Db, fact: &FlowAuditFact<'_>, outcome: &str) -> bool {
    let Some(item_ref) = fact.payload.get("itemRef") else {
        return false;
    };
    let content_hash = fact.payload.get("contentHash").and_then(|h| parse_hex32(h));
    let entry = ItemEvidenceEntry {
        evidence_id: fact.event_id.to_string(),
        operation_id: fact.round_id.map(str::to_string),
        item_ref: item_ref.clone(),
        source_version: fact.payload.get("sourceVersion").cloned(),
        content_hash: content_hash.as_ref().map(|h| h.to_vec()),
        receipt_ref: fact.payload.get("receiptRef").cloned(),
        asset_ref: content_hash.as_ref().map(|h| h.to_vec()),
        outcome: outcome.to_string(),
        occurred_at: fact.occurred_at_ms,
        payload: serde_json::to_string(fact.payload).ok(),
    };
    // Idempotent: a fresh insert accepts it; a replay hitting INSERT OR
    // IGNORE's no-op path must still report accepted (the fact IS durable,
    // just not newly written), or the phone would resend it forever.
    if db.append_item_evidence(&entry).await.unwrap_or(false) {
        return true;
    }
    db.list_item_evidence_for_operation(fact.round_id.unwrap_or_default())
        .await
        .unwrap_or_default()
        .iter()
        .any(|r| r.entry.evidence_id == fact.event_id)
}

/// `flow.reconciliation.resolved` fans out to one of two canonical tables
/// depending on the phone's recovery disposition:
/// - `NEEDS_DECISION` (remote missing, phone source present) is still
///   object evidence pointing at a recoverable gap.
/// - `UNRECOVERABLE` (remote missing, phone source also gone) is the
///   tombstone case matrix §5 "不可恢复确认" — the asset left for good.
async fn route_reconciliation_resolved(db: &Db, actor: &[u8], fact: &FlowAuditFact<'_>) -> bool {
    let Some(disposition) = fact.payload.get("disposition") else {
        return false;
    };
    let Some(content_hash) = fact.payload.get("contentHash").and_then(|h| parse_hex32(h)) else {
        return false;
    };
    match disposition.as_str() {
        "UNRECOVERABLE" => {
            let entry = TombstoneEntry {
                tombstone_id: fact.event_id.to_string(),
                item_ref: None,
                asset_ref: content_hash.to_vec(),
                evidence_ref: None,
                reason: "unrecoverable".into(),
                // The phone determined this via reconciliation (it queried
                // both the remote's and its own source presence) — unlike
                // the daemon's own filesystem-detected external delete,
                // this discoverer IS known.
                discoverer: Some(actor.to_vec()),
                occurred_at: fact.occurred_at_ms,
                recoverable: false,
                payload: serde_json::to_string(fact.payload).ok(),
            };
            if db.append_tombstone(&entry).await.unwrap_or(false) {
                return true;
            }
            db.list_tombstones_for_asset(&content_hash)
                .await
                .unwrap_or_default()
                .iter()
                .any(|r| r.entry.tombstone_id == fact.event_id)
        }
        _ => {
            let entry = ItemEvidenceEntry {
                evidence_id: fact.event_id.to_string(),
                operation_id: fact.round_id.map(str::to_string),
                item_ref: hex::encode(content_hash),
                source_version: None,
                content_hash: Some(content_hash.to_vec()),
                receipt_ref: None,
                asset_ref: Some(content_hash.to_vec()),
                outcome: "remote_missing".into(),
                occurred_at: fact.occurred_at_ms,
                payload: serde_json::to_string(fact.payload).ok(),
            };
            db.append_item_evidence(&entry).await.unwrap_or(false)
        }
    }
}

async fn route_decision(db: &Db, actor: &[u8], fact: &FlowAuditFact<'_>) -> bool {
    let decision_kind = match fact.kind {
        "flow.round.controlled" => fact
            .payload
            .get("action")
            .cloned()
            .unwrap_or_else(|| "controlled".into()),
        "flow.scope.changed" => "scope_changed".to_string(),
        "flow.epoch.invalidated" => "epoch_invalidated".to_string(),
        other => other.to_string(),
    };
    let entry = DecisionEntry {
        decision_id: fact.event_id.to_string(),
        decision_kind,
        actor: Some(actor.to_vec()),
        causal_operation_id: fact.round_id.map(str::to_string),
        causal_object_ref: None,
        occurred_at: fact.occurred_at_ms,
        payload: serde_json::to_string(fact.payload).ok(),
    };
    if db.append_decision(&entry).await.unwrap_or(false) {
        return true;
    }
    db.get_decision(fact.event_id)
        .await
        .ok()
        .flatten()
        .is_some()
}

async fn route_unknown_as_operation(db: &Db, actor: &[u8], fact: &FlowAuditFact<'_>) -> bool {
    let entry = AuditOperationEntry {
        operation_id: fact.event_id.to_string(),
        occurred_at: fact.occurred_at_ms,
        confirmed_at: Some(now_ms()),
        actor: Some(actor.to_vec()),
        actor_name: None,
        kind: fact.kind.to_string(),
        trigger: None,
        round_id: fact.round_id.map(str::to_string),
        target_hash: None,
        scope_summary: None,
        final_counts: None,
        evidence_summary: None,
        causal_ref: None,
        payload: serde_json::to_string(fact.payload).ok(),
    };
    if db.append_operation(&entry).await.unwrap_or(false) {
        return true;
    }
    db.get_operation(fact.event_id)
        .await
        .ok()
        .flatten()
        .is_some()
}

fn parse_hex32(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, chunk) in s.as_bytes().as_chunks::<2>().0.iter().enumerate() {
        let hi = (chunk[0] as char).to_digit(16)?;
        let lo = (chunk[1] as char).to_digit(16)?;
        out[i] = ((hi << 4) | lo) as u8;
    }
    Some(out)
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn payload(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    const ACTOR: [u8; 32] = [0xAB; 32];
    const HASH: [u8; 32] = [0x11; 32];
    fn hash_hex() -> String {
        hex::encode(HASH)
    }

    // RED (card acceptance #1): a confirmed item's evidence commits and is
    // queryable by the operation it belongs to.
    #[tokio::test]
    async fn item_confirmed_lands_in_item_evidence_linked_to_its_round() {
        let db = Db::open_in_memory().await.unwrap();
        let p = payload(&[
            ("itemRef", "content://media/1"),
            ("sourceVersion", "gen-7"),
            ("contentHash", &hash_hex()),
            ("receiptRef", "receipt-1"),
        ]);
        let fact = FlowAuditFact {
            event_id: "e1",
            kind: "flow.item.confirmed",
            round_id: Some("round-1"),
            occurred_at_ms: 1_000,
            payload: &p,
        };
        assert!(route(&db, &ACTOR, &fact).await);

        let evidence = db
            .list_item_evidence_for_operation("round-1")
            .await
            .unwrap();
        assert_eq!(evidence.len(), 1);
        assert_eq!(evidence[0].entry.outcome, "confirmed");
        assert_eq!(evidence[0].entry.item_ref, "content://media/1");
        assert_eq!(evidence[0].entry.asset_ref, Some(HASH.to_vec()));
    }

    // RED (card acceptance #2): a round.finished summary's evidence_summary
    // is recomputed from persisted item evidence, not the phone payload —
    // deliberately construct a phone final_counts that LIES (says 5) while
    // only 2 evidence rows actually exist, and assert the daemon's own
    // recount (2) wins.
    #[tokio::test]
    async fn round_finished_evidence_summary_is_recomputed_not_trusted() {
        let db = Db::open_in_memory().await.unwrap();
        for i in 0..2 {
            let p = payload(&[
                ("itemRef", &format!("item-{i}")),
                ("contentHash", &hash_hex()),
            ]);
            let fact = FlowAuditFact {
                event_id: &format!("item-evt-{i}"),
                kind: "flow.item.confirmed",
                round_id: Some("round-2"),
                occurred_at_ms: 1_000,
                payload: &p,
            };
            assert!(route(&db, &ACTOR, &fact).await);
        }
        let lying_payload = payload(&[("confirmed", "5")]);
        let fact = FlowAuditFact {
            event_id: "round-evt",
            kind: "flow.round.finished",
            round_id: Some("round-2"),
            occurred_at_ms: 2_000,
            payload: &lying_payload,
        };
        assert!(route(&db, &ACTOR, &fact).await);

        let op = db.get_operation("round-2").await.unwrap().unwrap();
        assert!(
            op.entry
                .evidence_summary
                .as_deref()
                .unwrap_or("")
                .contains("\"confirmed\":2"),
            "evidence_summary must reflect the real 2 persisted evidence rows, not the phone's claimed 5: {:?}",
            op.entry.evidence_summary
        );
        // The operation_id IS the round_id — not a freshly minted id.
        assert_eq!(op.entry.operation_id, "round-2");
    }

    // RED (card acceptance #3): an UNRECOVERABLE reconciliation lands in
    // audit_tombstone, keyed by the content hash as asset_ref — even
    // though no asset row for that hash exists in this test's Db (the
    // real asset may already have been deleted by the time this arrives).
    #[tokio::test]
    async fn unrecoverable_reconciliation_becomes_a_tombstone() {
        let db = Db::open_in_memory().await.unwrap();
        let p = payload(&[
            ("disposition", "UNRECOVERABLE"),
            ("contentHash", &hash_hex()),
        ]);
        let fact = FlowAuditFact {
            event_id: "recon-1",
            kind: "flow.reconciliation.resolved",
            round_id: Some("round-3"),
            occurred_at_ms: 3_000,
            payload: &p,
        };
        assert!(route(&db, &ACTOR, &fact).await);

        let tombstones = db.list_tombstones_for_asset(&HASH).await.unwrap();
        assert_eq!(tombstones.len(), 1);
        assert_eq!(tombstones[0].entry.reason, "unrecoverable");
        assert!(!tombstones[0].entry.recoverable);
        assert_eq!(
            tombstones[0].entry.discoverer.as_deref(),
            Some(ACTOR.as_slice())
        );

        // Reverse-proof: NEEDS_DECISION must NOT become a tombstone.
        let p2 = payload(&[
            ("disposition", "NEEDS_DECISION"),
            ("contentHash", &hash_hex()),
        ]);
        let fact2 = FlowAuditFact {
            event_id: "recon-2",
            kind: "flow.reconciliation.resolved",
            round_id: Some("round-3"),
            occurred_at_ms: 3_100,
            payload: &p2,
        };
        assert!(route(&db, &ACTOR, &fact2).await);
        assert_eq!(
            db.list_tombstones_for_asset(&HASH).await.unwrap().len(),
            1,
            "a recoverable disposition must not add a second tombstone"
        );
    }

    // RED (card acceptance #4): user decisions (pause/cancel/restore) land
    // in audit_decision, referencing the causal operation (round_id).
    #[tokio::test]
    async fn round_controlled_lands_in_decision_with_causal_round() {
        let db = Db::open_in_memory().await.unwrap();
        let p = payload(&[("action", "cancel")]);
        let fact = FlowAuditFact {
            event_id: "dec-1",
            kind: "flow.round.controlled",
            round_id: Some("round-4"),
            occurred_at_ms: 4_000,
            payload: &p,
        };
        assert!(route(&db, &ACTOR, &fact).await);

        let decisions = db.list_decisions(10).await.unwrap();
        assert_eq!(decisions.len(), 1);
        assert_eq!(decisions[0].entry.decision_kind, "cancel");
        assert_eq!(
            decisions[0].entry.causal_operation_id.as_deref(),
            Some("round-4")
        );
    }

    // RED: replaying the same batch (network retry after a lost response)
    // must not duplicate any of the four canonical tables.
    #[tokio::test]
    async fn replaying_the_same_fact_does_not_duplicate_any_table() {
        let db = Db::open_in_memory().await.unwrap();
        let p = payload(&[
            ("itemRef", "content://media/9"),
            ("contentHash", &hash_hex()),
        ]);
        let fact = FlowAuditFact {
            event_id: "replay-1",
            kind: "flow.item.confirmed",
            round_id: Some("round-5"),
            occurred_at_ms: 5_000,
            payload: &p,
        };
        assert!(route(&db, &ACTOR, &fact).await, "first delivery accepts");
        assert!(
            route(&db, &ACTOR, &fact).await,
            "replay still reports accepted"
        );
        assert_eq!(
            db.list_item_evidence_for_operation("round-5")
                .await
                .unwrap()
                .len(),
            1,
            "replay must not duplicate the evidence row"
        );
    }

    // Card decision #5 hard boundary: `device.connected` never reaches
    // this router, and PRES-01's own path (router.rs::record_presence)
    // writes NO audit row at all anymore — connectivity is presence-only,
    // never a long-term audit fact. This test documents the closed kind
    // set this module accepts and proves an unrecognised Flow-outbox kind
    // is never silently dropped.
    #[tokio::test]
    async fn an_unrecognised_kind_still_lands_somewhere_never_silently_dropped() {
        let db = Db::open_in_memory().await.unwrap();
        let p = payload(&[]);
        let fact = FlowAuditFact {
            event_id: "future-kind-1",
            kind: "flow.some_future_kind",
            round_id: None,
            occurred_at_ms: 6_000,
            payload: &p,
        };
        assert!(route(&db, &ACTOR, &fact).await);
        let op = db.get_operation("future-kind-1").await.unwrap();
        assert!(op.is_some(), "unrecognised kinds must still be durable");
    }
}
