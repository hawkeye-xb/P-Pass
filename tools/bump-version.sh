#!/usr/bin/env bash
# REL-01 / UPD-13: bump 版本号（两条线）。
#
#   两条线（#660 起，2026-10-04 拍板）：
#     - **desktop 线**：根 workspace（Cargo.toml + Cargo.lock）+ 桌面壳四件套
#       （tauri.conf.json / package.json / src-tauri/Cargo.toml / src-tauri/Cargo.lock）
#     - **android 线**：build.gradle.kts（versionName 回退串 + versionCode 单调 +1）
#   真相源 = `release/versions.json`：CI（tools/release-version.sh）从这里取
#   「本次发布该用哪个版本号」，所以本脚本改完文件必须同步写它。
#
#   不加 --platform 时两条线一起走（等价旧行为）。只改一端时，另一端
#   的文件**一个字节都不动** —— 它的版本号代表「该端最后一次真变更」。
#
# 用法：tools/bump-version.sh [--platform desktop|android|both] <new-version>
#   e.g. tools/bump-version.sh --platform android 0.9.2
#
# 防版本覆盖（2026-08-04 用户裁决：绝不挪/覆盖旧版本）：
#   - 已打过精确 tag（v<ver>）的版本号拒绝使用
#   - 新版本必须严格高于该线当前版本
#   - 只改版本号行——验收：跑完 git diff 恰好只碰本线的文件 + versions.json
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PLATFORM=both
if [ "${1:-}" = "--platform" ]; then
  PLATFORM="${2:-}"
  shift 2
fi
case "$PLATFORM" in
  desktop|android|both) ;;
  *) echo "error: --platform 只接受 desktop|android|both（收到 '$PLATFORM'）" >&2; exit 1 ;;
esac

NEW="${1:-}"
if [ -z "$NEW" ]; then
  echo "usage: tools/bump-version.sh [--platform desktop|android|both] <new-version>" >&2
  exit 1
fi

# SemVer 校验（3 段数字 + 可选预发布/构建后缀）
if ! [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "error: 非法版本号 '$NEW'（期望 SemVer，如 0.9.1 或 0.9.1-beta.1）" >&2
  exit 1
fi

VJSON=release/versions.json
if [ ! -f "$VJSON" ]; then
  echo "error: 缺 $VJSON（版本真相源，UPD-13）" >&2
  exit 1
fi

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
  local path="$1" actual="$2" expected="$3"
  if [ -z "$actual" ]; then echo "error: 读不到 ${path} 的 version" >&2; exit 1; fi
  if [ "$actual" != "$expected" ]; then
    echo "error: ${path} version drift: ${actual} != ${expected}; 先对齐再 bump。" >&2
    exit 1
  fi
}

# ── 版本真相源 ────────────────────────────────────────────────────
DESKTOP_CUR=$(jq -r '.desktop' "$VJSON")
ANDROID_CUR=$(jq -r '.android' "$VJSON")
VCODE_CUR=$(jq -r '.androidVersionCode' "$VJSON")
for v in "$DESKTOP_CUR" "$ANDROID_CUR" "$VCODE_CUR"; do
  [ -n "$v" ] && [ "$v" != "null" ] || { echo "error: $VJSON 字段缺失" >&2; exit 1; }
done

# ── Version-drift preflight：真相源 vs 各文件（每处独立读，不借用别处的值）──
TCUR=$(read_json_version apps/desktop/src-tauri/tauri.conf.json)
PCUR=$(read_json_version apps/desktop/package.json)
DCCUR=$(read_toml_version apps/desktop/src-tauri/Cargo.toml)
ALCUR=$(read_android_fallback_version apps/android/app/build.gradle.kts)
DLLOCKCUR=$(read_lock_package_version apps/desktop/src-tauri/Cargo.lock)
ROOTCUR=$(read_toml_version Cargo.toml)
VCODE=$(awk '/versionCode/{gsub(/.*= */,""); print; exit}' apps/android/app/build.gradle.kts)

assert_version Cargo.toml "$ROOTCUR" "$DESKTOP_CUR"
assert_version apps/desktop/src-tauri/tauri.conf.json "$TCUR" "$DESKTOP_CUR"
assert_version apps/desktop/package.json "$PCUR" "$DESKTOP_CUR"
assert_version apps/desktop/src-tauri/Cargo.toml "$DCCUR" "$DESKTOP_CUR"
assert_version 'apps/desktop/src-tauri/Cargo.lock (p-pass-desktop)' "$DLLOCKCUR" "$DESKTOP_CUR"
assert_version apps/android/app/build.gradle.kts "$ALCUR" "$ANDROID_CUR"
assert_version 'apps/android/app/build.gradle.kts (versionCode)' "$VCODE" "$VCODE_CUR"

# 防覆盖 1：已打过精确 tag 的版本号绝不复用
if git tag -l "v${NEW}" | grep -q .; then
  echo "error: v${NEW} 已打过 tag（git tag -l 'v${NEW}'）——拒绝覆盖旧版本号。" >&2
  echo "       每个版本的问题都是独一无二的：打新 tag，不挪旧 tag。" >&2
  exit 1
fi

# 防覆盖 2：新版本必须严格高于**该线**当前版本
bump_ok() { # <cur> <new> <label>
  if [ "$2" = "$1" ] \
    || [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" != "$1" ]; then
    echo "error: $3 新版本 $2 必须严格高于当前版本 $1" >&2
    exit 1
  fi
}
if [ "$PLATFORM" = desktop ] || [ "$PLATFORM" = both ]; then bump_ok "$DESKTOP_CUR" "$NEW" desktop; fi
if [ "$PLATFORM" = android ] || [ "$PLATFORM" = both ]; then bump_ok "$ANDROID_CUR" "$NEW" android; fi

# ⚠️ 便携 sed：`-i ''` 是 macOS（BSD）专属，Linux（GNU）必炸——统一用
# `-i.bak … && rm …bak`（GNU/BSD 均接受带后缀的 -i）。
sedi() { # <pattern> <file>
  sed -i.bak "$1" "$2" && rm "$2.bak"
}

NCODE="$VCODE"
if [ "$PLATFORM" = desktop ] || [ "$PLATFORM" = both ]; then
  # 根 workspace（daemon 那套只随桌面端交付）
  sedi "s/^version = \"$ROOTCUR\"/version = \"$NEW\"/" Cargo.toml
  # 桌面四件套（JSON 引号 + TOML 裸值两种写法）
  sedi "s/\"version\": \"$TCUR\"/\"version\": \"$NEW\"/" apps/desktop/src-tauri/tauri.conf.json
  sedi "s/\"version\": \"$PCUR\"/\"version\": \"$NEW\"/" apps/desktop/package.json
  sedi "s/^version = \"$DCCUR\"/version = \"$NEW\"/" apps/desktop/src-tauri/Cargo.toml
  # 两个独立 workspace 的 lock 同步（BUMP-01：只有 workspace 成员版本会变）
  ( cd apps/desktop/src-tauri && cargo update -w -q )
  cargo update -w -q
fi

if [ "$PLATFORM" = android ] || [ "$PLATFORM" = both ]; then
  # versionCode 单调 +1（Android 强制）；BSD awk 把行首缩进当第一个分隔符，
  # -F'[= ]+' 下 $2 是 "versionCode"——用 gsub 去掉 "= " 前缀拿纯数字。
  NCODE=$((VCODE + 1))
  sedi "s/versionCode = $VCODE/versionCode = $NCODE/" apps/android/app/build.gradle.kts
  sedi "s/?: \"$ALCUR\"/?: \"$NEW\"/" apps/android/app/build.gradle.kts
fi

# ── 写回真相源 ────────────────────────────────────────────────────
NEW_DESKTOP="$DESKTOP_CUR"
NEW_ANDROID="$ANDROID_CUR"
if [ "$PLATFORM" = desktop ] || [ "$PLATFORM" = both ]; then NEW_DESKTOP="$NEW"; fi
if [ "$PLATFORM" = android ] || [ "$PLATFORM" = both ]; then NEW_ANDROID="$NEW"; fi
tmp=$(mktemp)
jq --arg d "$NEW_DESKTOP" --arg a "$NEW_ANDROID" --argjson c "$NCODE" \
  '{desktop:$d, android:$a, androidVersionCode:$c}' "$VJSON" > "$tmp"
mv "$tmp" "$VJSON"

# ── 收尾断言：每个目标都必须到达 NEW（不借用别处读到的值）──────────
if [ "$PLATFORM" = desktop ] || [ "$PLATFORM" = both ]; then
  assert_version Cargo.toml "$(read_toml_version Cargo.toml)" "$NEW"
  assert_version apps/desktop/src-tauri/tauri.conf.json "$(read_json_version apps/desktop/src-tauri/tauri.conf.json)" "$NEW"
  assert_version apps/desktop/package.json "$(read_json_version apps/desktop/package.json)" "$NEW"
  assert_version apps/desktop/src-tauri/Cargo.toml "$(read_toml_version apps/desktop/src-tauri/Cargo.toml)" "$NEW"
  assert_version 'apps/desktop/src-tauri/Cargo.lock (p-pass-desktop)' "$(read_lock_package_version apps/desktop/src-tauri/Cargo.lock)" "$NEW"
fi
if [ "$PLATFORM" = android ] || [ "$PLATFORM" = both ]; then
  assert_version apps/android/app/build.gradle.kts "$(read_android_fallback_version apps/android/app/build.gradle.kts)" "$NEW"
  assert_version 'apps/android/app/build.gradle.kts (versionCode)' \
    "$(awk '/versionCode/{gsub(/.*= */,""); print; exit}' apps/android/app/build.gradle.kts)" "$NCODE"
fi
assert_version "release/versions.json (desktop)" "$(jq -r '.desktop' "$VJSON")" "$NEW_DESKTOP"
assert_version "release/versions.json (android)" "$(jq -r '.android' "$VJSON")" "$NEW_ANDROID"

echo "bumped[$PLATFORM]: desktop ${DESKTOP_CUR} -> ${NEW_DESKTOP}, android ${ANDROID_CUR} -> ${NEW_ANDROID} (versionCode ${VCODE} -> ${NCODE})"
echo "--- git diff（应只含本线的版本号行 + release/versions.json）---"
TARGETS="release/versions.json"
[ "$NEW_DESKTOP" != "$DESKTOP_CUR" ] && TARGETS="$TARGETS Cargo.toml Cargo.lock apps/desktop/src-tauri/tauri.conf.json apps/desktop/package.json apps/desktop/src-tauri/Cargo.toml apps/desktop/src-tauri/Cargo.lock"
[ "$NEW_ANDROID" != "$ANDROID_CUR" ] && TARGETS="$TARGETS apps/android/app/build.gradle.kts"
# shellcheck disable=SC2086 # TARGETS 是刻意拆分
git diff --stat $TARGETS
# shellcheck disable=SC2086
git diff $TARGETS | grep -E "^[+-]" | grep -vE "^(\+\+\+|---)" || true

# BUMP-01: assert the tree is clean except the version files themselves.
# Untracked files (-uno) are never added by an explicit `git add`, so they must
# not fail the bump. The bump script itself is whitelisted (it may be edited while
# running); `tools/release-version.sh` is whitelisted for the same reason.
DIRTY=$(git status --porcelain -uno | sed 's/^...//' | grep -v -E '^(Cargo\.toml|apps/android/app/build\.gradle\.kts|Cargo\.lock|tools/bump-version\.sh|tools/release-version\.sh|release/versions\.json|apps/desktop/src-tauri/tauri\.conf\.json|apps/desktop/package\.json|apps/desktop/src-tauri/Cargo\.toml|apps/desktop/src-tauri/Cargo\.lock)$' || true)
if [ -n "$DIRTY" ]; then
  echo "error: unexpected dirty files after bump: $DIRTY" >&2
  exit 1
fi
echo "ok: versions.json + Cargo.lock workspace members synced; tree clean (version files only)"
