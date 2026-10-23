#!/usr/bin/env bash
# UPD-13（#660）漏判门禁：**改了某端的构建输入，却没涨该端的版本号**必须红。
#
# 判据（两条线）：
#   - `crates/**`、`apps/desktop/**`、`assets/**`、`Cargo.*`、`rust-toolchain.toml`
#     ⇒ 桌面端（含共享内核）被改到 ⇒ `versions.json.desktop` 必须前进
#   - `apps/android/**`，以及安卓 APK 里那份 Rust 原生库（libtransport.so）的构建输入
#     ⇒ 安卓端被改到 ⇒ `versions.json.android` 必须前进
#     #894：原生库输入 = gradle 任务 `buildIrohBlobsProviderBridge` 的 inputs
#     （`Cargo.toml`、`Cargo.lock`、`crates/transport/**`、`crates/proto/**`）+ 它实际调用的
#     `tools/build-android-iroh-blobs-bridge.sh` + 钉工具链的 `rust-toolchain.toml`。
#     #1124 起安卓的 libtransport.so 也开 `mobile-ffi`，transport 在它下依赖 `crates/proto`。
#     这份清单与 gradle inputs 的一致性由 tools/test-release-version-source.sh 校验。
#   - iOS（#348）：`apps/ios/**`、传输 XCFramework 的输入（`crates/transport/`、`crates/proto/`、
#     `Cargo.*`、`rust-toolchain.toml`、`tools/build-ios-*`）、会进 App 的生成源（`assets/i18n/`、
#     `assets/design/tokens.json`、Android 两份 strings.xml）与盖章/生成脚本
#     ⇒ `versions.json.ios` 必须前进。上一个 tag 里没有 ios 线（UPD-13 之后第一次出现）时跳过这条门禁。
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
  echo "error: 找不到 ${PREV}（需要 fetch tag）" >&2
  exit 1
fi
# REL-11（#708）：head-ref 同样必须存在——否则下面的 diff 会失败，门禁不能静默放行。
if ! git rev-parse -q --verify "${HEAD_REF}^{commit}" >/dev/null; then
  echo "::error::找不到 head-ref ${HEAD_REF}——版本门禁无法计算改动面" >&2
  exit 1
fi

# ── 上一版的号 ────────────────────────────────────────────────────
if git cat-file -e "$PREV:release/versions.json" 2>/dev/null; then
  prev_d=$(git show "$PREV:release/versions.json" | jq -r '.desktop')
  prev_a=$(git show "$PREV:release/versions.json" | jq -r '.android')
  prev_i=$(git show "$PREV:release/versions.json" | jq -r '.ios // empty')
else
  prev_d=$(git show "$PREV:apps/desktop/src-tauri/tauri.conf.json" | jq -r '.version')
  prev_a=$(git show "$PREV:apps/android/app/build.gradle.kts" \
    | sed -n 's/^[[:space:]]*?: "\([^"]*\)".*/\1/p' | head -1)
  prev_i=""
  echo "::notice::${PREV} 里没有 release/versions.json（UPD-13 之前），改用当时的文件版本：desktop=${prev_d} android=${prev_a}"
fi

# ── 本版的号 ──────────────────────────────────────────────────────
cur_d=$(jq -r '.desktop' release/versions.json)
cur_a=$(jq -r '.android' release/versions.json)
cur_i=$(jq -r '.ios // empty' release/versions.json)

# ── 改动面 ────────────────────────────────────────────────────────
# REL-11（#708）：diff 失败必须红。原先 `|| true` 让失败时改动面为空 ⇒ 门禁静默放行。
# `--` 防止 head-ref 恰好是一个目录名时被 git 当成路径（那样会 diff 工作区且退出 0）。
if ! CHANGED=$(git diff --name-only "$PREV" "$HEAD_REF" --); then
  echo "::error::git diff $PREV $HEAD_REF 失败——版本门禁无法计算改动面" >&2
  exit 1
fi
# 测试目录不算「产品改动」：`crates/**/tests/**`、`**/benches/**` 改了不需要涨号
# （否则一个只改测试的 PR 会逼着发一个内容相同的版本，正是 UPD-13 要消灭的东西）。
# 保守边界：src 文件里 `#[cfg(test)]` 块改动仍算产品改动——宁可多涨，不漏涨。
PRODUCT=$(grep -Ev '(^|/)(tests?|benches)/' <<<"$CHANGED" || true)
desk_hit=$(grep -Ec '^(crates/|apps/desktop/|assets/|Cargo\.(toml|lock)$|rust-toolchain\.toml)' <<<"$PRODUCT" || true)
ANDROID_INPUTS='^(apps/android/|crates/(transport|proto|pair-pake)/|Cargo\.(toml|lock)$|rust-toolchain\.toml$|tools/build-android-iroh-blobs-bridge\.sh$)'
andr_hit=$(grep -Ec "$ANDROID_INPUTS" <<<"$PRODUCT" || true)
# iOS 输入（#348）：与 ci-ios 的触发路径同口径，但 tools/ios/ 只算会进产物的盖章/生成/字体脚本，
# 测试与 e2e 脚本不算（改它们不该逼着发一个内容相同的 TestFlight 构建）。
IOS_INPUTS='^(apps/ios/|crates/(transport|proto|pair-pake)/|Cargo\.(toml|lock)$|rust-toolchain\.toml$|tools/build-ios-|tools/ios/(stamp-version|gen-strings|gen-tokens|sync-i18n|prepare-fonts)|assets/i18n/|assets/design/tokens\.json$|apps/android/app/src/main/res/values(-zh)?/strings\.xml$)'
ios_hit=$(grep -Ec "$IOS_INPUTS" <<<"$PRODUCT" || true)

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
  echo "::error::改了安卓端构建输入（apps/android 或原生库 libtransport.so 的输入，${andr_hit} 个文件）但 android 版本没涨：${prev_a} → ${cur_a}"
  fail=1
fi
if [ -n "$prev_i" ] && [ -n "$cur_i" ]; then
  if [ "$ios_hit" -gt 0 ] && ! newer "$prev_i" "$cur_i"; then
    echo "::error::改了 iOS 端构建输入（${ios_hit} 个文件）但 ios 版本没涨：${prev_i} → ${cur_i}（TestFlight 不能重复上传同一构建号）"
    fail=1
  fi
  if [ "$ios_hit" -eq 0 ] && newer "$prev_i" "$cur_i"; then
    echo "::warning::ios 版本涨了（${prev_i} → ${cur_i}）但没改 iOS 端构建输入——确认是有意的吗？"
  fi
else
  echo "::notice::${PREV} 里没有 ios 版本线（或本版缺 ios）——跳过 iOS 门禁"
fi
if [ "$desk_hit" -eq 0 ] && newer "$prev_d" "$cur_d"; then
  echo "::warning::desktop 版本涨了（${prev_d} → ${cur_d}）但没有任何桌面/共享内核改动——确认是有意的吗？"
fi
if [ "$andr_hit" -eq 0 ] && newer "$prev_a" "$cur_a"; then
  echo "::warning::android 版本涨了（${prev_a} → ${cur_a}）但没改安卓端构建输入——确认是有意的吗？"
fi

if [ "$fail" -eq 0 ]; then
  echo "ok: 版本号与改动范围一致（desktop ${prev_d}→${cur_d} 命中 ${desk_hit} 个文件；android ${prev_a}→${cur_a} 命中 ${andr_hit} 个文件；ios ${prev_i:-无}→${cur_i:-无} 命中 ${ios_hit} 个文件）"
fi
exit "$fail"
