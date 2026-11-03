#!/usr/bin/env bash
# just batch-plan：列出 worker 已交的卡（status:review），逐张判能不能进批次，输出建议批次。
# 说明见 docs/runbook/owner.md。
#
#   owner-batch-plan.sh            判定 + 把不合格且需要 worker 返工的卡打回 status:blocked（写明原因）
#   owner-batch-plan.sh --dry-run  只判定、只打印，不改任何 issue（停下时也只打印要写的内容）
#
# 每张卡的判据（任一不过 = 排除）：issue 打开且带 status:review；远端恰好一条 <type>/<号>-<slug> 分支；
# 分支包含最新 origin/main；没有 Hook-Bypass 尾行；DCO 齐；改动全在 issue「范围」内；
# 命中核心时带 core 标签且引用 origin/main 上「已采纳」的 ADR（docs/decisions/）。
# 两张卡改了同一个文件、或试合并（git merge-tree）有冲突 ⇒ 不进同一批。
#
# 输出（stdout，每行一条，供人和脚本读）：
#   PLAN BATCH <序号> <号> <号>...
#   PLAN EXCLUDE <号> <原因>
#   PLAN EMPTY                      （没有可进批次的卡）

set -uo pipefail
# shellcheck source=tools/flow/owner-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/owner-lib.sh"

# 开工前自检：位置、shell、提交拦截、gh、提交身份、磁盘、私仓模式。不过就停，不带病继续。
bash "${FLOW_DIR}/doctor.sh" || exit 1

DRY=0
case "${1:-}" in
  --dry-run) DRY=1; export PPASS_OWNER_DRY=1 ;;
  "") ;;
  *) sed -n 2,17p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

need_gh
fetch_origin

labels="$(gh label list -R "$REPO" --limit 300 --json name --jq '.[].name' 2>&1)" ||
  die_stuck "读不到仓库标签列表：$(printf '%s' "$labels" | head -1)"
printf '%s\n' "$labels" | grep -qx 'status:review' ||
  die_stuck "仓库没有 status:review 标签（worker 交卡命令还没合入？），判断不了哪些卡已交"

nums="$(gh issue list -R "$REPO" --state open --label status:review --limit 200 \
  --json number --jq '.[].number' 2>&1)" || die_stuck "列 status:review 的 issue 失败：$(printf '%s' "$nums" | head -1)"
nums="$(printf '%s\n' "$nums" | grep -E '^[0-9]+$' | sort -n)"
if [ -z "$nums" ]; then
  echo "PLAN EMPTY"
  exit 0
fi

OK=()
for n in $nums; do
  if check_card "$n"; then
    OK+=("$n")
    eval "BR_${n}=\"\$CARD_BRANCH\""
    note=""
    [ "$CARD_CORE" = false ] || note="（核心，定案：$(printf '%s' "$CARD_ADRS" | tr '\n' ' ')）"
    say "  ✓ #${n} ${CARD_BRANCH}${note}"
  else
    echo "PLAN EXCLUDE ${n} ${CARD_ERR}"
    if [ "$CARD_BLOCK" = 1 ] && [ "$DRY" = 0 ]; then
      block_card "$n" "batch-plan 排除：${CARD_ERR}" || die_stuck "把 #${n} 打回 status:blocked 失败"
    fi
  fi
done

compatible() { # compatible <号> <号>
  local ba bb
  eval "ba=\"\$BR_$1\""
  eval "bb=\"\$BR_$2\""
  branches_compatible "$ba" "$bb" && return 0
  say "  ⚠ #$1 与 #$2 不能同批：${COMPAT_ERR}"
  return 1
}

# 贪心分批：按卡号顺序，放进第一个与组内每张卡都兼容的批次。
NB=0
for n in ${OK[@]+"${OK[@]}"}; do
  placed=0
  i=1
  while [ "$i" -le "$NB" ]; do
    eval "members=\"\$BATCH_${i}\""
    fits=1
    for m in $members; do compatible "$m" "$n" || { fits=0; break; }; done
    if [ "$fits" = 1 ]; then
      eval "BATCH_${i}=\"\$members ${n}\""
      placed=1
      break
    fi
    i=$((i + 1))
  done
  if [ "$placed" = 0 ]; then
    NB=$((NB + 1))
    eval "BATCH_${NB}=\"${n}\""
  fi
done

if [ "$NB" = 0 ]; then
  echo "PLAN EMPTY"
  exit 0
fi
i=1
while [ "$i" -le "$NB" ]; do
  eval "members=\"\$BATCH_${i}\""
  echo "PLAN BATCH ${i} $(printf '%s' "$members" | sed 's/^ *//')"
  i=$((i + 1))
done
say ""
say "下一步：一次只开一批（第 1 批），主题用小写英文短横线，例如"
say "  just batch-open <主题> $(eval "printf '%s' \"\$BATCH_1\"")"
