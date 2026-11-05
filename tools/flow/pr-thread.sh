#!/usr/bin/env bash
# just pr-thread：回复一条 PR 评审线程并标为已解决（#1421）。
#
# main 要求「对话全部解决」才能合入；CodeRabbit 等评审的行内意见由开 PR 的会话逐条判定：
# 成立就改代码，改完或不改都在线程里回一句理由，再关掉线程。这条命令把「回复 + 关闭」做成一步。
#
# 用法:
#   tools/flow/pr-thread.sh <线程ID> "<回复>"     回复后关闭
#   tools/flow/pr-thread.sh --resolve-only <线程ID>  只关闭（回复已发出、上次关闭失败时用，免得重复回复）
# 线程 ID 形如 PRRT_xxx，用 just pr-status <PR号> 列出。
#
# 内部是两次 gh api graphql：addPullRequestReviewThreadReply、resolveReviewThread；
# 回复正文只走变量传入，不拼进查询字符串。
# 退出码: 0 成功；1 gh 调用失败（打印 gh 原文与停在哪一步）；2 用法错。

set -uo pipefail

usage() {
  printf '%s\n' "用法: just pr-thread <线程ID> \"<回复>\"   或   tools/flow/pr-thread.sh --resolve-only <线程ID>" >&2
  printf '%s\n' "线程 ID 形如 PRRT_xxx，用 just pr-status <PR号> 查。" >&2
  exit 2
}

REPLY_Q='mutation($id: ID!, $body: String!) { addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $id, body: $body}) { comment { url } } }'
RESOLVE_Q='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { id isResolved } } }'

RESOLVE_ONLY=0
if [ "${1:-}" = "--resolve-only" ]; then
  RESOLVE_ONLY=1
  shift
  [ $# -eq 1 ] || usage
  ID="$1"
  BODY=""
else
  [ $# -eq 2 ] || usage
  ID="$1"
  BODY="$2"
fi

case "$ID" in
  PRRT_?*) ;;
  *)
    printf '✗ 线程 ID「%s」不对：评审线程的 ID 以 PRRT_ 开头（不是评论 ID）。\n' "$ID" >&2
    usage
    ;;
esac
if [ "$RESOLVE_ONLY" = 0 ] && [ -z "$(printf '%s' "$BODY" | tr -d '[:space:]')" ]; then
  printf '%s\n' "✗ 回复不能为空：写明改了什么，或为什么不改。" >&2
  usage
fi

if [ "$RESOLVE_ONLY" = 0 ]; then
  if ! out="$(gh api graphql -f query="$REPLY_Q" -f id="$ID" -f body="$BODY" --jq '.data.addPullRequestReviewThreadReply.comment.url' 2>&1)"; then
    printf '✗ 回复线程 %s 失败（没回复，也没关闭）。gh 输出：\n%s\n' "$ID" "$out" >&2
    exit 1
  fi
  printf '已回复：%s\n' "$out"
fi

if ! out="$(gh api graphql -f query="$RESOLVE_Q" -f id="$ID" --jq '.data.resolveReviewThread.thread.isResolved' 2>&1)"; then
  printf '✗ 关闭线程 %s 失败（回复%s）。gh 输出：\n%s\n' "$ID" "$([ "$RESOLVE_ONLY" = 1 ] && echo '本次没发' || echo '已发出')" "$out" >&2
  printf '%s\n' "  只重试关闭：tools/flow/pr-thread.sh --resolve-only ${ID}" >&2
  exit 1
fi
if [ "$out" != "true" ]; then
  printf '✗ 关闭线程 %s 后 GitHub 回报 isResolved=%s。\n' "$ID" "${out:-空}" >&2
  printf '%s\n' "  只重试关闭：tools/flow/pr-thread.sh --resolve-only ${ID}" >&2
  exit 1
fi
printf '已关闭线程 %s\n' "$ID"
