-- AUDIT-01: audit_event v2 is the sole long-term audit source. audit_log and
-- its action/detail free-text projection are eliminated outright — no
-- migration, no compatibility read path. Historical v1 rows are not carried
-- forward and are not fabricated as v2 facts (card decision #1).
--
-- event_id is the idempotency key: a phone-side ledger outbox event and a
-- daemon-retried delivery both write the SAME event_id, so UNIQUE + INSERT
-- OR IGNORE makes replay/retransmission a no-op instead of a duplicate row.
-- Daemon-originated events (pairing, revoke, external delete — this process
-- is the sole writer, no retry path) mint a fresh random event_id per write.
DROP TABLE IF EXISTS audit_log;

CREATE TABLE audit_event (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id    TEXT NOT NULL UNIQUE,      -- idempotency key (phone UUID or daemon-minted)
  ts          INTEGER NOT NULL,          -- unix ms
  actor       BLOB,                      -- acting device NodeId; NULL = unattributable
  kind        TEXT NOT NULL,             -- e.g. flow.round.finished, pair.accepted
  round_id    TEXT,                      -- persistent Flow window id, when applicable
  target_hash BLOB,                      -- asset hash, when applicable
  payload     TEXT                       -- JSON object, structured per-kind fields
);
CREATE INDEX idx_audit_event_ts ON audit_event(ts DESC);
CREATE INDEX idx_audit_event_round ON audit_event(round_id);
