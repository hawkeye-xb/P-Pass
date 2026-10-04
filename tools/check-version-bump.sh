#!/usr/bin/env bash
# UPD-13（#660）漏判门禁：**改了某端的构建输入，却没涨该端的版本号**必须红。
#
# 判据（两条线）：
#   - `crates/**`、`apps/desktop/**`、`assets/**`、`Cargo.*`、`rust-toolchain.toml`
#     ⇒ 桌面端（含共享内核）被改到 ⇒ `versions.json.desktop` 必须前进
#   - `apps/android/**`
#     ⇒ 安卓端被改到 ⇒ `versions.json.android` 必须前进
#   - 只改 docs/site/.github/tools ⇒ 两端的号都不该动（动了只 warning，不判红：
#     可能是刻意重发）
#
# 用法：tools/check-version-bump.sh <prev-tag> [head-ref]
#   在 tag 推送时运行（release.yml create-draft），prev-tag = 上一个 v* tag。
#   prev tag 里没有 release/versions.json 时（UPD-13 之前的版本），退回读当时的
#   tauri.conf.json / build.gradle.kts，门禁照样有效。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PREV="${1:-}"
HEAD_REF="${2:-HEAD}"
if [ -z "$PREV" ]; then
  echo "usage: $0 <prev-tag> [head-ref]" >&2
  exit 1
fi
if ! git rev-parse -q --verify "${PREV}^{commit}" >/dev/null; then
  echo "error: 找不到 $PREV（需要 fetch tag）" >&2
  exit 1
fi

# ── 上一版的号 ────────────────────────────────────────────────────
if git cat-file -e "$PREV:release/versions.json" 2>/dev/null; then
  prev_d=$(git show "$PREV:release/versions.json" | jq -r '.desktop')
  prev_a=$(git show "$PREV:release/versions.json" | jq -r '.android')
else
  prev_d=$(git show "$PREV:apps/desktop/src-tauri/tauri.conf.json" | jq -r '.version')
  prev_a=$(git show "$PREV:apps/android/app/build.gradle.kts" \
    | sed -n 's/^[[:space:]]*?: "\([^"]*\)".*/\1/p' | head -1)
  echo "::notice::${PREV} 里没有 release/versions.json（UPD-13 之前），改用当时的文件版本：desktop=${prev_d} android=${prev_a}"
fi

# ── 本版的号 ──────────────────────────────────────────────────────
cur_d=$(jq -r '.desktop' release/versions.json)
cur_a=$(jq -r '.android' release/versions.json)

# ── 改动面 ────────────────────────────────────────────────────────
CHANGED=$(git diff --name-only "$PREV" "$HEAD_REF" || true)
desk_hit=$(grep -Ec '^(crates/|apps/desktop/|assets/|Cargo\.(toml|lock)$|rust-toolchain\.toml)' <<<"$CHANGED" || true)
andr_hit=$(grep -Ec '^apps/android/' <<<"$CHANGED" || true)

newer() { # <prev> <cur> → 0 表示 cur 严格更新
  [ "$1" != "$2" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]
}

fail=0
if [ "$desk_hit" -gt 0 ] && ! newer "$prev_d" "$cur_d"; then
  echo "::error::改了桌面/共享内核（${desk_hit} 个文件）但 desktop 版本没涨：${prev_d} → ${cur_d}"
  fail=1
fi
if [ "$andr_hit" -gt 0 ] && ! newer "$prev_a" "$cur_a"; then
  echo "::error::改了 apps/android（${andr_hit} 个文件）但 android 版本没涨：${prev_a} → ${cur_a}"
  fail=1
fi
if [ "$desk_hit" -eq 0 ] && newer "$prev_d" "$cur_d"; then
  echo "::warning::desktop 版本涨了（${prev_d} → ${cur_d}）但没有任何桌面/共享内核改动——确认是有意的吗？"
fi
if [ "$andr_hit" -eq 0 ] && newer "$prev_a" "$cur_a"; then
  echo "::warning::android 版本涨了（${prev_a} → ${cur_a}）但没改 apps/android——确认是有意的吗？"
fi

if [ "$fail" -eq 0 ]; then
  echo "ok: 版本号与改动范围一致（desktop ${prev_d}→${cur_d} 命中 ${desk_hit} 个文件；android ${prev_a}→${cur_a} 命中 ${andr_hit} 个文件）"
fi
exit "$fail"
