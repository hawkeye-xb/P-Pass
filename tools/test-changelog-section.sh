#!/usr/bin/env bash
# #1636：tools/release/changelog-section.sh 与 prev-published-tag.sh / notes-presence.sh 的正反证单测。
# 模拟 contents: read 下 gh release list --exclude-drafts --exclude-pre-releases 的真实行为：
# stub gh 严格过滤掉 Draft（只返回已 Publish Release），验证差集检查、--current 候选排除、
# 历史保留边界及 notes-presence / prev-published-tag 对草稿的跳过行为。
# 用法: bash tools/test-changelog-section.sh    退出码: 0 全过 / 1 有失败
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${SRC}/tools/release/changelog-section.sh"
PREV_SCRIPT="${SRC}/tools/release/prev-published-tag.sh"
NOTES_SCRIPT="${SRC}/tools/release/notes-presence.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { printf '  ✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }

R="${TMP}/repo"
FAKE="${TMP}/fake"
mkdir -p "${R}/tools/release" "${R}/release/notes/android" "${TMP}/bin" "${FAKE}" "${TMP}/tpl"
cp "$SCRIPT" "${R}/tools/release/"
cp "$PREV_SCRIPT" "${R}/tools/release/"
cp "$NOTES_SCRIPT" "${R}/tools/release/"
cp "${SRC}/tools/release-notes.mjs" "${R}/tools/"

# 模拟 contents: read 权限的 gh：release list 仅返回非草稿、非预发布的已 Publish Release。
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
if [ "$1 $2" = "release list" ]; then
  [ -e "${FAKE}/releases.fail" ] && { echo "HTTP 502: stub release list failure" >&2; exit 1; }
  python3 - "${FAKE}/releases.json" "$@" <<'PY'
import json, sys
path, argv = sys.argv[1], sys.argv[2:]
rows = json.load(open(path, encoding="utf-8"))
excl_draft = "--exclude-drafts" in argv
excl_pre = "--exclude-pre-releases" in argv
# 模拟 GitHub contents: read：即使未传 --exclude-drafts，只读 token 也拿不到 isDraft=true。
out = []
for r in rows:
    if r.get("isDraft"):
        continue
    if excl_pre and r.get("isPrerelease"):
        continue
    out.append(r)
print(json.dumps(out))
PY
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
  c() { git add -A && git -c core.hooksPath=/dev/null commit -q --no-verify --allow-empty -m "$1"; }
  printf '{"desktop":"0.9.0","android":"0.9.0"}\n' >release/versions.json && c "c0" && git tag v2026.10.6
  printf '{"desktop":"0.10.1","android":"0.10.2"}\n' >release/versions.json && c "c1" && git tag v2026.10.7
  printf '{"desktop":"0.11.0","android":"0.11.0"}\n' >release/versions.json && c "c2" && git tag v2026.11.1
  printf '{"desktop":"0.11.1","android":"0.11.1"}\n' >release/versions.json && c "c3" && git tag v2026.11.2
  printf '{"desktop":"0.11.1","android":"0.11.1"}\n' >release/versions.json && c "c4"
) || { echo "造临时仓库失败"; exit 1; }

run_cs() {
  local want="$1" desc="$2" bin="$3" rc
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

echo "── --check 模式（contents: read 差集门禁 + --current + 反证）"
# 线上仅保留从 v2026.10.7 起的已 Publish Release（v2026.10.6 更早未被保留；v2026.11.1 是 Draft，contents: read 看不到）
cat >"${FAKE}/releases.json" <<'JSON'
[
  {"tagName": "v2026.11.1", "isDraft": true, "isPrerelease": false, "publishedAt": ""},
  {"tagName": "v2026.10.7", "isDraft": false, "isPrerelease": false, "publishedAt": "2026-10-28T10:11:39Z"}
]
JSON

# 1. 只读 token 下虽看不到 isDraft=true，但通过「v2026.11.1 有 tag 却不在已 Publish 列表」依然拦红
cat >"${R}/CHANGELOG.md" <<'MD'
# Changelog

## [2026.11.2] - 2026-11-10

### Fixed
- 2026.11.2 条目。

## [2026.11.1] - 2026-11-05

### Added
- 滞留在草稿段里的未归并功能（#1636）。

## [2026.10.7] - 2026-10-28

### Added
- 已发布版本。

## [2026.10.6] - 2026-10-20

### Added
- 早于最早保留 Release 的历史版本。
MD
run_cs 1 "只读 token 下仍拦截滞留未发布小节 [2026.11.1]（且排除 --current v2026.11.2）→ 红（1）" \
  "$SCRIPT" --check --current v2026.11.2 "${R}/CHANGELOG.md"
has "[2026.11.1]" && ! has "[2026.11.2]" && ! has "[2026.10.6]" \
  && ok "  点名 [2026.11.1]，同时排除当前候选 v2026.11.2 与早于 v2026.10.7 的历史版本" || bad "  输出不对：$(cat "${TMP}/out")"

# 1b. 当前正在发布的候选版自身（tag 与草稿已建、处于 CHANGELOG 最顶部且无更新 tag）→ 不误报
cat >"${R}/CHANGELOG.md" <<'MD'
# Changelog

## [2026.11.2] - 2026-11-10

### Fixed
- 正在等待人工 Publish 的当前候选版条目。

## [2026.10.7] - 2026-10-28

### Added
- 已发布版本。
MD
run_cs 0 "不传 --current 时，位于 CHANGELOG 顶部且无更新 tag 的当前候选版 [2026.11.2] 不误判 → 绿（0）" \
  "$SCRIPT" --check "${R}/CHANGELOG.md"
run_cs 0 "传入 --current v2026.11.2 重跑同一候选版 → 绿（0）" \
  "$SCRIPT" --check --current v2026.11.2 "${R}/CHANGELOG.md"
run_cs 1 "反证：传入下一候选版 --current v2026.11.3 时，未发布的 [2026.11.2] 必须被拦 → 红（1）" \
  "$SCRIPT" --check --current v2026.11.3 "${R}/CHANGELOG.md"

# 1c. 空草稿段 / 写去向但仍留列表 → 红
cat >"${R}/CHANGELOG.md" <<'MD'
# Changelog

## [2026.11.2] - 2026-11-10

### Fixed
- 新条目。

## [2026.11.1] - 2026-11-05

## [2026.10.7] - 2026-10-28
MD
run_cs 1 "未发布 [2026.11.1] 为空且无去向说明 → 红（1）" "$SCRIPT" --check --current v2026.11.2 "${R}/CHANGELOG.md"

cat >"${R}/CHANGELOG.md" <<'MD'
# Changelog

## [2026.11.2] - 2026-11-10

### Fixed
- 新条目。

## [2026.11.1] - 2026-11-05

本版本未发布，内容已并入 [2026.11.2]。

- 残留条目未删。
MD
run_cs 1 "写了去向说明但仍残留条目列表 → 红（1）" "$SCRIPT" --check --current v2026.11.2 "${R}/CHANGELOG.md"

# 2. 合法做法（删掉旧头 或 保留并标注未发布/已并入且无列表）→ 绿
cat >"${R}/CHANGELOG.md" <<'MD'
# Changelog

## [2026.11.2] - 2026-11-10

### Added
- 已并入条目。
MD
run_cs 0 "已并入并移除 [2026.11.1] 小节 → 绿（0）" "$SCRIPT" --check --current v2026.11.2 "${R}/CHANGELOG.md"

cat >"${R}/CHANGELOG.md" <<'MD'
# Changelog

## [2026.11.2] - 2026-11-10

### Added
- 已并入条目。

## [2026.11.1] - 2026-11-05

本版本未发布，内容已并入 [2026.11.2]。
MD
run_cs 0 "保留 [2026.11.1] 并显式标注「本版本未发布，内容已并入」→ 绿（0）" "$SCRIPT" --check --current v2026.11.2 "${R}/CHANGELOG.md"

# 3. gh 查询失败 → fail-closed 红
touch "${FAKE}/releases.fail"
run_cs 1 "gh 查询失败 → fail-closed 退出 1" "$SCRIPT" --check --current v2026.11.2 "${R}/CHANGELOG.md"
has "fail-closed" && ok "  gh 失败明确报错" || bad "  未说明 fail-closed：$(cat "${TMP}/out")"
rm -f "${FAKE}/releases.fail"

# 4. 反证：绕过 --check 校验后滞留草稿段错误放行
cat >"${R}/CHANGELOG.md" <<'MD'
# Changelog

## [2026.11.1] - 2026-11-05

### Added
- 滞留条目。
MD
cat >"${TMP}/changelog-section-mutant.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--check" ]; then exit 0; fi
exit 2
SH
run_cs 0 "反证：绕过 --check 后滞留草稿段错误放行（证明门禁有效）" "${TMP}/changelog-section-mutant.sh" --check --current v2026.11.2 "${R}/CHANGELOG.md"

echo "── prev-published-tag.sh 与 notes-presence.sh（跳过草稿 tag，按已 Publish 算上一版）"
run_cs 0 "prev-published-tag.sh 跳过草稿 v2026.11.1/v2026.11.2，取 v2026.10.7" "$PREV_SCRIPT" --exclude v2026.11.3 HEAD
[ "$(tr -d '\n' <"${TMP}/out")" = "v2026.10.7" ] && ok "  正确返回 v2026.10.7" || bad "  返回不对：$(cat "${TMP}/out")"

# 反证：v2026.11.1 的 desktop=0.11.0，当前 0.11.1 与草稿比只涨了 desktop；但与已 Publish 的 v2026.10.7（0.10.1/0.10.2）比两万端都涨了，
# 若只写了 macos/windows 说明而缺 android 0.11.1 说明，notes-presence.sh 必须仍告警 android 缺失！
(cd "$R" && PATH="${TMP}/bin:${PATH}" FAKE="$FAKE" GH_REPO=o/r TAG=v2026.11.3 RUNNER_TEMP="$TMP" bash "tools/release/notes-presence.sh") >"${TMP}/out" 2>&1
has "::warning::android 版本涨到 0.11.1" && ok "notes-presence.sh 对比已 Publish v2026.10.7，正确告警 android 缺失说明（未被草稿 v2026.11.2 截断）" \
  || bad "notes-presence.sh 未按已 Publish 版比较：$(cat "${TMP}/out")"

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" = 0 ]
