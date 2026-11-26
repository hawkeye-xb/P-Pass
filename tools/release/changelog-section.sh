#!/usr/bin/env bash
# #773：正式 tag 的 Release 正文要以 CHANGELOG 本版小节开头（docs/RELEASING.md §3 第 5 步）。
# #1636：新增 --check 模式，拦截「存在正式形状 git tag 但 Release 仍为草稿」在 CHANGELOG.md 中滞留未归并小节。
#
# 用法：
#   tools/release/changelog-section.sh <tag> <输出文件> [CHANGELOG 路径，默认 CHANGELOG.md]
#   tools/release/changelog-section.sh --check [CHANGELOG 路径，默认 CHANGELOG.md]
#
# 抽取模式：
#   正式 tag v<批次号>：从 CHANGELOG 取 `## [<批次号>]` 标题下、到下一个 `## [` 为止的全文，写成
#       ## 本版更新（<批次号>）
#
#       <小节全文>
#
#       ---
#
#   （后面接构建台账）。
#   test tag（含 `-test.`）：写空文件——test 版没有 CHANGELOG 小节，正文保持原样。
#   正式 tag 但 CHANGELOG 没有该节或该节为空：写空文件 + ::warning::，退出码 0（不阻断发布）。
#
# 检查模式（--check）：
#   查询 GitHub Releases（覆盖 isDraft=true，排除 -test. 与 prerelease）并结合仓库正式形状 git tag（v* 且不含 -），
#   找出所有「存在 git tag 但对应 Release 仍为草稿」的批次号 <batch>：
#   - 若 CHANGELOG.md 已无 `## [<batch>]` 小节（已并入下版并删头）→ 通过；
#   - 若仍保留 `## [<batch>]`，则正文必须显式标注去向（如「本版本未发布，内容已并入 [x.y.z]。」「不发布」「已并入」），
#     且不得滞留 `### Added/Changed/Fixed/Security/...` 或变更条目列表；
#   - 任一草稿小节不满足或 gh / git 查询失败（fail-closed）→ 退出码 1。
set -euo pipefail

usage() {
  echo "用法: $0 <tag> <输出文件> [CHANGELOG 路径] | $0 --check [CHANGELOG 路径]" >&2
  exit 2
}

if [ "${1:-}" = "--check" ]; then
  [ "$#" -le 2 ] || usage
  CHANGELOG="${2:-CHANGELOG.md}"
  if [ ! -f "$CHANGELOG" ]; then
    echo "::error::找不到 CHANGELOG 文件：${CHANGELOG}" >&2
    exit 1
  fi
  REPO="${GH_REPO:-${PPASS_HOOK_REPO:-${GITHUB_REPOSITORY:-}}}"
  GH_ARGS=()
  if [ -n "$REPO" ]; then
    GH_ARGS+=(-R "$REPO")
  fi
  ERR_FILE="$(mktemp)"
  trap 'rm -f "$ERR_FILE"' EXIT
  if ! RELEASES_JSON="$(gh release list ${GH_ARGS[@]+"${GH_ARGS[@]}"} --limit 1000 --json tagName,isDraft,isPrerelease 2>"$ERR_FILE")"; then
    echo "::error::查询 GitHub Releases 失败（fail-closed）：$(head -3 "$ERR_FILE" | tr '\n' ' ')" >&2
    exit 1
  fi
  if ! GIT_TAGS="$(git tag -l 'v*' 2>"$ERR_FILE")"; then
    echo "::error::读取本地 git tag 失败（fail-closed）：$(head -3 "$ERR_FILE" | tr '\n' ' ')" >&2
    exit 1
  fi
  python3 - "$CHANGELOG" "$RELEASES_JSON" "$GIT_TAGS" <<'PY'
import json, re, sys

changelog_path, releases_raw, tags_raw = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    releases = json.loads(releases_raw)
except Exception as exc:
    sys.stderr.write(f"::error::解析 GitHub Releases JSON 失败（fail-closed）：{exc}\n")
    sys.exit(1)
if not isinstance(releases, list):
    sys.stderr.write("::error::GitHub Releases 返回格式不是列表（fail-closed）\n")
    sys.exit(1)

git_tags = {ln.strip() for ln in tags_raw.splitlines() if ln.strip()}
draft_batches = []
seen = set()
for rel in releases:
    if not isinstance(rel, dict):
        continue
    tag = str(rel.get("tagName") or "").strip()
    if not tag or tag in seen:
        continue
    if rel.get("isDraft") is not True or rel.get("isPrerelease") is True:
        continue
    if not re.fullmatch(r"v[^-]+", tag):
        continue
    if tag not in git_tags:
        continue
    seen.add(tag)
    draft_batches.append(tag[1:])

if not draft_batches:
    print("ok: 没有处于草稿状态的正式 Release tag")
    sys.exit(0)

text = open(changelog_path, encoding="utf-8").read()
lines = text.splitlines()

def extract_section(batch: str) -> str | None:
    head = f"## [{batch}]"
    found = False
    buf = []
    for ln in lines:
        if not found:
            if ln.startswith(head):
                found = True
            continue
        if ln.startswith("## ["):
            break
        buf.append(ln)
    if not found:
        return None
    while buf and not buf[0].strip():
        buf.pop(0)
    while buf and not buf[-1].strip():
        buf.pop()
    return "\n".join(buf)

DISPOSITION_RE = re.compile(r"(本版本未发布|本版未发布|未发布|不发布|已并入|内容已并入|not released|unpublished|merged into)", re.I)
SUBHEADER_OR_ITEM_RE = re.compile(r"^\s*(?:#{3,}\s+|(?:[-*+]|\d+\.)\s+)", re.M)

bad = []
for batch in draft_batches:
    sec = extract_section(batch)
    if sec is None:
        continue
    reasons = []
    if SUBHEADER_OR_ITEM_RE.search(sec):
        reasons.append("仍滞留独立的变更小节（### ...）或条目列表，尚未完全并入下一正式版")
    if not sec.strip() or not DISPOSITION_RE.search(sec):
        reasons.append("未显式标注去向（须写明如「本版本未发布，内容已并入 [x.y.z]。」或「本版本未发布 / 不发布」）")
    if reasons:
        bad.append((batch, reasons))

if bad:
    for batch, reasons in bad:
        sys.stderr.write(f"::error::CHANGELOG.md 中的草稿版本 [{batch}]（v{batch} Release 仍为 Draft）去向不明确：{'；'.join(reasons)}\n")
    sys.exit(1)

print(f"ok: CHANGELOG 草稿版本小节去向检查通过（已核对 {len(draft_batches)} 个草稿正式 tag）")
PY
  exit 0
fi

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
TAG="$1"; OUT="$2"; CHANGELOG="${3:-CHANGELOG.md}"
: > "$OUT"

case "$TAG" in
  *-test.*) exit 0 ;;
esac

BATCH="${TAG#v}"
SECTION=""
if [ -f "$CHANGELOG" ]; then
  # 标题行形如 `## [2026.10.3] - 2026-10-09`；批次号按字面匹配（点号不当正则）。
  # 去掉小节首尾的空行（纯 awk：GNU / BSD sed 的多行写法不通用）。
  SECTION="$(awk -v head="## [$BATCH]" '
    index($0, head) == 1 { on = 1; next }
    on && /^## \[/ { exit }
    on { lines[++n] = $0 }
    END {
      s = 1; while (s <= n && lines[s] ~ /^[[:space:]]*$/) s++
      e = n; while (e >= s && lines[e] ~ /^[[:space:]]*$/) e--
      for (i = s; i <= e; i++) print lines[i]
    }
  ' "$CHANGELOG")"
fi

if [ -z "$SECTION" ]; then
  echo "::warning::CHANGELOG 里没有 [$BATCH] 小节（或为空）——Release 正文只有构建台账。发布前补上 CHANGELOG 再重跑，或手工编辑正文。"
  exit 0
fi

{
  printf '## 本版更新（%s）\n\n' "$BATCH"
  printf '%s\n\n' "$SECTION"
  printf -- '---\n\n'
} > "$OUT"
echo "Release 正文开头：CHANGELOG [$BATCH] 小节（$(printf '%s\n' "$SECTION" | wc -l | tr -d ' ') 行）"
