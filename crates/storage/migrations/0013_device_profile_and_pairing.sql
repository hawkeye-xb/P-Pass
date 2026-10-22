-- #1117：设备档案与配对记录拆分（对齐 HomeKit / 蓝牙 / Matter 的 pairing list）。
--
-- 设备档案 = 它是谁：NodeId、名字、首次出现、最后在线、最近一次离开。永不删除，
-- 审计（actor）与照片来源（asset.src_device）都挂 NodeId，不挂配对记录。
-- 配对记录 = 它现在凭什么能连：断开、撤销、换身份时物理删除。它的 id 取代
-- 旧的 pairing_epoch；挂在它上面的传输状态（备份水位、交付租约与回执）外键
-- ON DELETE CASCADE，随记录一起删，不靠手写清理顺序。
--
-- 不考虑旧用户、不迁移旧数据：旧 device / backup_watermark / flow_delivery
-- 整表重建，已配对手机重新扫码（#1109 换身份后本来也要全部重新配对）。
-- 先删子表再删父表：foreign_keys 打开时删父表会被引用它的子行挡住。

DROP TABLE backup_watermark;
DROP TABLE flow_delivery;
DROP TABLE device;

CREATE TABLE device_profile (
  node_id        BLOB PRIMARY KEY,
  name           TEXT NOT NULL,
  first_seen_at  INTEGER NOT NULL,
  last_seen_at   INTEGER,
  departed_at    INTEGER,
  departed_by    TEXT CHECK (departed_by IN ('device', 'owner', 'identity'))
);

CREATE TABLE pairing (
  id         TEXT PRIMARY KEY,
  node_id    BLOB NOT NULL UNIQUE REFERENCES device_profile(node_id),
  role       TEXT NOT NULL CHECK (role IN ('member', 'viewer')),
  paired_at  INTEGER NOT NULL
);

CREATE TABLE backup_watermark (
  pairing_id  TEXT PRIMARY KEY REFERENCES pairing(id) ON DELETE CASCADE,
  last_gen    INTEGER,
  updated_at  INTEGER
);

CREATE TABLE flow_delivery (
  pairing_id      TEXT NOT NULL REFERENCES pairing(id) ON DELETE CASCADE,
  queue_sequence  INTEGER NOT NULL,
  lease_token     TEXT NOT NULL,
  content_hash    BLOB NOT NULL,
  file_name       TEXT NOT NULL,
  media_type      TEXT NOT NULL,
  provider        TEXT NOT NULL,
  state           TEXT NOT NULL CHECK (state IN ('active', 'cancelled', 'completed')),
  receipt_id      TEXT,
  last_resumed_ms INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (pairing_id, queue_sequence)
);
