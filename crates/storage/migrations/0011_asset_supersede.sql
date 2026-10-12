-- #851: 用原图替换抹过拍摄地点的旧副本。
--
-- asset_alias：旧指纹 → 替换它的新指纹。旧行删掉之后，手机（或另一台设备）再报旧指纹时，
-- 「库里有没有」按新指纹回答——否则对账会把旧副本当成缺失重新上传，库里多出一份。
-- 链式替换时 new_hash 一律指向最新的那份。
CREATE TABLE asset_alias (
    old_hash      BLOB    PRIMARY KEY,
    new_hash      BLOB    NOT NULL,
    superseded_at INTEGER NOT NULL
);

-- asset_swap_pending：索引已改指新内容、但新文件还没换到 rel_path 上的那一步。
-- 换文件前崩溃时，启动时按这里补完（staged_path 在 .ppf/ 里，与 originals/ 同卷，rename 原子）。
CREATE TABLE asset_swap_pending (
    new_hash    BLOB PRIMARY KEY,
    rel_path    TEXT NOT NULL,
    staged_path TEXT NOT NULL
);
