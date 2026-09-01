#!/usr/bin/env bash
# REL-01: bump workspace + Android + desktop (Tauri) versions in one shot.
# Usage: tools/bump-version.sh <new-version>    e.g. tools/bump-version.sh 0.3.0
#
# 防版本覆盖（2026-08-04 用户裁决：绝不挪/覆盖旧版本）：
#   - 已打过精确 tag（v<ver>）的版本号拒绝使用
#   - 新版本必须高于当前 Cargo.toml version
#   - 只改版本号行——验收：跑完 git diff 恰好只碰 Cargo.toml version 行、
#     build.gradle.kts 的 versionCode/versionName 行、桌面四件套
#     （tauri.conf.json / package.json / src-tauri/Cargo.toml /
#     src-tauri/Cargo.lock——独立 workspace，主仓 cargo update 够不着）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NEW="${1:-}"
if [ -z "$NEW" ]; then
  echo "usage: tools/bump-version.sh <new-version>" >&2
  exit 1
fi

# SemVer 校验（3 段数字 + 可选预发布/构建后缀）
if ! [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "error: 非法版本号 '$NEW'（期望 SemVer，如 0.3.0 或 0.3.0-beta.1）" >&2
  exit 1
fi

CUR=$(awk '/^version = /{gsub(/"/,"",$3); print $3; exit}' Cargo.toml)
if [ -z "$CUR" ]; then
  echo "error: 读不到 Cargo.toml workspace version" >&2
  exit 1
fi

# Every version target is read independently. Do not reuse a value from one
# file as another file's sed pattern: a drift would turn that edit into a
# silent no-op.
read_json_version() {
  awk -F'"' '/"version"/{print $4; exit}' "$1"
}

read_toml_version() {
  awk '/^version = /{gsub(/"/,"",$3); print $3; exit}' "$1"
}

read_android_fallback_version() {
  awk -F'"' '/\?: "/{print $2; exit}' "$1"
}

read_lock_package_version() {
  awk '
    $0 == "name = \"p-pass-desktop\"" { package = 1; next }
    package && /^version = / { gsub(/"/, "", $3); print $3; exit }
  ' "$1"
}

assert_version() {
  local path="$1"
  local actual="$2"
  local expected="$3"
  if [ -z "$actual" ]; then
    echo "error: 读不到 ${path} 的 version" >&2
    exit 1
  fi
  if [ "$actual" != "$expected" ]; then
    echo "error: ${path} version drift: ${actual} != ${expected}; 先对齐再 bump。" >&2
    exit 1
  fi
}

# ── Version-drift preflight ────────────────────────────────────────
# The standalone desktop workspace has its own Cargo.lock. Android local
# builds use the versionName fallback when no release tag is injected.
TCUR=$(read_json_version apps/desktop/src-tauri/tauri.conf.json)
PCUR=$(read_json_version apps/desktop/package.json)
DCCUR=$(read_toml_version apps/desktop/src-tauri/Cargo.toml)
ALCUR=$(read_android_fallback_version apps/android/app/build.gradle.kts)
DLLOCKCUR=$(read_lock_package_version apps/desktop/src-tauri/Cargo.lock)

assert_version apps/desktop/src-tauri/tauri.conf.json "$TCUR" "$CUR"
assert_version apps/desktop/package.json "$PCUR" "$CUR"
assert_version apps/desktop/src-tauri/Cargo.toml "$DCCUR" "$CUR"
assert_version 'apps/desktop/src-tauri/Cargo.lock (p-pass-desktop)' "$DLLOCKCUR" "$CUR"

# 防覆盖 1：已打过精确 tag 的版本号绝不复用
if git tag -l "v${NEW}" | grep -q .; then
  echo "error: v${NEW} 已打过 tag（git tag -l 'v${NEW}'）——拒绝覆盖旧版本号。" >&2
  echo "       每个版本的问题都是独一无二的：打新 tag，不挪旧 tag。" >&2
  exit 1
fi

# 防覆盖 2：新版本必须严格高于当前代码版本（显式相等检查 + sort -V
# 语义比较——相等时 sort -V 两行相同，head/tail 双端判断仍会放过，
# 必须先判 [ "$NEW" = "$CUR" ]）
if [ "$NEW" = "$CUR" ] \
  || [ "$(printf '%s\n%s\n' "$CUR" "$NEW" | sort -V | head -1)" != "$CUR" ]; then
  echo "error: 新版本 $NEW 必须严格高于当前版本 $CUR" >&2
  exit 1
fi

# 改 Cargo.toml（workspace 级第一处 version）
# ⚠️ 便携 sed：`-i ''` 是 macOS（BSD）专属，Linux（GNU）必炸——统一用
# `-i.bak … && rm …bak`（GNU/BSD 均接受带后缀的 -i）。
sed -i.bak "s/^version = \"$CUR\"/version = \"$NEW\"/" Cargo.toml && rm Cargo.toml.bak
# 改 Android versionName + versionCode（versionCode 单调 +1，Android 强制）
# ⚠️ BSD awk 把行首缩进当第一个分隔符，-F'[= ]+' 下 $2 是 "versionCode"——
# 用 gsub 去掉 "= " 前缀拿纯数字
VCODE=$(awk '/versionCode/{gsub(/.*= */,""); print; exit}' apps/android/app/build.gradle.kts)
if [ -z "$VCODE" ]; then
  echo "error: 读不到 build.gradle.kts versionCode" >&2
  exit 1
fi
NCODE=$((VCODE + 1))
sed -i.bak "s/versionCode = $VCODE/versionCode = $NCODE/" apps/android/app/build.gradle.kts && rm apps/android/app/build.gradle.kts.bak
sed -i.bak "s/?: \"$ALCUR\"/?: \"$NEW\"/" apps/android/app/build.gradle.kts && rm apps/android/app/build.gradle.kts.bak

# ── Desktop (Tauri standalone workspace) 四件套同步 ──────────────
# 桌面四件套同步（JSON 引号 + TOML 裸值两种写法）
sed -i.bak "s/\"version\": \"$TCUR\"/\"version\": \"$NEW\"/" apps/desktop/src-tauri/tauri.conf.json && rm apps/desktop/src-tauri/tauri.conf.json.bak
sed -i.bak "s/\"version\": \"$PCUR\"/\"version\": \"$NEW\"/" apps/desktop/package.json && rm apps/desktop/package.json.bak
sed -i.bak "s/^version = \"$DCCUR\"/version = \"$NEW\"/" apps/desktop/src-tauri/Cargo.toml && rm apps/desktop/src-tauri/Cargo.toml.bak
# 独立 workspace 的 lock 同步（与主仓 BUMP-01 同款：cargo update -w）
( cd apps/desktop/src-tauri && cargo update -w -q )

# BUMP-01 (2026-08-06): sync workspace-member versions into Cargo.lock.
# bump-version.sh only edits Cargo.toml / build.gradle.kts / desktop files,
# so the first build after a bump used to dirty the lock (TAG-01 0.2.1,
# fixed by hand in 6bb3239) — this makes it automatic: `cargo update -w`
# refreshes just the workspace members, leaving their dependency tree
# untouched. Desktop is its own workspace: `cargo update -w` runs inside
# apps/desktop/src-tauri for its lock.
cargo update -w -q

# The whitelist below only proves that no unrelated file changed. Verify that
# every target actually reached NEW, including the generated desktop lock entry.
assert_version Cargo.toml "$(read_toml_version Cargo.toml)" "$NEW"
assert_version apps/android/app/build.gradle.kts "$(read_android_fallback_version apps/android/app/build.gradle.kts)" "$NEW"
assert_version apps/desktop/src-tauri/tauri.conf.json "$(read_json_version apps/desktop/src-tauri/tauri.conf.json)" "$NEW"
assert_version apps/desktop/package.json "$(read_json_version apps/desktop/package.json)" "$NEW"
assert_version apps/desktop/src-tauri/Cargo.toml "$(read_toml_version apps/desktop/src-tauri/Cargo.toml)" "$NEW"
assert_version 'apps/desktop/src-tauri/Cargo.lock (p-pass-desktop)' "$(read_lock_package_version apps/desktop/src-tauri/Cargo.lock)" "$NEW"

echo "bumped: $CUR -> $NEW (android versionCode $VCODE -> $NCODE, desktop $TCUR -> $NEW)"
echo "--- git diff（应只含版本号行）---"
git diff --stat Cargo.toml Cargo.lock apps/android/app/build.gradle.kts \
  apps/desktop/src-tauri/tauri.conf.json apps/desktop/package.json \
  apps/desktop/src-tauri/Cargo.toml apps/desktop/src-tauri/Cargo.lock
git diff Cargo.toml Cargo.lock apps/android/app/build.gradle.kts \
  apps/desktop/src-tauri/tauri.conf.json apps/desktop/package.json \
  apps/desktop/src-tauri/Cargo.toml apps/desktop/src-tauri/Cargo.lock \
  | grep -E "^[+-]" | grep -vE "^(\+\+\+|---)" || true

# BUMP-01: assert the tree is clean except the version files themselves.
# Anything else dirty (stray build artifacts, accidental edits) fails the
# bump instead of silently riding along into the commit. The script itself
# is whitelisted: a developer may run it while it has uncommitted edits.
# Rework (2026-08-06 07:47 round): use --porcelain -uno - untracked files
# (e.g. a stray .claude/ dir on the reviewer's machine) are never added by
# an explicit `git add`, so they must not fail the bump.
DIRTY=$(git status --porcelain -uno | sed 's/^...//' | grep -v -E '^(Cargo\.toml|apps/android/app/build\.gradle\.kts|Cargo\.lock|tools/bump-version\.sh|apps/desktop/src-tauri/tauri\.conf\.json|apps/desktop/package\.json|apps/desktop/src-tauri/Cargo\.toml|apps/desktop/src-tauri/Cargo\.lock)$' || true)
if [ -n "$DIRTY" ]; then
  echo "error: unexpected dirty files after bump: $DIRTY" >&2
  exit 1
fi
echo "ok: Cargo.lock workspace members synced; tree clean (version files only)"
