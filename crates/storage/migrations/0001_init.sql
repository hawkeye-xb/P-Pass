-- P-Pass index schema — 架构文档 §5 v1.1, implemented verbatim (T-010).
-- The index is derived data: the original files are the truth and this
-- database can be rebuilt from them at any time (ADR-006, T-012).
-- All timestamps are unix epoch MILLISECONDS.

CREATE TABLE asset (
  hash        BLOB PRIMARY KEY,          -- BLAKE3 32B（与 iroh-blobs 同源）
  rel_path    TEXT NOT NULL,             -- originals/ 下相对路径
  media_type  TEXT NOT NULL,             -- image/heic, video/mp4 ...
  bytes       INTEGER NOT NULL,
  taken_at    INTEGER,                   -- EXIF 优先，缺失回退 mtime（时间线键）
  width       INTEGER,
  height      INTEGER,
  src_device  BLOB NOT NULL,             -- 上传者 NodeId
  added_at    INTEGER NOT NULL,
  thumb_state INTEGER NOT NULL DEFAULT 0 -- 0待生成 1完成 2失败
);
CREATE INDEX idx_timeline ON asset(taken_at DESC, hash);

CREATE TABLE device (
  node_id     BLOB PRIMARY KEY,
  name        TEXT NOT NULL,
  role        TEXT NOT NULL CHECK(role IN ('owner','member','viewer')),
  paired_at   INTEGER NOT NULL,
  last_seen   INTEGER,
  revoked     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE backup_watermark (           -- 每设备增量水位（服务端侧防重）
  node_id     BLOB PRIMARY KEY REFERENCES device(node_id),
  last_gen    INTEGER,                    -- Android MediaStore generation
  updated_at  INTEGER
);

CREATE TABLE diag_event (                 -- 环形保留 30 天，喂 diag.status 与日志导出
  ts INTEGER, kind TEXT, detail TEXT
);

CREATE TABLE audit_log (                  -- v1.1：操作审计，长期保留（不设环形上限）
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ts          INTEGER NOT NULL,           -- 何时（unix ms）
  actor       BLOB,                       -- 操作设备 NodeId；外部变动为 NULL（无法归因）
  action      TEXT NOT NULL,              -- backup.commit / pair / revoke / external.delete ...
  target_hash BLOB,                       -- 涉及的资产哈希（可空：如 pair）
  detail      TEXT                        -- 补充（相对路径、错误码等）
);
CREATE INDEX idx_audit_ts ON audit_log(ts DESC);
