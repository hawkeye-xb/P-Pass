#!/usr/bin/env bash
# tools/arch-check.sh 的自测（#1040）。
#
# 门禁本身也会坏——B.3 原先逐行 grep，三种写法能绕过，而且没有任何自测，
# 「声称拦得住、实际拦不住」。本脚本给每条规则造**正样例（必须报红）**与
# **反样例（必须不报）**，并对 B.3 做反证：把规则还原成逐行 grep，三个绕过
# 样例必须全部漏报——证明这几个样例确实是在测「跨行/引号/schema」，不是
# 随便写的。
#
# 做法：在临时目录里搭一棵最小仓库，用 ARCH_ROOT 指过去跑真实的
# arch-check.sh。不碰真实代码树。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/arch-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAILED=0

ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAILED=$((FAILED + 1)); echo "  FAIL $1"; }

# 新建一棵空仓库根并返回路径。
new_root() {
  local r
  r="$(mktemp -d "$TMP/root.XXXXXX")"
  mkdir -p "$r/crates/core/src" "$r/crates/platform/src" "$r/apps/desktop/src" \
    "$r/apps/desktop/src-tauri/src" "$r/tools"
  printf '[ratchet]\n\n[permanent]\n' >"$r/tools/arch-allowlist.txt"
  echo "$r"
}

# run <root> [ENV=VAL ...]：跑门禁，输出存到 ${OUT}，退出码返回。
run() {
  local r="$1"; shift
  OUT="$(env ARCH_ROOT="$r" ARCH_RATCHET_SKIP=1 "$@" bash "$CHECK" 2>&1)"
}

# expect_red <描述> <root> <必须出现在输出里的子串> [ENV...]
expect_red() {
  local d="$1" r="$2" needle="$3"; shift 3
  if run "$r" "$@"; then bad "${d}（应报红，实际通过）"; return; fi
  if printf '%s' "$OUT" | grep -qF -- "$needle"; then ok "$d"; else bad "${d}（红了但没有 '$needle'）"; echo "$OUT" | sed 's/^/       /'; fi
}
expect_green() {
  local d="$1" r="$2"; shift 2
  if run "$r" "$@"; then ok "$d"; else bad "${d}（应通过，实际报红）"; echo "$OUT" | sed 's/^/       /'; fi
}

# 一个样例 = 一个新根 + 一个文件。
sample() { # <相对路径> <内容>
  local r; r="$(new_root)"
  mkdir -p "$(dirname "$r/$1")"
  printf '%s\n' "$2" >"$r/$1"
  echo "$r"
}

echo "== 基线：空仓库必须通过"
expect_green "空仓库" "$(new_root)"

# ── B.3 ────────────────────────────────────────────
echo "== B.3 正样例（必须报红）"
B3_PLAIN='let _ = "DELETE FROM device_profile WHERE id = ?";'
B3_MULTILINE='let _ = "DELETE
        FROM device_profile WHERE id = ?";'
B3_QUOTED='let _ = r#"DELETE FROM "device_profile" WHERE id = ?"#;'
B3_SCHEMA='let _ = "DELETE FROM main.device_profile WHERE id = ?";'
B3_AUDIT_ML='let _ = "delete  from
    audit_operation";'
B3_RUST_CONT='let _ = "DELETE \
    FROM audit_decision";'
B3_ESC_QUOTE='let _ = "DELETE FROM \"main\".\"device_profile\"";'
B3_SQLFILE='DELETE
  FROM [audit_event];'
for pair in "plain:$B3_PLAIN" "multiline:$B3_MULTILINE" "quoted:$B3_QUOTED" \
            "schema-prefix:$B3_SCHEMA" "audit+multiline:$B3_AUDIT_ML" \
            "rust-line-continuation:$B3_RUST_CONT" "escaped-quotes+schema:$B3_ESC_QUOTE"; do
  expect_red "B.3 ${pair%%:*}" "$(sample crates/core/src/a.rs "${pair#*:}")" "B.3 VIOLATION"
done
expect_red "B.3 .sql 文件 + 方括号 + 跨行" "$(sample crates/core/migrations/1.sql "$B3_SQLFILE")" "B.3 VIOLATION"

echo "== B.3 配对记录：只许在 crates/storage/src/device_repo.rs 里删除（#1117）"
B3_PAIRING='let _ = "DELETE
    FROM pairing WHERE node_id = ?";'
expect_red "B.3 别处删配对记录" "$(sample crates/daemon/src/a.rs "$B3_PAIRING")" "配对记录只许在"
expect_red "B.3 storage 里别的文件删配对记录" "$(sample crates/storage/src/other_repo.rs "$B3_PAIRING")" "配对记录只许在"
expect_green "B.3 device_repo.rs 删配对记录" "$(sample crates/storage/src/device_repo.rs "$B3_PAIRING")"
expect_green "B.3 删 pairing_x 不误报" "$(sample crates/daemon/src/a.rs 'let _ = "DELETE FROM pairing_requests";')"
for pair in \
  "INSERT:let _ = \"INSERT INTO pairing (id) VALUES (?)\";" \
  "INSERT OR REPLACE:let _ = \"INSERT OR REPLACE INTO pairing (id) VALUES (?)\";" \
  "REPLACE INTO:let _ = \"REPLACE INTO pairing (id) VALUES (?)\";" \
  "UPDATE 跨行:let _ = \"UPDATE
    pairing SET role = ?\";" \
  "UPDATE OR IGNORE:let _ = \"UPDATE OR IGNORE main.pairing SET role = ?\";"; do
  expect_red "B.3 别处写配对记录：${pair%%:*}" "$(sample crates/daemon/src/a.rs "${pair#*:}")" "配对记录只许在"
done
expect_green "B.3 device_repo.rs 写配对记录" "$(sample crates/storage/src/device_repo.rs 'let _ = "INSERT INTO pairing (id) VALUES (?)";')"
expect_green "B.3 别处只读配对记录" "$(sample crates/daemon/src/a.rs 'let _ = "SELECT id FROM pairing";')"
expect_green "B.3 UPDATE 档案、子查询读 pairing" "$(sample crates/daemon/src/a.rs 'let _ = "UPDATE device_profile SET x = 1 WHERE node_id IN (SELECT node_id FROM pairing)";')"

# ── B.5 ────────────────────────────────────────────
echo "== B.5 授权点只读内存副本（#1117）"
expect_red "B.5 authz.rs 查库取设备" "$(sample crates/daemon/src/authz.rs 'let d = db.get_device(&peer).await;')" "B.5 VIOLATION"
expect_red "B.5 router.rs 列配对记录（跨行）" "$(sample crates/daemon/src/router.rs 'let all = self.db
    .list_pairings().await;')" "B.5 VIOLATION"
expect_red "B.5 blobs_gate.rs 直接查 pairing 表" "$(sample crates/daemon/src/blobs_gate.rs 'let _ = "SELECT role FROM pairing WHERE node_id = ?";')" "B.5 VIOLATION"
expect_red "B.5 download.rs 列设备" "$(sample crates/daemon/src/download.rs 'let d = db.list_devices().await;')" "B.5 VIOLATION"
expect_green "B.5 授权点读内存副本" "$(sample crates/daemon/src/router.rs 'let p = self.db.active_pairing(&peer.0);')"
expect_green "B.5 非授权点查库不管" "$(sample crates/daemon/src/ipc.rs 'let d = db.get_device(&peer).await;')"
expect_green "B.5 测试模块里查库不管" "$(sample crates/daemon/src/router.rs 'fn x() {}
#[cfg(test)]
mod tests {
    async fn t(db: Db) { db.get_device(&[0; 32]).await.unwrap(); }
}')"

# ── B.4 ────────────────────────────────────────────
echo "== B.4 正样例（审计 / 照片来源挂了配对记录，必须报红）"
expect_red "B.4 审计表加 pairing_id 列" "$(sample crates/storage/migrations/9.sql 'ALTER TABLE audit_operation ADD COLUMN pairing_id TEXT;')" "B.4 VIOLATION"
expect_red "B.4 asset 表外键到 pairing（跨行）" "$(sample crates/storage/migrations/9.sql 'CREATE TABLE asset_x (
  hash BLOB PRIMARY KEY,
  src REFERENCES pairing(id)
);')" "B.4 VIOLATION"
expect_red "B.4 audit_repo.rs 用 pairing_id" "$(sample crates/storage/src/audit_repo.rs 'let _ = "INSERT INTO audit_operation (pairing_id) VALUES (?)";')" "B.4 VIOLATION"
echo "== B.4 反样例（必须不报）"
expect_green "B.4 传输表挂配对记录" "$(sample crates/storage/migrations/9.sql 'CREATE TABLE backup_watermark (pairing_id TEXT REFERENCES pairing(id) ON DELETE CASCADE);')"
expect_green "B.4 审计表只挂 NodeId" "$(sample crates/storage/migrations/9.sql 'CREATE TABLE audit_x (actor BLOB);
CREATE TABLE pairing (id TEXT PRIMARY KEY);')"

echo "== B.3 反样例（必须不报）"
for pair in \
  "device_token 表:let _ = \"DELETE FROM device_token WHERE id = ?\";" \
  "devices 复数表:let _ = \"DELETE FROM devices WHERE id = ?\";" \
  "SELECT FROM device_profile:let _ = \"SELECT id FROM device_profile WHERE departed_at IS NULL\";" \
  "UPDATE 档案:let _ = \"UPDATE device_profile SET departed_at = 1 WHERE id = ?\";" \
  "删别的表、子查询里读档案:let _ = \"DELETE FROM asset WHERE owner IN (SELECT id FROM device_profile)\";" \
  "跨行删别的表:let _ = \"DELETE
    FROM asset WHERE id = ?\";" \
  "schema 前缀的别的表:let _ = \"DELETE FROM main.device_profile_log\";"; do
  expect_green "B.3 ${pair%%:*}" "$(sample crates/core/src/a.rs "${pair#*:}")"
done

echo "== B.3 反证：还原成逐行 grep，三个绕过样例必须全部漏报"
legacy_hits() { # <内容> → 逐行 grep 的命中数（改前的规则原文）
  printf '%s\n' "$1" | grep -ciE 'DELETE[[:space:]]+FROM[[:space:]]+(device_profile|audit_[a-z_]+)\b' || true
}
for pair in "跨行:$B3_MULTILINE" "引号:$B3_QUOTED" "schema 前缀:$B3_SCHEMA"; do
  n="$(legacy_hits "${pair#*:}")"
  if [ "$n" = "0" ]; then ok "逐行 grep 漏掉「${pair%%:*}」（新规则能拦，见上）"; else bad "逐行 grep 居然拦住了「${pair%%:*}」——样例没有测到绕过"; fi
done
n="$(legacy_hits "$B3_PLAIN")"
[ "$n" != "0" ] && ok "逐行 grep 能拦住最朴素的写法（反证的对照组有效）" || bad "对照组失效"

# ── G1 ─────────────────────────────────────────────
echo "== G1 正样例（壳里各种越界，必须报红；ARCH_ROOT 下白名单为空）"
g1_red() { # <描述> <相对路径> <内容>
  expect_red "G1 $1" "$(sample "$2" "$3")" "G1 VIOLATION"
}
g1_red "plugin-os 判平台" apps/desktop/src/a.js 'import { platform } from "@tauri-apps/plugin-os";'
g1_red "navigator.platform" apps/desktop/src/a.js 'const isMac = navigator.platform.startsWith("Mac");'
g1_red "navigator.userAgent" apps/desktop/src/a.svelte 'const win = /Windows/.test(navigator.userAgent);'
g1_red "process.platform" apps/desktop/src/a.js 'if (process.platform === 1) {}'
g1_red "字面量 windows 比较" apps/desktop/src/a.svelte 'if (p === "windows") { go(); }'
g1_red "字面量 macos(单引号)" apps/desktop/src/a.js "if (p === 'macos') go();"
g1_red "Windows 错误原文" apps/desktop/src/a.svelte 'if (/access is denied/i.test(msg)) {}'
g1_red "JS 读 HOME" apps/desktop/src/a.js 'const h = process.env.HOME;'
g1_red "Rust 读 HOME" apps/desktop/src-tauri/src/a.rs 'let h = std::env::var("HOME").unwrap();'
g1_red "Rust 读 USERPROFILE" apps/desktop/src-tauri/src/a.rs 'let h = std::env::var_os("USERPROFILE");'
g1_red "Rust 读 LANG" apps/desktop/src-tauri/src/a.rs 'let l = env::var("LANG").unwrap_or_default();'
g1_red "Rust 跨行读 LANG" apps/desktop/src-tauri/src/a.rs 'let l = std::env::var(
    "LANG",
);'
g1_red "Rust consts::OS" apps/desktop/src-tauri/src/a.rs 'let os = std::env::consts::OS;'
g1_red "拼 plist 路径" apps/desktop/src-tauri/src/a.rs 'let p = home.join("com.hawkeyexb.ppass.desktop.daemon.plist");'
g1_red "LaunchAgents 目录" apps/desktop/src-tauri/src/a.rs 'let d = home.join("Library/LaunchAgents");'

echo "== G1 反样例（必须不报）"
g1_green() { expect_green "G1 $1" "$(sample "$2" "$3")"; }
g1_green "注释里讲 HOME / plist" apps/desktop/src-tauri/src/a.rs '// 不要读 std::env::var("HOME")，日志路径从 plist 读
/// LaunchAgents/com.hawkeyexb.ppass.desktop.daemon.plist 才是真相
//! navigator.platform 也不能用'
g1_green "块注释里讲 plugin-os" apps/desktop/src/a.js '/**
 * 以前用 @tauri-apps/plugin-os 判平台
 */
export const x = 1;'
g1_green "svelte 注释" apps/desktop/src/a.svelte '<!-- process.platform / "windows" 都不要 -->
<p>ok</p>'
g1_green "名字相近的环境变量" apps/desktop/src-tauri/src/a.rs 'let h = std::env::var("PPASS_HOME").ok();
let q = std::env::var("HOMEPAGE").ok();'
g1_green "bin 根上的 windows_subsystem（与 B.2 同一条豁免）" apps/desktop/src-tauri/src/main.rs '#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]'
g1_green "测试文件不扫（*.test.js）" apps/desktop/src/a.test.js 'vi.mock("@tauri-apps/plugin-os", () => ({ platform: () => "macos" }));'
g1_green "testSetup.js 不扫" apps/desktop/src/testSetup.js 'vi.mock("@tauri-apps/plugin-os", () => ({ platform: () => "macos" }));'
g1_green "不在 apps/desktop 下（crates 里读 HOME 归别的规则）" crates/core/src/a.rs 'let h = std::env::var("HOME").unwrap();'

# ── G5 ─────────────────────────────────────────────
echo "== G5 正样例（必须报红）"
g5_red() { expect_red "G5 $1" "$(sample "$2" "$3")" "G5 VIOLATION"; }
g5_red "crates 里 std::os::unix" crates/core/src/a.rs 'use std::os::unix::fs::MetadataExt;'
g5_red "crates 里 std::os::windows" crates/core/src/a.rs 'use std::os::windows::ffi::OsStrExt;'
g5_red "crates 里 consts::OS" crates/core/src/a.rs 'let os = std::env::consts::OS;'
g5_red "apps 里 std::os::unix" apps/desktop/src-tauri/src/a.rs 'use std::os::unix::process::CommandExt;'
g5_red "launchctl" crates/core/src/a.rs 'let _ = Command::new("launchctl").arg("list").output();'
g5_red "powershell(跨行)" crates/core/src/a.rs 'let _ = Command::new(
    "powershell",
).output();'
g5_red "pmset" crates/core/src/a.rs 'Command::new("pmset")'
g5_red "Cargo.toml 依赖 windows-sys" crates/core/Cargo.toml '[dependencies]
windows-sys = "0.59"'
g5_red "Cargo.toml 依赖 objc2 带 features" crates/core/Cargo.toml '[dependencies]
objc2 = { version = "0.5" }'
g5_red "Cargo.toml 依赖 nix" apps/desktop/src-tauri/Cargo.toml '[dependencies]
nix = "0.29"'

echo "== G5 反样例（必须不报）"
g5_green() { expect_green "G5 $1" "$(sample "$2" "$3")"; }
g5_green "crates/platform 里随便用" crates/platform/src/a.rs 'use std::os::unix::fs::MetadataExt;
let os = std::env::consts::OS;
let _ = Command::new("launchctl");'
g5_green "crates/platform 的 Cargo.toml 可依赖平台 crate" crates/platform/Cargo.toml '[dependencies]
windows-sys = "0.59"
objc2 = "0.5"'
g5_green "普通命令" crates/core/src/a.rs 'let _ = Command::new("ffmpeg");
let _ = Command::new("git");'
g5_green "注释里提 launchctl / std::os::unix" crates/core/src/a.rs '// 以前这里 Command::new("launchctl")，现在走 adapter
/// std::os::unix 只在 platform 里用'
g5_green "Cargo.toml 注释与名字相近的依赖" crates/core/Cargo.toml '[dependencies]
# nix = "0.29"  不要
nixpkgs-fetcher = "1"
windowing = "1"'

# ── 白名单 ─────────────────────────────────────────
echo "== 白名单：登记 / 过期 / 只降不升"
mk_allow_root() { # <relpath> <content> <allowlist 内容>
  local r; r="$(sample "$1" "$2")"
  printf '%s\n' "$3" >"$r/tools/arch-allowlist.txt"
  echo "$r"
}
SRC_ONE='let h = std::env::var("HOME").unwrap();'
SRC_TWO='let h = std::env::var("HOME").unwrap();
let l = std::env::var("LANG").unwrap();'
F=apps/desktop/src-tauri/src/a.rs

expect_green "命中被登记 → 通过" "$(mk_allow_root $F "$SRC_ONE" "[ratchet]
$F | G1 | 1 | 测试夹具
[permanent]")"
expect_red "同文件再多一处 → 报新增越界" "$(mk_allow_root $F "$SRC_TWO" "[ratchet]
$F | G1 | 1 | 测试夹具
[permanent]")" "新增越界"
expect_red "命中少于登记 → 白名单过期要缩表" "$(mk_allow_root $F "$SRC_ONE" "[ratchet]
$F | G1 | 2 | 测试夹具
[permanent]")" "白名单过期"
expect_red "登记了但已无命中 → 过期条目报错" "$(mk_allow_root $F 'let x = 1;' "[ratchet]
$F | G1 | 1 | 测试夹具
[permanent]")" "已无命中"
expect_red "命中了别的文件 → 未登记" "$(mk_allow_root apps/desktop/src-tauri/src/b.rs "$SRC_ONE" "[ratchet]
$F | G1 | 1 | 测试夹具
[permanent]")" "未登记的新越界"
expect_red "白名单格式错：缺理由" "$(mk_allow_root $F "$SRC_ONE" "[ratchet]
$F | G1 | 1
[permanent]")" "格式"
expect_red "白名单格式错：计数不是数字" "$(mk_allow_root $F "$SRC_ONE" "[ratchet]
$F | G1 | many | x
[permanent]")" "计数"
expect_red "重复条目" "$(mk_allow_root $F "$SRC_ONE" "[ratchet]
$F | G1 | 1 | a
$F | G1 | 1 | b
[permanent]")" "重复"
R="$(sample $F "$SRC_ONE")"; rm "$R/tools/arch-allowlist.txt"
expect_red "白名单文件缺失 → 失败（不放行）" "$R" "找不到白名单"
expect_green "永久例外：命中被豁免且不计数" "$(mk_allow_root $F "$SRC_ONE" "[ratchet]
[permanent]
$F | G1 | 客观平台差异（测试）")"
expect_red "永久例外：已无命中也算过期" "$(mk_allow_root $F 'let x = 1;' "[ratchet]
[permanent]
$F | G1 | 客观平台差异（测试）")" "已无命中"

echo "== 只报告模式"
R="$(sample $F "$SRC_ONE")"
if run "$R" ARCH_REPORT_ONLY=1 && printf '%s' "$OUT" | grep -q "G1  $F:1"; then ok "只报告：列出命中且不判红（白名单为空也不红）"; else bad "只报告模式"; echo "$OUT" | sed 's/^/       /'; fi

# ── ratchet（相对基线分支只降不升）──────────────────
echo "== ratchet：白名单相对基线不许变大"
mk_git_root() { # <base 白名单> <当前白名单> → 在 git 仓库里：基线提交 + 工作区改成当前
  local r; r="$(sample $F "$SRC_ONE")"
  (
    cd "$r" || exit 1
    git init -q . && git config user.email t@t && git config user.name t
    printf '%s\n' "$1" >tools/arch-allowlist.txt
    git add -A && git -c core.hooksPath=/dev/null commit -qm base
    printf '%s\n' "$2" >tools/arch-allowlist.txt
  )
  echo "$r"
}
run_ratchet() { OUT="$(env ARCH_ROOT="$1" ARCH_BASE_REF=HEAD "${@:2}" bash "$CHECK" 2>&1)"; }
BASE1="[ratchet]
$F | G1 | 1 | x
[permanent]"
R="$(mk_git_root "$BASE1" "$BASE1")"
if run_ratchet "$R"; then ok "白名单与基线一致 → 通过"; else bad "与基线一致应通过"; echo "$OUT" | sed 's/^/       /'; fi

# 当前代码有 2 处，把白名单计数 1 → 2，门禁自身的精确相等校验通过，只有 ratchet 能拦。
R="$(sample $F "$SRC_TWO")"
(
  cd "$R" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  printf '%s\n' "$BASE1" >tools/arch-allowlist.txt
  git add -A && git -c core.hooksPath=/dev/null commit -qm base
  printf '[ratchet]\n%s | G1 | 2 | 偷偷加\n[permanent]\n' "$F" >tools/arch-allowlist.txt
)
if run_ratchet "$R"; then bad "计数 1→2 应被 ratchet 拦下"; else
  printf '%s' "$OUT" | grep -q "变大" && ok "计数 1→2（同时代码也多一处）→ ratchet 报红" || { bad "ratchet 红了但原因不对"; echo "$OUT" | sed 's/^/       /'; }
fi

# 新增一个文件的条目
R="$(sample "$F" "$SRC_ONE")"
mkdir -p "$R/apps/desktop/src-tauri/src"
printf '%s\n' "$SRC_ONE" >"$R/apps/desktop/src-tauri/src/b.rs"
(
  cd "$R" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  printf '%s\n' "$BASE1" >tools/arch-allowlist.txt
  git add -A && git -c core.hooksPath=/dev/null commit -qm base
  printf '[ratchet]\n%s | G1 | 1 | x\napps/desktop/src-tauri/src/b.rs | G1 | 1 | 新条目\n[permanent]\n' "$F" >tools/arch-allowlist.txt
)
if run_ratchet "$R"; then bad "新增条目应被 ratchet 拦下"; else
  printf '%s' "$OUT" | grep -q "变大" && ok "新增条目 → ratchet 报红" || { bad "新增条目：红了但原因不对"; echo "$OUT" | sed 's/^/       /'; }
fi

# 新增永久例外
R="$(sample "$F" "$SRC_ONE")"
(
  cd "$R" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  printf '[ratchet]\n[permanent]\n' >tools/arch-allowlist.txt
  git add -A && git -c core.hooksPath=/dev/null commit -qm base
  printf '[ratchet]\n[permanent]\n%s | G1 | 想蒙混过关\n' "$F" >tools/arch-allowlist.txt
)
if run_ratchet "$R"; then bad "新增永久例外应被拦下"; else
  printf '%s' "$OUT" | grep -q "新增永久例外" && ok "新增永久例外 → ratchet 报红" || { bad "永久例外：红了但原因不对"; echo "$OUT" | sed 's/^/       /'; }
fi

# 缩表：基线 2 → 当前 1（代码也缩到 1）→ 通过
R="$(sample "$F" "$SRC_ONE")"
(
  cd "$R" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  printf '[ratchet]\n%s | G1 | 2 | x\n[permanent]\n' "$F" >tools/arch-allowlist.txt
  git add -A && git -c core.hooksPath=/dev/null commit -qm base
  printf '[ratchet]\n%s | G1 | 1 | x\n[permanent]\n' "$F" >tools/arch-allowlist.txt
)
if run_ratchet "$R"; then ok "缩表（计数 2→1）→ 通过"; else bad "缩表应通过"; echo "$OUT" | sed 's/^/       /'; fi

# 基线上没有白名单（首次引入）→ 通过；基线 ref 不存在：本地警告、CI 失败。
R="$(sample "$F" "$SRC_ONE")"
(
  cd "$R" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  rm tools/arch-allowlist.txt && git add -A && git -c core.hooksPath=/dev/null commit -qm base
  printf '[ratchet]\n%s | G1 | 1 | x\n[permanent]\n' "$F" >tools/arch-allowlist.txt
)
if run_ratchet "$R"; then ok "基线上还没有白名单（首次引入）→ 通过"; else bad "首次引入应通过"; echo "$OUT" | sed 's/^/       /'; fi
OUT="$(env -u CI ARCH_ROOT="$R" ARCH_BASE_REF=no-such-ref bash "$CHECK" 2>&1)" \
  && ok "本地取不到基线 → 仅警告" || { bad "本地取不到基线应只警告"; echo "$OUT" | sed 's/^/       /'; }
OUT="$(env ARCH_ROOT="$R" ARCH_BASE_REF=no-such-ref CI=true bash "$CHECK" 2>&1)" \
  && bad "CI 取不到基线必须失败（fail-closed）" || ok "CI 取不到基线 → 失败（fail-closed）"

# ── G4（#1045）────────────────────────────────────
echo "== G4 正样例（壳里写 config.toml 的各种写法，必须报红；无白名单）"
SHELL_RS=apps/desktop/src-tauri/src/a.rs
g4_red() { expect_red "G4 $1" "$(sample "$SHELL_RS" "$2")" "G4 VIOLATION"; }
# 改调子命令前壳里的真实写法（逐字摘自 #1045 之前的 write_first_run_config / render_config /
# merge_library_dir）：三个函数名都改掉也必须拦——门禁看的是写法，不是名字。
g4_red "fs::write 写 config.toml（旧 write_first_run_config）" 'fn f(d: &Path, c: &str) -> Result<(), String> {
    std::fs::write(d.join("config.toml"), c).map_err(|e| e.to_string())
}'
g4_red "config.toml 在写 API 之后、跨行" 'std::fs::write(
    platform_dir.join("config.toml"),
    merged,
)'
g4_red "File::create" 'let f = std::fs::File::create(dir.join("config.toml"))?;'
g4_red "OpenOptions" 'let f = OpenOptions::new().write(true).open(dir.join("config.toml"))?;'
g4_red "fs::rename 覆盖 config.toml" 'std::fs::rename(&tmp, dir.join("config.toml"))?;'
g4_red "config 模板字面量（旧 render_config）" 'fn render(d: &str) -> String {
    format!("data_dir = {d}\n\nbind_addr = \"0.0.0.0:41145\"\n")
}'
g4_red "只渲染 relay_urls 模板" 'let t = "relay_urls = []\n";'
g4_red "TOML 序列化（旧 merge_library_dir 的 data_dir 值）" 'let v = toml::Value::String(normalize(dir)).to_string();'
g4_red "toml::to_string" 'let t = toml::to_string(&cfg).unwrap();'
g4_red "toml_edit" 'use toml_edit::Document;'

echo "== G4 反样例（必须不报）"
g4_green() { expect_green "G4 $1" "$(sample "${3:-$SHELL_RS}" "$2")"; }
g4_green "只读 config（toml::Table 解析）" 'let raw = std::fs::read_to_string(dir.join("config.toml")).ok()?;
let t = raw.parse::<toml::Table>().ok()?;'
g4_green "判断 config.toml 是否存在" 'fn configured(d: &Path) -> bool { d.join("config.toml").exists() }'
g4_green "写别的文件（停止标记）" 'fn mark(m: &Path) { std::fs::write(m, b"stopped\n").unwrap(); }
fn cfg(d: &Path) -> PathBuf { d.join("config.toml") }'
g4_green "写与读各自在不同语句（; 隔开）" 'std::fs::write(marker, b"x")?;
let cfg = dir.join("config.toml");'
g4_green "注释里讲 config.toml 与 fs::write" '// 以前这里 std::fs::write(dir.join("config.toml"), …)，现在调 daemon 的 config 子命令
/// data_dir = "x" 的模板归 daemon'
g4_green "文件尾部测试模块里造 config 夹具不算" 'fn product() {}
#[cfg(test)]
mod tests {
    fn fixture(d: &Path) {
        std::fs::write(d.join("config.toml"), "data_dir = \"/x\"\n").unwrap();
    }
}'
g4_green "别的目录（crates/daemon 是 config 的写者）" 'pub fn init(d: &Path) { std::fs::write(d.join("config.toml"), "data_dir = \"/x\"\n").unwrap(); }' crates/daemon/src/config.rs
g4_green "前端 invoke(\"write_config\") 不是写文件" 'await invoke("write_config", { libraryDir });' apps/desktop/src/Wizard.svelte

echo "== G4 反证：测试夹具豁免只认「cfg(test) 紧跟 mod」；挂在别的条目上的不藏后面的代码"
expect_red "G4 #[cfg(test)] use 之后的产品代码仍被扫到" "$(sample "$SHELL_RS" '#[cfg(test)]
use std::fs as _;
fn product(d: &Path) { std::fs::write(d.join("config.toml"), "x").unwrap(); }')" "G4 VIOLATION"

# ── G2（#1046）────────────────────────────────────
echo "== G2 正样例（核心里的托管代码，必须报红；无白名单）"
g2_red() { expect_red "G2 $1" "$(sample crates/daemon/src/a.rs "$2")" "G2 VIOLATION"; }
# 反证样例：#1046 删掉的那段 daemon 接管后重装登记，原样放回必须红。
g2_red "接管后重装登记（#1046 删除的原代码形状）" 'fn f(exe: &Path) {
    let registered = h.autostart_registration();
    if !h.is_install_location(&exe) {} else if let Err(e) = h.install_autostart(&exe) {}
}'
g2_red "绕开 hosting() 入口、换个接收者调托管方法" 'fn f(a: &A) { let _ = a.uninstall_autostart(); }'
g2_red "方法名与括号之间有空白" 'fn f(a: &A) { let _ = a.restart_resident_daemon (true); }'
g2_red "托管类型" 'fn f(m: platform::ServiceMode) {}'
g2_red "直接拼 launchctl" 'fn f() { let _ = platform::command("launchctl"); }'
g2_red "计划任务" 'const T: &str = "schtasks";'
g2_red "测试代码也算（核心的测试也不碰托管）" '#[cfg(test)]
mod tests { fn t() { let _ = a.install_autostart(p); } }'
echo "== G2 反样例（必须不报）"
expect_green "G2 注释里讲托管不算" "$(sample crates/daemon/src/a.rs '// 接管后不再 install_autostart()；launchctl 归发行层
/// 见 HostingAdapter::reconcile_autostart')"
expect_green "G2 crates/platform 自己实现托管不算" "$(sample crates/platform/src/macos.rs 'fn f() { let _ = a.install_autostart(p); let _ = "launchctl"; }')"
expect_green "G2 桌面壳（发行层）调托管不算" "$(sample apps/desktop/src-tauri/src/distribution.rs 'fn f() { let _ = platform::hosting().reconcile_autostart(p); }')"
expect_green "G2 同名前缀的别的符号不算" "$(sample crates/daemon/src/a.rs 'fn f() { let _ = a.install_autostart_hint(); let service_mode = 1; let x = stop_daemon_now(); }')"
echo "== G2 清单与 trait HostingAdapter 的方法一一对应（trait 加方法而 G2 没加 → 红）"
REAL_TRAIT="$HERE/../crates/platform/src/lib.rs"
TRAIT_FNS="$(awk '/^pub trait HostingAdapter/,/^}/' "$REAL_TRAIT" | grep -oE 'fn [a-z_0-9]+' | sed 's/^fn //' | sort -u)"
G2_LIST="$(sed -n "s/^G2_METHODS='\(.*\)'$/\1/p" "$CHECK" | tr '|' '\n' | sort -u)"
if [ -z "$TRAIT_FNS" ]; then
  bad "G2 清单核对：读不到 trait HostingAdapter 的方法"
elif [ "$TRAIT_FNS" = "$G2_LIST" ]; then
  ok "G2 清单覆盖 trait HostingAdapter 全部 $(printf '%s\n' "$TRAIT_FNS" | wc -l | tr -d ' ') 个方法"
else
  bad "G2 清单与 trait HostingAdapter 不一致"
  diff <(printf '%s\n' "$TRAIT_FNS") <(printf '%s\n' "$G2_LIST") | sed 's/^/       /'
fi

# ── G3（#1043）────────────────────────────────────
echo "== G3 正样例（enforce 模式必须报红）"
G3_USE='use platform::HostingAdapter as _;'
G3_CALL='fn f() { let _ = platform::hosting().service_mode(); }'
G3_BRACE_ML='use platform::{
    adapter,
    hosting,
};'
G3_PATH='fn f(h: &dyn platform::HostingAdapter) {}'
for pair in "use-trait:$G3_USE" "call-hosting:$G3_CALL" "brace-use-multiline:$G3_BRACE_ML" "trait-object:$G3_PATH"; do
  expect_red "G3 ${pair%%:*}" "$(sample crates/daemon/src/a.rs "${pair#*:}")" "G3 VIOLATION" ARCH_G3_MODE=enforce
done
echo "== G3 反样例（必须不报）"
expect_green "G3 平台能力入口不算" "$(sample crates/daemon/src/a.rs 'fn f() { let _ = platform::adapter().data_dir(); }')" ARCH_G3_MODE=enforce
expect_green "G3 注释里提到 HostingAdapter 不算" "$(sample crates/daemon/src/a.rs '// HostingAdapter 只给壳用；platform::hosting() 同理')" ARCH_G3_MODE=enforce
expect_green "G3 crates/platform 自己定义托管 trait 不算" "$(sample crates/platform/src/lib.rs 'pub trait HostingAdapter {}
pub fn hosting() {}')" ARCH_G3_MODE=enforce
expect_green "G3 桌面壳用托管能力不算" "$(sample apps/desktop/src-tauri/src/lib.rs 'fn f() { let _ = platform::hosting(); }')" ARCH_G3_MODE=enforce
expect_green "G3 名字里含 hosting 的别的符号不算" "$(sample crates/daemon/src/a.rs 'fn f() { let _ = platform::hosting_hint(); let HostingAdapterX = 1; }')" ARCH_G3_MODE=enforce
echo "== G3 默认模式（#1046 起为 enforce）：不设 ARCH_G3_MODE 也必须报红"
expect_red "G3 默认即阻断" "$(sample crates/daemon/src/a.rs "$G3_USE")" "G3 VIOLATION"
echo "== G3 只报告模式：命中照列、不判红"
R="$(sample crates/daemon/src/a.rs "$G3_USE")"
if run "$R" ARCH_G3_MODE=report && printf '%s' "$OUT" | grep -qF "G3（只报告）：crates/daemon/src/a.rs"; then
  ok "G3 report 模式列出命中且通过"
else
  bad "G3 report 模式应列出命中且通过"; echo "$OUT" | sed 's/^/       /'
fi

echo
echo "arch-check 自测：通过 ${PASS}，失败 $FAILED"
[ "$FAILED" -eq 0 ]
