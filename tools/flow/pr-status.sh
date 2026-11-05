#!/usr/bin/env bash
# just pr-status：一次列出 PR 合不进去的全部原因（#1421）。
#
# 列：未过的检查、还在跑的检查、未解决的评审线程（线程 ID、文件:行、级别、要点）、冲突、是否开了自动合入。
# 未解决线程里「已过时」的照样挡合入（main 要求对话全部解决），一并列出并标注。
# 给不在 Claude Desktop 里的执行端与 owner 排查用；线程用 just pr-thread 回复并关闭。
#
# 用法: tools/flow/pr-status.sh <PR号>
# 退出码: 0 全清（或已合入）；1 有卡点；3 没有卡点但还没出结果（检查在跑、冲突待 GitHub 算）；2 用法错或读不到。

set -uo pipefail

FLOW_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=worker-lib.sh
. "${FLOW_DIR}/worker-lib.sh"

[ $# -eq 1 ] && [[ "$1" =~ ^[0-9]+$ ]] || {
  printf '%s\n' "用法: just pr-status <PR号>" >&2
  exit 2
}
N="$1"
REPO="$(flow_repo)" || exit 2

Q='query($owner: String!, $name: String!, $n: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $n) {
      number title url state isDraft mergeable mergeStateStatus
      autoMergeRequest { mergeMethod }
      commits(last: 1) { nodes { commit { oid statusCheckRollup { contexts(first: 100) {
        pageInfo { hasNextPage }
        nodes {
          __typename
          ... on CheckRun { name status conclusion detailsUrl }
          ... on StatusContext { context state targetUrl }
        }
      } } } } }
      reviewThreads(first: 100) {
        pageInfo { hasNextPage }
        nodes { id isResolved isOutdated path line originalLine
          comments(first: 1) { nodes { author { login } body } } }
      }
    }
  }
}'

if ! JSON="$(gh api graphql -f query="$Q" -f owner="${REPO%%/*}" -f name="${REPO#*/}" -F n="$N" 2>&1)"; then
  printf '✗ 读 %s#%s 失败。gh 输出：\n%s\n' "$REPO" "$N" "$JSON" >&2
  exit 2
fi

printf '%s' "$JSON" | python3 -I -X utf8 -c '
import json, re, sys

d = json.load(sys.stdin)
pr = ((d.get("data") or {}).get("repository") or {}).get("pullRequest")
if not pr:
    print("✗ 读不到这个 PR：" + json.dumps(d.get("errors") or d, ensure_ascii=False)[:300], file=sys.stderr)
    sys.exit(2)

print("PR #%s %s" % (pr["number"], pr["title"]))
print("  " + pr["url"])
state = pr["state"]
if state == "MERGED":
    print("✅ 已合入")
    sys.exit(0)
if state == "CLOSED":
    print("✗ 已关闭（没合入）")
    sys.exit(1)

block = []   # 卡点：要人或会话动手
wait = []    # 还没出结果

if pr.get("isDraft"):
    block.append("草稿 PR：转成 ready for review 才会合")

# ── 检查 ──
FAILED = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"}
failed, running = [], []
nodes = pr["commits"]["nodes"]
roll = (nodes[0]["commit"].get("statusCheckRollup") if nodes else None) or {}
ctx = roll.get("contexts") or {"nodes": [], "pageInfo": {}}
for c in ctx.get("nodes") or []:
    if c.get("__typename") == "CheckRun":
        name, url = c.get("name"), c.get("detailsUrl") or ""
        if c.get("status") != "COMPLETED":
            running.append(name)
        elif c.get("conclusion") in FAILED:
            failed.append("%s（%s）%s" % (name, c.get("conclusion"), url))
    else:
        name, url, st = c.get("context"), c.get("targetUrl") or "", c.get("state")
        if st in ("PENDING", "EXPECTED"):
            running.append(name)
        elif st in FAILED:
            failed.append("%s（%s）%s" % (name, st, url))
if (ctx.get("pageInfo") or {}).get("hasNextPage"):
    print("⚠ 检查超过 100 个，只看了前 100 个")

print()
print("检查：未过 %d，进行中 %d" % (len(failed), len(running)))
for f in failed:
    print("  ✗ " + f)
for r in running:
    print("  … " + r)
if failed:
    block.append("%d 个检查没过" % len(failed))
if running:
    wait.append("%d 个检查还在跑" % len(running))

# ── 评审线程 ──
CHUNK = r"(?:\*\*[^*]+\*\*|_[^_]+_)"
META = re.compile(CHUNK + r"(?:\s*[·|]\s*" + CHUNK + r")*")
LEVEL = re.compile(r"\b(Critical|Major|Minor|Trivial|Nitpick)\b")

def gist(body):
    # 评审机器人的首条评论：先是级别徽章行（如 **Minor** · **Quick win**），再是加粗的要点。
    body = re.sub(r"<!--.*?-->", "", body or "", flags=re.S)
    body = re.sub(r"<[^>]+>", "", body)
    level, text = "", ""
    for line in body.splitlines():
        line = line.strip()
        if not line:
            continue
        if META.fullmatch(line) and (re.search(r"[·|]", line) or (LEVEL.search(line) and len(line) < 40)):
            m = LEVEL.search(line)
            if m and not level:
                level = m.group(1)
            continue
        text = line.replace("**", "").replace("`", "").strip(" _#>-\t")
        if text:
            break
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > 100:
        text = text[:100] + "…"
    return level, text

threads = pr["reviewThreads"]
open_t = [t for t in threads["nodes"] if not t["isResolved"]]
print()
print("未解决的评审线程：%d" % len(open_t))
for t in open_t:
    line = t.get("line") or t.get("originalLine")
    loc = "%s:%s" % (t.get("path"), line if line else "?")
    cs = t["comments"]["nodes"]
    who = ((cs[0].get("author") or {}).get("login") if cs else None) or "?"
    level, text = gist(cs[0].get("body") if cs else "")
    tags = []
    if level:
        tags.append(level)
    if t.get("isOutdated"):
        tags.append("已过时")
    print("  %s  %s  @%s%s" % (t["id"], loc, who, ("  [" + "，".join(tags) + "]") if tags else ""))
    if text:
        print("      " + text)
if threads["pageInfo"].get("hasNextPage"):
    print("⚠ 评审线程超过 100 条，只看了前 100 条")
if open_t:
    block.append("%d 条评审线程没解决（判定后用 just pr-thread <线程ID> \"<回复>\" 回复并关闭）" % len(open_t))

# ── 冲突 ──
print()
ms, mg = pr.get("mergeStateStatus"), pr.get("mergeable")
if ms == "DIRTY" or mg == "CONFLICTING":
    print("冲突：有（先 git rebase origin/main 解决）")
    block.append("和 main 有冲突")
elif mg == "UNKNOWN":
    print("冲突：未知（GitHub 还在算，过一会儿再看）")
    wait.append("冲突状态还没算出来")
else:
    print("冲突：无")
if ms == "BEHIND":
    print("  分支落后 main（mergeStateStatus=BEHIND）")

# ── 自动合入 ──
am = pr.get("autoMergeRequest")
print("自动合入：" + ("已开（%s）" % am.get("mergeMethod") if am else "没开"))

print()
if block:
    print("合不进去：" + "；".join(block + wait))
    sys.exit(1)
if wait:
    print("暂无卡点，等：" + "；".join(wait))
    sys.exit(3)
print("✅ 全清：没有未过的检查、未解决的线程和冲突")
sys.exit(0)
'
