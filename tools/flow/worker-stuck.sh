#!/usr/bin/env bash
# just stuck <issue号> "<原因>"：四种必须停下的情况的统一出口
# （命中核心 / 需改范围外文件 / 没有可用的验收场景 / 同一处连红 3 次）。
# 在 issue 里写评论 + 打 status:blocked（去掉 doing/ready/review），然后去做下一张卡。
# 多卡分支（just start <号> <号>…）：卡号与 just done 同口径——分支名里的号 + branch.<分支>.ppasscards
# 里记的其余卡——一次给这条分支上的每张卡都写评论、打 status:blocked，不用人手补齐。
# 哪张没做成会点名，其余卡照做，最后非 0 退出。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FLOW_PATHS="${HERE}/../ci-paths.sh"
# shellcheck source=worker-lib.sh
. "${HERE}/worker-lib.sh"

N="${1:-}"
REASON="${2:-}"
[[ "$N" =~ ^[0-9]+$ ]] && [ -n "$(printf '%s' "$REASON" | tr -d '[:space:]')" ] ||
  die "用法: just stuck <issue号> \"<原因>\"" \
    "原因写清：属于哪种（命中核心 / 需改范围外文件 / 没有验收场景 / 连红 3 次）、停在哪、还剩什么。" \
    "多卡分支：在卡 worktree 里跑一次，这条分支关联的每张卡都会写评论、打 status:blocked。"
command -v gh >/dev/null 2>&1 || die "找不到 gh"
REPO="$(flow_repo)"

# 这条分支关联的卡（与 just done 同口径）：分支名里的号 + 分支配置里记的其余卡。
# 不在卡 worktree 里（主仓、别的分支）、或给的号不属于这条分支时，只处理命令行给的这一张。
CARDS=()
ON_BRANCH=()
branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [[ "$branch" =~ ^(feat|fix|docs|test|ci)/([0-9]+)- ]]; then
  ON_BRANCH+=("${BASH_REMATCH[2]}")
  rest="$(git config --get "branch.${branch}.ppasscards" 2>/dev/null)" || rest=""
  for c in $rest; do
    [[ "$c" =~ ^[0-9]+$ ]] || die "分支记录的卡号「${c}」不对" "git config --get branch.${branch}.ppasscards"
    case " ${ON_BRANCH[*]} " in *" ${c} "*) ;; *) ON_BRANCH+=("$c") ;; esac
  done
fi
case " ${ON_BRANCH[*]-} " in
  *" ${N} "*) CARDS=("${ON_BRANCH[@]}") ;;
  *) CARDS=("$N") ;;
esac
CARDS_SHOW=""
for c in "${CARDS[@]}"; do CARDS_SHOW="${CARDS_SHOW:+${CARDS_SHOW}、}#${c}"; done

tmp="$(mktemp)"
KEEP_TMP=""
trap '[ -n "$KEEP_TMP" ] || rm -f "$tmp"' EXIT
{
  echo "**worker 停下，等 owner 处理**"
  echo
  printf '%s\n' "$REASON" | scrub
  echo
  [ -z "$branch" ] || echo "当前分支：\`${branch}\`（改动不会推送）"
  [ "${#CARDS[@]}" -le 1 ] || echo "关联卡：${CARDS_SHOW}（同一条分支，一起打 status:blocked）"
} >"$tmp"

failed=()
comment_failed=""
for c in "${CARDS[@]}"; do
  if ! err="$( ( flow_load_issue "$c" ) 2>&1 )"; then
    failed+=("#${c} 读不到：$(printf '%s' "$err" | sed -n '2s/^✗ //p')")
    continue
  fi
  flow_comment "$c" "$tmp" || { failed+=("#${c} 写评论失败"); comment_failed=1; }
  flow_try_labels "$c" "status:blocked" "status:doing,status:ready,status:review" ||
    failed+=("#${c} 打 status:blocked 失败")
done

if [ "${#failed[@]}" -gt 0 ]; then
  hint=()
  # 评论贴失败时保留正文文件，下面给的补做命令直接可用。
  if [ -n "$comment_failed" ]; then
    KEEP_TMP=1
    hint+=("补做评论：gh issue comment <号> -R ${REPO} --body-file ${tmp}")
  fi
  hint+=("补做标签：gh issue edit <号> -R ${REPO} --add-label status:blocked --remove-label status:doing,status:ready,status:review")
  die "有 ${#failed[@]} 项没做成，其余卡已处理" "${failed[@]}" "${hint[@]}"
fi
echo "已在 ${CARDS_SHOW} 记录原因并打 status:blocked。现在去领下一张卡：just start <下一个 issue号>"
