-- AUDIT-04: retire AUDIT-01's `audit_event` catch-all schema outright. The
-- new canonical audit core is four typed tables — audit_operation,
-- audit_item_evidence, audit_tombstone, audit_decision — replacing the
-- single generic `kind` string bucket. No historical audit_event rows are
-- migrated or read; this is a hard cutover (card decision #9). Real backup
-- ledger/receipt/asset data (unrelated tables) is untouched.
--
-- Security/pairing/ingest facts that are NOT Flow backup-operation rounds
-- (pair.*, device.merged/revoked/renamed/unpaired, ingest.*,
-- asset.relocated/replaced_in_place, index.rebuild) keep writing to
-- audit_operation as plain one-shot operations with no item evidence —
-- card decision #1 explicitly allows "备份操作或安全操作" here. Only the
-- Flow round facts AUDIT-01 introduced (flow.round.*, flow.scope.changed,
-- flow.epoch.invalidated, flow.item.attention, flow.reconciliation.resolved)
-- move off this table onto the three new ones (see audit_repo.rs routing).
DROP TABLE IF EXISTS audit_event;

CREATE TABLE audit_operation (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  operation_id     TEXT NOT NULL UNIQUE,   -- idempotency key (phone round_id, or daemon/phone-minted event id)
  occurred_at      INTEGER NOT NULL,       -- unix ms: when the fact happened
  confirmed_at     INTEGER,                -- unix ms: when Desktop durably confirmed it (NULL when not applicable)
  actor            BLOB,                   -- acting device NodeId; NULL = unattributable/system
  actor_name       TEXT,                   -- display-name snapshot at occurrence time
  kind             TEXT NOT NULL,          -- e.g. flow.round.finished, pair.accepted, device.revoked
  trigger          TEXT,                   -- what triggered it (user/auto/system), free text
  round_id         TEXT,                   -- causal Flow round id, when applicable (== operation_id for Flow rows)
  target_hash      BLOB,                   -- asset hash, when applicable
  scope_summary    TEXT,                   -- JSON: scope revision / collection digest
  final_counts     TEXT,                   -- JSON: terminal counts as reported by the origin (advisory)
  evidence_summary TEXT,                   -- JSON: object evidence collection digest (recomputed from audit_item_evidence)
  causal_ref       TEXT,                   -- id of the operation/decision/tombstone that caused this one
  payload          TEXT,                   -- JSON: free-form per-kind fields
  schema_version   INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_audit_operation_occurred ON audit_operation(occurred_at DESC);
CREATE INDEX idx_audit_operation_round ON audit_operation(round_id);

CREATE TABLE audit_item_evidence (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  evidence_id    TEXT NOT NULL UNIQUE,   -- idempotency key
  operation_id   TEXT,                   -- the operation this item belongs to (== round_id for Flow items); no hard FK, evidence must outlive the operation row
  item_ref       TEXT NOT NULL,          -- stable item identity (phone sourceRef+sourceVersion, or content-hash string)
  source_version TEXT,
  content_hash   BLOB,
  receipt_ref    TEXT,
  asset_ref      BLOB,                   -- asset.hash at evidence time; NOT a FK — must survive asset row deletion (card decision #3)
  outcome        TEXT NOT NULL,          -- confirmed | duplicate | failed | source_missing | remote_missing
  occurred_at    INTEGER NOT NULL,
  payload        TEXT
);
CREATE INDEX idx_audit_item_evidence_operation ON audit_item_evidence(operation_id);
CREATE INDEX idx_audit_item_evidence_asset ON audit_item_evidence(asset_ref);

CREATE TABLE audit_tombstone (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  tombstone_id TEXT NOT NULL UNIQUE,
  item_ref     TEXT,
  asset_ref    BLOB NOT NULL,           -- the asset hash that left; NOT a FK — must outlive asset row deletion
  evidence_ref TEXT,                    -- evidence_id this tombstone relates to, if any
  reason       TEXT NOT NULL,           -- external_delete | product_delete | unrecoverable
  discoverer   BLOB,                    -- actor NodeId; NULL = system/filesystem (unattributable)
  occurred_at  INTEGER NOT NULL,
  recoverable  INTEGER NOT NULL DEFAULT 0,
  payload      TEXT
);
CREATE INDEX idx_audit_tombstone_asset ON audit_tombstone(asset_ref);

CREATE TABLE audit_decision (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  decision_id         TEXT NOT NULL UNIQUE,
  decision_kind       TEXT NOT NULL,    -- cancel | restore | give_up_recovery | scope_changed | revoke_authorization
  actor               BLOB,
  causal_operation_id TEXT,
  causal_object_ref   TEXT,             -- item_ref / asset_ref hex / tombstone_id
  occurred_at         INTEGER NOT NULL,
  payload             TEXT
);
CREATE INDEX idx_audit_decision_occurred ON audit_decision(occurred_at DESC);
