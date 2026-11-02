#!/usr/bin/env bash
# tools/check-disk-growth.py 的自测：未登记的新落盘目录必须红，还原必须绿。
set -uo pipefail
. "$(dirname "$0")/fitness-test-lib.sh"
CHECK=check-disk-growth.py
new_repo disk-growth-registry.txt 'dir|staging|基线：启动清扫，过宽限即删'

echo "占盘 1x 结构信号门禁自测"
put crates/daemon/src/a.rs 'fn d(root: &Path) -> PathBuf { root.join(".ppf/staging") }'
expect_green "基线：已登记目录通过"

put crates/storage/src/q.rs 'const QUARANTINE_DIR: &str = ".ppf/quarantine";'
expect_red "新增 .ppf/quarantine（未登记）" "dir|quarantine"
unput crates/storage/src/q.rs; expect_green "还原：quarantine"
put crates/storage/src/t.rs 'fn t(r: &Path) -> PathBuf { r.join("trash") }'
expect_red "新增 .join(\"trash\")" "dir|trash"
unput crates/storage/src/t.rs
put crates/core-index/src/c.rs 'pub const IMAGE_CACHE_DIR: &str = "image-cache";'
expect_red "新增 *_DIR 常量含 cache" "dir|image-cache"
unput crates/core-index/src/c.rs
put crates/daemon/src/z.rs 'fn d(root: &Path) -> PathBuf { root.join(".ppf/spill") }'
expect_red "新增任意 .ppf/<目录>" "dir|spill"
unput crates/daemon/src/z.rs; expect_green "还原：全部"

put crates/daemon/src/t2.rs 'fn real() {}
#[cfg(test)]
mod t { fn x() { let _ = std::path::Path::new(".ppf/only-in-test"); } }'
expect_green "#[cfg(test)] 内的目录不算"
unput crates/daemon/src/t2.rs

cp "$R/tools/disk-growth-registry.txt" "$TMP/base.txt"
printf 'dir|ghost\n' >>"$R/tools/disk-growth-registry.txt"
expect_red "登记缺清理触发条件" "说明不许留空"
cp "$TMP/base.txt" "$R/tools/disk-growth-registry.txt"
printf 'dir|ghost|不存在了\n' >>"$R/tools/disk-growth-registry.txt"
expect_red "登记了但代码里已找不到" "已找不到"
cp "$TMP/base.txt" "$R/tools/disk-growth-registry.txt"
expect_green "还原：登记表"
finish
