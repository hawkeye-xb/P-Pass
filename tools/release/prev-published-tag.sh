#!/usr/bin/env bash
# #1636：查询 <ref> 往前最近一个真正 Publish 过的正式 Release tag（仅依赖 contents: read）。
# 用法：tools/release/prev-published-tag.sh [--exclude <tag>] [<ref，默认 HEAD>]
# 输出：找到则打印 tag 名（退出 0）；gh 成功但没有符合条件的祖先 tag 则空输出（退出 0）；
#       gh 查询或解析失败时 fail-closed 打印错误到 stderr 并退出 1。
set -euo pipefail

EXCLUDE=""
REF="HEAD"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --exclude) EXCLUDE="${2:-}"; [ -n "$EXCLUDE" ] || { echo "用法: $0 [--exclude <tag>] [<ref>]" >&2; exit 2; }; shift 2 ;;
    -h|--help) echo "用法: $0 [--exclude <tag>] [<ref>]" >&2; exit 2 ;;
    *) REF="$1"; shift ;;
  esac
done

REPO="${GH_REPO:-${PPASS_HOOK_REPO:-${GITHUB_REPOSITORY:-}}}"
GH_ARGS=()
if [ -n "$REPO" ]; then
  GH_ARGS+=(-R "$REPO")
fi

ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT

if ! RAW="$(gh release list ${GH_ARGS[@]+"${GH_ARGS[@]}"} --exclude-drafts --exclude-pre-releases --limit 1000 \
  --json tagName,isDraft,isPrerelease,publishedAt 2>"$ERR_FILE")"; then
  printf '✗ 查询 GitHub Releases 失败（fail-closed）：%s\n' "$(head -3 "$ERR_FILE" | tr '\n' ' ')" >&2
  exit 1
fi

python3 - "$REF" "$EXCLUDE" "$RAW" <<'PY'
import json, re, subprocess, sys

ref, exclude, raw = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    rows = json.loads(raw)
except Exception as exc:
    sys.stderr.write(f"✗ 解析 GitHub Releases JSON 失败（fail-closed）：{exc}\n")
    sys.exit(1)
if not isinstance(rows, list):
    sys.stderr.write("✗ GitHub Releases 返回格式不是列表（fail-closed）\n")
    sys.exit(1)

best = None
for row in rows:
    if not isinstance(row, dict):
        continue
    if row.get("isDraft") is not False or row.get("isPrerelease") is not False:
        continue
    tag = str(row.get("tagName") or "").strip()
    if not tag or tag == exclude:
        continue
    if not re.fullmatch(r"v[^-]+", tag):
        continue
    sha_p = subprocess.run(
        ["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag}^{{commit}}"],
        capture_output=True, text=True,
    )
    if sha_p.returncode != 0:
        continue
    tag_sha = sha_p.stdout.strip()
    anc_p = subprocess.run(
        ["git", "merge-base", "--is-ancestor", tag_sha, ref],
        capture_output=True, text=True,
    )
    if anc_p.returncode != 0:
        continue
    cnt_p = subprocess.run(
        ["git", "rev-list", "--count", f"{tag_sha}..{ref}"],
        capture_output=True, text=True,
    )
    if cnt_p.returncode != 0:
        continue
    dist = int(cnt_p.stdout.strip())
    pub = str(row.get("publishedAt") or "")
    cand = (-dist, pub, tag)
    if best is None or cand > best:
        best = cand

if best is not None:
    print(best[2])
PY
