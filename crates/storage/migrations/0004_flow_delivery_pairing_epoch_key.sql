-- REBUILD-07: a Flow queue sequence belongs to one pairing epoch, not to a
-- device's whole lifetime. Preserve historical receipts while allowing the
-- same stable NodeId to restart its queue after owner-approved re-pairing.
CREATE TABLE flow_delivery_rekeyed (
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
  PRIMARY KEY (node_id, pairing_epoch, queue_sequence)
);

INSERT INTO flow_delivery_rekeyed (
  node_id, queue_sequence, pairing_epoch, lease_token, content_hash, file_name,
  media_type, provider, state, receipt_id
)
SELECT
  node_id, queue_sequence, pairing_epoch, lease_token, content_hash, file_name,
  media_type, provider, state, receipt_id
FROM flow_delivery;

DROP TABLE flow_delivery;
ALTER TABLE flow_delivery_rekeyed RENAME TO flow_delivery;
