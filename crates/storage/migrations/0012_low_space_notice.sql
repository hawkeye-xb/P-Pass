-- #1044 B11: 照片库卷低空间通知的布防状态（单行）。过去只存在桌面前端
-- 内存里，重开 App 就重新布防、再弹一次。`armed` = 跌破阈值时该不该通知；
-- `pending_free_bytes` = 已判定该通知、尚未被桌面确认展示的那一次（非 NULL
-- 即待展示，值是判定时的剩余字节数）。
CREATE TABLE low_space_notice (
    id                 INTEGER PRIMARY KEY CHECK (id = 1),
    armed              INTEGER NOT NULL,
    pending_free_bytes INTEGER
);
INSERT INTO low_space_notice (id, armed, pending_free_bytes) VALUES (1, 1, NULL);
