#!/usr/bin/env bash
# just batch-open <主题> <issue号>...：从最新 origin/main 开批次分支，逐张合入卡分支。
# 说明见 docs/runbook/owner.md。
#
# 做的事（任何一步红即停，不续跑）：
#   1. 主题只许小写字母、数字、短横线；分支 batch/<日期>-<主题> 与 worktree 目录都必须是新的。
#   2. 每张卡重跑 batch-plan 的全部判据；两两检查不同批（同文件 / 试合并冲突）就拒绝。
#   3. 在新 worktree（主仓旁边的 P-Pass-wt/batch-<日期>-<主题>）里按给定顺序
#      git merge --no-ff --signoff 每条卡分支；冲突 ⇒ merge --abort，评论到那张卡并打 status:blocked，停。
#   4. 全部合入后，卡的状态换成 status:batched，记下批次状态（每张卡的分支与提交）。
# 之后到打印出的 worktree 里跑 just batch-verify。

set -uo pipefail
# shellcheck source=tools/flow/owner-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/owner-lib.sh"

usage() { sed -n 2,12p "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 2 ] || usage
TOPIC="$1"
shift
[[ "$TOPIC" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] ||
  refuse "主题「${TOPIC}」不合规" "只许小写字母、数字、短横线，40 字以内，例如 thumbs-fix。"
ISSUES=()
for n in "$@"; do
  [[ "$n" =~ ^[0-9]+$ ]] || refuse "「${n}」不是 issue 号"
  case " ${ISSUES[*]-} " in *" ${n} "*) refuse "#${n} 重复了" ;; esac
  ISSUES+=("$n")
done

need_gh
fetch_origin

DATE="$(today)"
NAME="batch/${DATE}-${TOPIC}"
WT_ROOT="${PPASS_OWNER_WT_ROOT:-$(dirname "$(dirname "$COMMON_DIR")")/P-Pass-wt}"
[ "$(basename "$COMMON_DIR")" = ".git" ] || WT_ROOT="${PPASS_OWNER_WT_ROOT:-$(dirname "$COMMON_DIR")/P-Pass-wt}"
DIR="${WT_ROOT}/batch-${DATE}-${TOPIC}"

if git show-ref --verify --quiet "refs/heads/${NAME}" || git show-ref --verify --quiet "refs/remotes/origin/${NAME}"; then
  refuse "分支 ${NAME} 已存在" "批次分支不复用，换一个主题名重开（例如加 -2）。"
fi
[ ! -e "$DIR" ] || refuse "目录 ${DIR} 已存在" "换一个主题名重开。"
[ ! -e "$(batch_dir "$NAME")" ] || refuse "批次状态目录已存在：$(batch_dir "$NAME")" "换一个主题名重开。"

step "逐张核对卡（与 batch-plan 同一判据）"
BRS=()
for n in "${ISSUES[@]}"; do
  if ! check_card "$n"; then
    [ "$CARD_BLOCK" = 1 ] && die_stuck "batch-open 拒收 #${n}：${CARD_ERR}" --issue "$n"
    refuse "#${n} 不能进批次：${CARD_ERR}" "先跑 just batch-plan 看建议批次。"
  fi
  BRS+=("$CARD_BRANCH")
  eval "SHA_${n}=\"\$CARD_SHA\""
  eval "TITLE_${n}=\"\$ISSUE_TITLE\""
  okmsg "#${n} ${CARD_BRANCH} @ ${CARD_SHA:0:10}"
done
i=0
while [ "$i" -lt "${#BRS[@]}" ]; do
  j=$((i + 1))
  while [ "$j" -lt "${#BRS[@]}" ]; do
    branches_compatible "${BRS[$i]}" "${BRS[$j]}" ||
      refuse "这几张卡不能同批：${COMPAT_ERR}" "按 just batch-plan 的建议分批。"
    j=$((j + 1))
  done
  i=$((i + 1))
done

step "开批次 ${NAME}（worktree：${DIR}）"
BASE="$(git rev-parse origin/main)"
mkdir -p "$WT_ROOT"
git worktree add -q --no-track -b "$NAME" "$DIR" "$BASE" || die_stuck "git worktree add 失败：${DIR}"
state_set "$NAME" TOPIC "$TOPIC"
state_set "$NAME" BASE "$BASE"
state_set "$NAME" WORKTREE "$DIR"
state_set "$NAME" ISSUES "${ISSUES[*]}"

i=0
for n in "${ISSUES[@]}"; do
  br="${BRS[$i]}"
  i=$((i + 1))
  eval "sha=\"\$SHA_${n}\""
  eval "title=\"\$TITLE_${n}\""
  step "合入 #${n} ${br}"
  log="$(batch_dir "$NAME")/merge-${n}.log"
  if ! git -C "$DIR" merge --no-ff --signoff -m "merge #${n}: ${title} (${br})" "$sha" >"$log" 2>&1; then
    conflicts="$(git -C "$DIR" diff --name-only --diff-filter=U | tr '\n' ' ')"
    git -C "$DIR" merge --abort >/dev/null 2>&1
    if [ -n "$conflicts" ]; then
      die_stuck "合入批次 ${NAME} 时与前面的卡冲突：${conflicts% }。worker 基于 ${NAME} 之外的最新 main 解决不了时，等前一批合入后 rebase 再交" --issue "$n" --log "$log"
    fi
    die_stuck "合入 #${n}（${br}）失败（不是冲突，见日志）" --issue "$n" --log "$log"
  fi
  state_set "$NAME" "CARD_${n}" "${br}@${sha}"
  okmsg "#${n} 已合入"
done

step "卡状态 → status:batched"
for n in "${ISSUES[@]}"; do
  set_status "$n" status:batched || die_stuck "把 #${n} 换成 status:batched 失败" --issue "$n"
done
state_set "$NAME" OPENED_SHA "$(git -C "$DIR" rev-parse HEAD)"

printf '\nBATCH-OPEN OK %s %s\n' "$NAME" "${ISSUES[*]}"
say "下一步："
say "  cd ${DIR}"
say "  just batch-verify"
