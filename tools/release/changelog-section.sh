#!/usr/bin/env bash
# #773：正式 tag 的 Release 正文要以 CHANGELOG 本版小节开头（docs/RELEASING.md §3 第 5 步）。
# #1636：新增 --check 模式（仅依赖 contents: read），用「CHANGELOG 中已有正式 git tag 的版本段」与
#        「GitHub 已 Publish 正式 Release 列表」的差集拦截滞留未归并草稿段。
#
# 用法：
#   tools/release/changelog-section.sh <tag> <输出文件> [CHANGELOG 路径，默认 CHANGELOG.md]
#   tools/release/changelog-section.sh --check [--current <tag>] [CHANGELOG 路径，默认 CHANGELOG.md]
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
#   只依赖 `contents: read` 完全可见的信息（`gh release list --exclude-drafts --exclude-pre-releases`）：
#   1. 查询所有已 Publish 正式 Release（`isDraft == false && isPrerelease == false && ^v[^-]+$`）；
#   2. 结合仓库内正式形状 git tag（`v*` 且不含 `-`），跳过严格早于「GitHub 上最早保留的已 Publish 正式 Release」的历史 tag，
#      并排除当前候选版（`--current <tag>`；未传 `--current` 时，仅当某未发布小节位于 CHANGELOG 首位且没有更新的正式 tag/Release 时视为当前候选版）；
#   3. 对差集里仍存在于 `CHANGELOG.md` 中的 `## [<batch>]` 小节：
#      - 若仍滞留 `### Added/Changed/Fixed/Security/...` 或条目列表，或未显式标注去向（如「本版本未发布，内容已并入 [x.y.z]。」「不发布」「已并入」）→ 退出码 1；
#      - `gh` / `git` 查询失败（fail-closed）→ 退出码 1。
set -euo pipefail

usage() {
  echo "用法: $0 <tag> <输出文件> [CHANGELOG 路径] | $0 --check [--current <tag>] [CHANGELOG 路径]" >&2
  exit 2
}

if [ "${1:-}" = "--check" ]; then
  shift
  CURRENT=""
  CHANGELOG="CHANGELOG.md"
  SET_CL=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --current)
        CURRENT="${2:-}"
        [ -n "$CURRENT" ] || usage
        shift 2
        ;;
      -h|--help) usage ;;
      -*) usage ;;
      *)
        [ "$SET_CL" = 0 ] || usage
        CHANGELOG="$1"
        SET_CL=1
        shift
        ;;
    esac
  done
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
  if ! RELEASES_JSON="$(gh release list ${GH_ARGS[@]+"${GH_ARGS[@]}"} --exclude-drafts --exclude-pre-releases --limit 1000 --json tagName,isDraft,isPrerelease,publishedAt 2>"$ERR_FILE")"; then
    echo "::error::查询 GitHub Releases 失败（fail-closed）：$(head -3 "$ERR_FILE" | tr '\n' ' ')" >&2
    exit 1
  fi
  if ! GIT_TAGS="$(git tag -l 'v*' 2>"$ERR_FILE")"; then
    echo "::error::读取本地 git tag 失败（fail-closed）：$(head -3 "$ERR_FILE" | tr '\n' ' ')" >&2
    exit 1
  fi
  python3 - "$CHANGELOG" "$RELEASES_JSON" "$GIT_TAGS" "$CURRENT" <<'PY'
import json, re, subprocess, sys

changelog_path, releases_raw, tags_raw, current_tag = sys.argv[1:5]
try:
    releases = json.loads(releases_raw)
except Exception as exc:
    sys.stderr.write(f"::error::解析 GitHub Releases JSON 失败（fail-closed）：{exc}\n")
    sys.exit(1)
if not isinstance(releases, list):
    sys.stderr.write("::error::GitHub Releases 返回格式不是列表（fail-closed）\n")
    sys.exit(1)

formal_re = re.compile(r"^v[^-]+$")
git_tags = {ln.strip() for ln in tags_raw.splitlines() if ln.strip() and formal_re.fullmatch(ln.strip())}

published_formal = {}  # tag -> publishedAt
for rel in releases:
    if not isinstance(rel, dict):
        continue
    if rel.get("isDraft") is not False or rel.get("isPrerelease") is not False:
        continue
    tag = str(rel.get("tagName") or "").strip()
    if formal_re.fullmatch(tag):
        published_formal[tag] = str(rel.get("publishedAt") or "")

def is_ancestor(a: str, b: str) -> bool:
    if a == b:
        return True
    p = subprocess.run(["git", "merge-base", "--is-ancestor", f"refs/tags/{a}", f"refs/tags/{b}"], capture_output=True)
    return p.returncode == 0

# GitHub 上最早保留的已 Publish 正式 Release：严格早于它的历史 tag（Release 已被平台清理）不视作未发布草稿。
pub_in_git = sorted((t for t in published_formal if t in git_tags), key=lambda t: (published_formal[t], t))
earliest_pub = pub_in_git[0] if pub_in_git else None

# 解析 CHANGELOG.md 所有版本小节（保持出现顺序，排除 [Unreleased]）
lines = open(changelog_path, encoding="utf-8").read().splitlines()
sections = []  # [(batch, body)]
cur_batch = None
cur_buf = []
for ln in lines:
    m = re.match(r"^## \[([^\]]+)\]", ln)
    if m:
        if cur_batch is not None:
            sections.append((cur_batch, "\n".join(cur_buf).strip()))
        cur_batch = m.group(1)
        cur_buf = []
    elif cur_batch is not None:
        cur_buf.append(ln)
if cur_batch is not None:
    sections.append((cur_batch, "\n".join(cur_buf).strip()))

version_sections = [(b, s) for b, s in sections if b.lower() != "unreleased"]
top_batch = version_sections[0][0] if version_sections else None

unpublished_batches = []
for batch, sec in version_sections:
    tag = f"v{batch}"
    if tag not in git_tags:
        continue
    if tag in published_formal:
        continue
    if current_tag and tag == current_tag:
        continue
    if earliest_pub and tag != earliest_pub and is_ancestor(tag, earliest_pub):
        continue
    # 未显式传 --current 时：若位于 CHANGELOG 最顶部且没有更新的正式 tag 或已发布 Release 在它之后，视为正在等待 Publish 的当前候选版。
    if not current_tag and batch == top_batch:
        newer_tag = any(other != tag and is_ancestor(tag, other) for other in (git_tags | set(published_formal)))
        if not newer_tag:
            continue
    unpublished_batches.append((batch, sec))

if not unpublished_batches:
    print("ok: 没有去向不明的未发布正式 Release 小节")
    sys.exit(0)

DISPOSITION_RE = re.compile(r"(本版本未发布|本版未发布|未发布|不发布|已并入|内容已并入|改号为|not released|unpublished|merged into)", re.I)
SUBHEADER_OR_ITEM_RE = re.compile(r"^\s*(?:#{3,}\s+|(?:[-*+]|\d+\.)\s+)", re.M)

bad = []
for batch, sec in unpublished_batches:
    reasons = []
    if SUBHEADER_OR_ITEM_RE.search(sec):
        reasons.append("仍滞留独立的变更小节（### ...）或条目列表，尚未完全并入下一正式版")
    if not sec.strip() or not DISPOSITION_RE.search(sec):
        reasons.append("未显式标注去向（须写明如「本版本未发布，内容已并入 [x.y.z]。」或「本版本未发布 / 不发布」）")
    if reasons:
        bad.append((batch, reasons))

if bad:
    for batch, reasons in bad:
        sys.stderr.write(f"::error::CHANGELOG.md 中的未发布版本 [{batch}]（存在 git tag v{batch} 但未见已 Publish Release）去向不明确：{'；'.join(reasons)}\n")
    sys.exit(1)

print(f"ok: CHANGELOG 未发布版本小节去向检查通过（已核对 {len(unpublished_batches)} 个未发布正式 tag）")
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
