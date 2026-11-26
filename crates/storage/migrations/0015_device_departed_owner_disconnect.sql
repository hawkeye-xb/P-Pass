-- #2079：在 device_profile.departed_by 的 CHECK 约束中新增 'owner_disconnect'。
-- SQLite 不支持原地修改 CHECK 约束，因此新建临时表拷入全部行后替换旧表。
-- 由于 pairing(node_id) 引用 device_profile(node_id)，而 sqlx-sqlite 的迁移总是包在
-- 事务内执行（SQLite 事务内禁止开关 foreign_keys），外键检查的临时关闭与恢复由
-- db.rs 的迁移入口在事务外完成；此处不改动 pairing 表（满足 B.3 门禁），亦不使用
-- `ALTER TABLE device_profile RENAME TO ...` 以免 SQLite 自动改写 pairing 外键指向。

CREATE TABLE device_profile_new (
  node_id        BLOB PRIMARY KEY,
  name           TEXT NOT NULL,
  first_seen_at  INTEGER NOT NULL,
  last_seen_at   INTEGER,
  departed_at    INTEGER,
  departed_by    TEXT CHECK (departed_by IN ('device', 'owner', 'identity', 'owner_disconnect'))
);

INSERT INTO device_profile_new (
  node_id, name, first_seen_at, last_seen_at, departed_at, departed_by
)
SELECT
  node_id, name, first_seen_at, last_seen_at, departed_at, departed_by
FROM device_profile;

DROP TABLE device_profile;

ALTER TABLE device_profile_new RENAME TO device_profile;
