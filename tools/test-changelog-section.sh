#!/usr/bin/env bash
# #1636：tools/release/changelog-section.sh 的正反证单测（抽取模式 + --check 草稿小节去向门禁）。
# 用法: bash tools/test-changelog-section.sh    退出码: 0 全过 / 1 有失败
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${SRC}/tools/release/changelog-section.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { printf '  ✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }

R="${TMP}/repo"
FAKE="${TMP}/fake"
mkdir -p "${R}" "${TMP}/bin" "${FAKE}" "${TMP}/tpl"
cp "$SCRIPT" "${TMP}/changelog-section.sh"

cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
if [ "$1 $2" = "release list" ]; then
  [ -e "${FAKE}/releases.fail" ] && { echo "HTTP 502: stub release list failure" >&2; exit 1; }
  cat "${FAKE}/releases.json"
  exit 0
fi
echo "stub gh: unsupported $*" >&2
exit 2
STUB
chmod +x "${TMP}/bin/gh"

(
  cd "$R" || exit 1
  export GIT_TEMPLATE_DIR="${TMP}/tpl"
  git init --template= -q -b main
  git config user.email t@t
  git config user.name t
  echo x >a.txt
  git add a.txt
  git -c core.hooksPath=/dev/null commit -q --no-verify -m "init"
  git tag v2026.10.7
  git tag v2026.11.1
  git tag v2026.11.2
  git tag v0.12.2-test.1
) || { echo "造临时仓库失败"; exit 1; }

run_cs() {
  local want="$1" desc="$2" bin="${3}" rc
  shift 3
  (cd "$R" && PATH="${TMP}/bin:${PATH}" FAKE="$FAKE" GH_REPO=o/r bash "$bin" "$@") >"${TMP}/out" 2>&1
  rc=$?
  if [ "$rc" = "$want" ]; then ok "$desc"; else bad "${desc}（期望 ${want}，实际 ${rc}：$(tr '\n' ' ' <"${TMP}/out")）"; fi
}
has() { grep -qF -- "$1" "${TMP}/out"; }

echo "── 抽取模式（既有行为不变）"
cat >"${R}/CHANGELOG.md" <<'MD'
# Changelog

## [Unreleased]

## [2026.11.2] - 2026-11-10

### Fixed
- 修复了一件事（#100）。

## [2026.10.7] - 2026-10-28

### Added
- 旧版功能。
MD

run_cs 0 "正式 tag 提取对应小节 → 退出 0" "$SCRIPT" v2026.11.2 "${TMP}/sec.md" "${R}/CHANGELOG.md"
grep -qF "## 本版更新（2026.11.2）" "${TMP}/sec.md" && grep -qF "修复了一件事" "${TMP}/sec.md" && ! grep -qF "旧版功能" "${TMP}/sec.md" \
  && ok "  正确提取 [2026.11.2] 且不串段" || bad "  提取结果不对：$(cat "${TMP}/sec.md")"

run_cs 0 "test tag 写空文件 → 退出 0" "$SCRIPT" v0.12.2-test.1 "${TMP}/sec-test.md" "${R}/CHANGELOG.md"
[ ! -s "${TMP}/sec-test.md" ] && ok "  test tag 输出为空" || bad "  test tag 输出非空"

run_cs 0 "缺失小节打 ::warning:: 且不阻断 → 退出 0" "$SCRIPT" v2026.11.9 "${TMP}/sec-miss.md" "${R}/CHANGELOG.md"
has "::warning::" && [ ! -s "${TMP}/sec-miss.md" ] && ok "  缺失小节告警且文件为空" || bad "  缺失处理不对"

echo "── --check 模式（草稿小节去向门禁 + 反证）"
cat >"${FAKE}/releases.json" <<'JSON'
[
  {"tagName": "v2026.11.1", "isDraft": true, "isPrerelease": false},
  {"tagName": "v2026.10.7", "isDraft": false, "isPrerelease": false},
  {"tagName": "v0.12.2-test.1", "isDraft": true, "isPrerelease": false}
]
JSON

# 1. 滞留草稿正式条目 → 必红
cat >"${R}/CHANGELOG.md" <<'MD'
# Changelog

## [2026.11.2] - 2026-11-10

### Fixed
- 2026.11.2 条目。

## [2026.11.1] - 2026-11-05

### Added
- 滞留在草稿段里的未归并功能（#1636）。
MD
run_cs 1 "草稿 v2026.11.1 在 CHANGELOG 滞留 ### Added 条目 → --check 红（1）" "$SCRIPT" --check "${R}/CHANGELOG.md"
has "[2026.11.1]" && ok "  点名滞留的 [2026.11.1]" || bad "  没点名：$(cat "${TMP}/out")"

# 1b. 空草稿段（没有去向说明）→ 必红
cat >"${R}/CHANGELOG.md" <<'MD'
# Changelog

## [2026.11.1] - 2026-11-05

## [2026.10.7] - 2026-10-28
MD
run_cs 1 "草稿 [2026.11.1] 为空且无去向说明 → --check 红（1）" "$SCRIPT" --check "${R}/CHANGELOG.md"

# 1c. 写了去向说明但仍残留列表项 → 必红
cat >"${R}/CHANGELOG.md" <<'MD'
# Changelog

## [2026.11.1] - 2026-11-05

本版本未发布，内容已并入 [2026.11.2]。

- 残留条目未删。
MD
run_cs 1 "写了去向说明但仍残留条目列表 → --check 红（1）" "$SCRIPT" --check "${R}/CHANGELOG.md"

# 2a. 合法做法一：合并条目后移除草稿小节头 → 必绿
cat >"${R}/CHANGELOG.md" <<'MD'
# Changelog

## [2026.11.2] - 2026-11-10

### Added
- 已并入到 2026.11.2 的功能（#1636）。
MD
run_cs 0 "已并入当前段并移除 [2026.11.1] 标题 → --check 绿（0）" "$SCRIPT" --check "${R}/CHANGELOG.md"

# 2b. 合法做法二：保留标题并按约定写明去向（无 ### 或列表） → 必绿
cat >"${R}/CHANGELOG.md" <<'MD'
# Changelog

## [2026.11.2] - 2026-11-10

### Added
- 已并入到 2026.11.2 的功能（#1636）。

## [2026.11.1] - 2026-11-05

本版本未发布，内容已并入 [2026.11.2]。
MD
run_cs 0 "保留 [2026.11.1] 并显式标注「本版本未发布，内容已并入」→ --check 绿（0）" "$SCRIPT" --check "${R}/CHANGELOG.md"

# 3. gh 查询失败 → fail-closed 红
touch "${FAKE}/releases.fail"
run_cs 1 "gh 查询失败 → fail-closed 退出 1" "$SCRIPT" --check "${R}/CHANGELOG.md"
has "fail-closed" && ok "  gh 失败明确报错" || bad "  未说明 fail-closed：$(cat "${TMP}/out")"
rm -f "${FAKE}/releases.fail"

# 4. 反证：撤掉 --check 门禁检查后，滞留草稿段夹具被错误放行（证明红来自 --check）
cat >"${R}/CHANGELOG.md" <<'MD'
# Changelog

## [2026.11.1] - 2026-11-05

### Added
- 滞留在草稿段里的未归并功能（#1636）。
MD
cat >"${TMP}/changelog-section-mutant.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--check" ]; then exit 0; fi
exit 2
SH
run_cs 0 "反证：绕过 --check 校验后滞留草稿段错误放行（证明门禁真在起作用）" "${TMP}/changelog-section-mutant.sh" --check "${R}/CHANGELOG.md"

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" = 0 ]
