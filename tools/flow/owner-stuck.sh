#!/usr/bin/env bash
# just owner-stuck：owner 流程停下的统一出口。说明见 docs/runbook/owner.md。
#
#   owner-stuck.sh "<原因>"                       开一个 status:blocked issue（同原因已有打开的就追加评论）
#   owner-stuck.sh "<原因>" --issue <号>          评论到该卡，并把它的状态换成 status:blocked
#   owner-stuck.sh "<原因>" --pr <号>             评论到该 PR，并给 PR 打 status:blocked
#   owner-stuck.sh "<原因>" --product "<选项一>" "<选项二>"
#                                                产品取向的问题：加打 needs:product，正文写两个选项
#   --log <文件>                                  附上日志末尾 60 行
#
# 选项能组合（如 --issue 12 --product A B）。写 GitHub 失败时把正文存到本机
# <git 公共目录>/ppass-batch/stuck-<时间>.md 并以 1 退出：这时要把原因原样转告产品负责人。

set -uo pipefail
# shellcheck source=tools/flow/owner-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/owner-lib.sh"

usage() { sed -n 2,14p "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ $# -ge 1 ] || usage
REASON="$1"
shift
[ -n "$(printf '%s' "$REASON" | tr -d '[:space:]')" ] || refuse "原因不能为空" "用法：just owner-stuck \"<一句话原因>\""
ISSUE=""
PR=""
LOG=""
OPT_A=""
OPT_B=""
PRODUCT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) ISSUE="${2:-}"; shift ;;
    --pr) PR="${2:-}"; shift ;;
    --log) LOG="${2:-}"; shift ;;
    --product)
      PRODUCT=1
      OPT_A="${2:-}"
      OPT_B="${3:-}"
      shift 2 || true
      ;;
    *) usage ;;
  esac
  shift
done
[ -z "$ISSUE" ] || [[ "$ISSUE" =~ ^[0-9]+$ ]] || refuse "--issue 要跟 issue 号"
[ -z "$PR" ] || [[ "$PR" =~ ^[0-9]+$ ]] || refuse "--pr 要跟 PR 号"
if [ "$PRODUCT" = 1 ]; then
  [ -n "$(printf '%s' "$OPT_A" | tr -d '[:space:]')" ] && [ -n "$(printf '%s' "$OPT_B" | tr -d '[:space:]')" ] ||
    refuse "--product 必须给两个非空选项" \
      "产品取向的问题要用产品语言写两个选项交产品负责人拍板：--product \"<选项一>\" \"<选项二>\""
fi

branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo '（detached）')"
head="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
{
  printf '**owner 流程停下**：%s\n\n' "$REASON"
  printf -- '- 分支：`%s` @ `%s`\n' "$branch" "$head"
  printf -- '- 时间：%s\n' "$(date '+%Y-%m-%d %H:%M %z')"
  if [ "$PRODUCT" = 1 ]; then
    printf '\n**需要产品负责人拍板**（二选一，回复选项号即可）：\n\n'
    printf '1. %s\n2. %s\n' "$OPT_A" "$OPT_B"
  fi
  if [ -n "$LOG" ] && [ -f "$LOG" ]; then
    printf '\n<details><summary>日志末尾（%s）</summary>\n\n```\n' "$(basename "$LOG")"
    tail -n 60 "$LOG" | sed 's/```/` ` `/g'
    printf '```\n</details>\n'
  fi
  printf '\n脚本已停下，没有做任何绕过。处理完后从停下的那一步重跑对应的 just 命令。\n'
} >"$BODY"

# 预演（release-test 的 --dry-run）：只打印，不写 GitHub。
if [ "${PPASS_OWNER_DRY:-}" = 1 ]; then
  say "（预演，不写 GitHub）将要写入${ISSUE:+ #${ISSUE}}${PR:+ PR #${PR}}："
  cat "$BODY" >&2
  exit 0
fi

save_local() {
  mkdir -p "$STATE_DIR"
  local f="${STATE_DIR}/stuck-$(date +%Y%m%d-%H%M%S).md"
  cp "$BODY" "$f"
  say "✗ 写 GitHub 失败，正文已存到 ${f}；把原因原样转告产品负责人"
  exit 1
}

command -v gh >/dev/null 2>&1 || save_local

labels="status:blocked"
[ "$PRODUCT" = 0 ] || labels="${labels},needs:product"

if [ -n "$ISSUE" ]; then
  gh issue comment "$ISSUE" -R "$REPO" --body-file "$BODY" >/dev/null || save_local
  set_status "$ISSUE" status:blocked || save_local
  [ "$PRODUCT" = 0 ] || gh issue edit "$ISSUE" -R "$REPO" --add-label needs:product >/dev/null || save_local
  okmsg "已评论 #${ISSUE} 并打上 ${labels}"
  exit 0
fi
if [ -n "$PR" ]; then
  gh pr comment "$PR" -R "$REPO" --body-file "$BODY" >/dev/null || save_local
  gh pr edit "$PR" -R "$REPO" --add-label "$labels" >/dev/null || save_local
  okmsg "已评论 PR #${PR} 并打上 ${labels}"
  exit 0
fi

title="[OWNER] $(printf '%s' "$REASON" | tr '\n' ' ' | cut -c1-80)"
existing="$(gh issue list -R "$REPO" --state open --label status:blocked --limit 100 \
  --json number,title --jq ".[] | select(.title == $(printf '%s' "$title" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')) | .number" 2>/dev/null | head -1)"
if [ -n "$existing" ]; then
  gh issue comment "$existing" -R "$REPO" --body-file "$BODY" >/dev/null || save_local
  okmsg "同一原因已有打开的 #${existing}，已追加评论"
  exit 0
fi
url="$(gh issue create -R "$REPO" --title "$title" --label "$labels" --body-file "$BODY")" || save_local
okmsg "已开 ${url}（${labels}）"
