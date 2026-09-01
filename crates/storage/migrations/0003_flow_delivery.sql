-- REBUILD-02: the Desktop owns the current pairing epoch and the single
-- active native-fetch grant. A completion receipt exists only after the
-- original has been materialized and indexed.
ALTER TABLE device ADD COLUMN pairing_epoch TEXT;

CREATE TABLE flow_delivery (
  node_id       BLOB NOT NULL,
  queue_sequence INTEGER NOT NULL,
  pairing_epoch TEXT NOT NULL,
  lease_token   TEXT NOT NULL,
  content_hash  BLOB NOT NULL,
  file_name     TEXT NOT NULL,
  media_type    TEXT NOT NULL,
  provider      TEXT NOT NULL,
  state         TEXT NOT NULL CHECK(state IN ('active', 'cancelled', 'completed')),
  receipt_id    TEXT,
  PRIMARY KEY (node_id, queue_sequence)
);
