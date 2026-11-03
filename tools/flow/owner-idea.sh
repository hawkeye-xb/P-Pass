#!/usr/bin/env bash
# just idea "<一句话>" [--discuss] [--from <来源>]：任何会话收到人类的新想法时用。说明见 docs/runbook/owner.md。
#
#   默认        建 Discussions 的 Ideas 帖：想法不进看板，等产品负责人说「要做」
#   --discuss   「要做，但要先定方案」：建 status:inbox 的 issue（类型 Feature），之后由 owner 跑 just triage
#   --from      来源（谁、在哪说的），默认「agent 会话转述」
# 正文 = 原话（一字不改）+ 来源 + 日期。标题就是原话（超过 80 字截断）。
# 同标题已有打开的帖子 / issue 时不重复建，追加一条评论。

set -uo pipefail
# shellcheck source=tools/flow/owner-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/owner-lib.sh"

# 开工前自检：位置、shell、提交拦截、gh、提交身份、磁盘、私仓模式。不过就停，不带病继续。
bash "${FLOW_DIR}/doctor.sh" || exit 1

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage
TEXT="$1"
shift
[ -n "$(printf '%s' "$TEXT" | tr -d '[:space:]')" ] || refuse "想法不能为空" "用法：just idea \"<一句话>\" [--discuss]"
DISCUSS=0
FROM="agent 会话转述"
while [ $# -gt 0 ]; do
  case "$1" in
    --discuss) DISCUSS=1 ;;
    --from) FROM="${2:-}"; shift ;;
    *) usage ;;
  esac
  shift
done
need_gh

TITLE="$(printf '%s' "$TEXT" | tr '\n' ' ' | cut -c1-80)"
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
{
  printf '**原话**：\n\n'
  printf '%s\n' "$TEXT" | sed 's/^/> /'
  printf '\n**来源**：%s\n\n**记录日期**：%s\n' "$FROM" "$(today)"
} >"$BODY"
OWNER="${REPO%%/*}"
NAME="${REPO#*/}"
json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"; }

if [ "$DISCUSS" = 1 ]; then
  existing="$(gh issue list -R "$REPO" --state open --limit 200 --json number,title \
    --jq ".[] | select(.title == $(json_str "$TITLE")) | .number" 2>/dev/null | head -1)"
  if [ -n "$existing" ]; then
    gh issue comment "$existing" -R "$REPO" --body-file "$BODY" >/dev/null || die_stuck "给 #${existing} 追加想法失败"
    printf 'IDEA ISSUE #%s（同标题已存在，已追加评论）\n' "$existing"
    exit 0
  fi
  url="$(gh issue create -R "$REPO" --title "$TITLE" --label status:inbox --body-file "$BODY" 2>&1)" ||
    die_stuck "建 issue 失败：$(printf '%s' "$url" | tail -1)"
  n="$(printf '%s' "$url" | grep -oE '[0-9]+$' | tail -1)"
  [ -n "$n" ] || die_stuck "gh issue create 没返回 issue 号：${url}"
  # gh 2.87 的 issue create 没有 --type，类型走 GraphQL。
  ids="$(gh api graphql -f query="query{repository(owner:$(json_str "$OWNER"),name:$(json_str "$NAME")){issue(number:${n}){id} issueTypes(first:20){nodes{id name}}}}" \
    --jq '.data.repository | .issue.id + " " + ([.issueTypes.nodes[] | select(.name == "Feature") | .id][0] // "")' 2>&1)" ||
    die_stuck "#${n} 已建，但读不到 issue 类型列表：$(printf '%s' "$ids" | head -1)" --issue "$n"
  iid="${ids%% *}"
  tid="${ids#* }"
  [ -n "$tid" ] && [ "$tid" != "$ids" ] || die_stuck "#${n} 已建，但仓库没有 Feature 类型" --issue "$n"
  gh api graphql -f query="mutation{updateIssue(input:{id:$(json_str "$iid"),issueTypeId:$(json_str "$tid")}){issue{number}}}" >/dev/null ||
    die_stuck "#${n} 已建，但设类型 Feature 失败" --issue "$n"
  printf 'IDEA ISSUE #%s status:inbox Feature\n' "$n"
  say "下一步：owner 跑 just triage ${n}"
  exit 0
fi

meta="$(gh api graphql -f query="query{repository(owner:$(json_str "$OWNER"),name:$(json_str "$NAME")){id discussionCategories(first:30){nodes{id name}}}}" \
  --jq '.data.repository | .id + " " + ([.discussionCategories.nodes[] | select(.name == "Ideas") | .id][0] // "")' 2>&1)" ||
  die_stuck "读不到 Discussions 分类：$(printf '%s' "$meta" | head -1)"
rid="${meta%% *}"
cid="${meta#* }"
[ -n "$cid" ] && [ "$cid" != "$meta" ] || die_stuck "仓库 Discussions 没有 Ideas 分类"
dup="$(gh api graphql -f query="query{repository(owner:$(json_str "$OWNER"),name:$(json_str "$NAME")){discussions(first:100,states:OPEN,orderBy:{field:CREATED_AT,direction:DESC}){nodes{id number title}}}}" \
  --jq ".data.repository.discussions.nodes[] | select(.title == $(json_str "$TITLE")) | .id + \" \" + (.number|tostring)" 2>/dev/null | head -1)"
if [ -n "$dup" ]; then
  gh api graphql -f query="mutation{addDiscussionComment(input:{discussionId:$(json_str "${dup%% *}"),body:$(json_str "$(cat "$BODY")")}){comment{id}}}" >/dev/null ||
    die_stuck "给讨论 #${dup#* } 追加想法失败"
  printf 'IDEA DISCUSSION #%s（同标题已存在，已追加评论）\n' "${dup#* }"
  exit 0
fi
num="$(gh api graphql -f query="mutation{createDiscussion(input:{repositoryId:$(json_str "$rid"),categoryId:$(json_str "$cid"),title:$(json_str "$TITLE"),body:$(json_str "$(cat "$BODY")")}){discussion{number}}}" \
  --jq '.data.createDiscussion.discussion.number' 2>&1)" || die_stuck "建 Ideas 讨论失败：$(printf '%s' "$num" | head -1)"
printf 'IDEA DISCUSSION #%s\n' "$num"
say "想法已记在 Discussions 的 Ideas，不进看板。产品负责人说「要做」后，owner 用「Create issue from discussion」转成 issue。"
