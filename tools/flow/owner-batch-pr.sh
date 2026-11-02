#!/usr/bin/env bash
# just batch-pr：推批次分支、开 PR、等全部检查出结论；全绿 squash 合入，红了写 PR 评论并停下。
# 说明见 docs/runbook/owner.md。
#
# 前置判定（不满足就拒绝或停下，绝不跳过）：
#   - batch-verify 已通过，且通过时的提交 = 当前 HEAD（验证后加过提交必须重跑 batch-verify）
#   - HEAD 包含最新 origin/main（main 前进了 ⇒ 重开批次）
#   - 每张卡仍是 status:batched，卡分支没有在合批之后再变
#   - 批次改到的每个核心文件都来自一张带 core 标签、引用「已采纳」ADR 的卡；
#     满足时脚本代 owner 批准 core review（环境审批），否则停下
# 推送：远端已有同名分支且内容不同、或本机私有 pre-push 把 main 上 GitHub 提交的 squash
# （committer GitHub <noreply@github.com>）误判为身份不在白名单 ⇒ 换新分支名（-r2、-r3）重推。
# 不用 --no-verify；其它推送失败一律停下。
# 等检查：gh pr checks --watch（全部检查，不只必需检查），总时长上限 PPASS_OWNER_CHECK_TIMEOUT 秒（默认 10800）。
# 合入：gh pr merge --squash --match-head-commit <已验证提交>。

set -uo pipefail
# shellcheck source=tools/flow/owner-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/owner-lib.sh"

case "${1:-}" in "") ;; *) sed -n 2,17p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;; esac
GRACE="${PPASS_OWNER_CHECK_GRACE:-60}"
RUN_WAIT="${PPASS_OWNER_RUN_WAIT:-600}"  # 等 core review 进入待批状态的上限（秒）
CHECK_TIMEOUT="${PPASS_OWNER_CHECK_TIMEOUT:-10800}"

require_batch
need_gh
fetch_origin
SHA="$(git rev-parse HEAD)"
[ "$(state_get "$BATCH" VERIFIED_SHA)" = "$SHA" ] ||
  refuse "当前 HEAD ${SHA:0:12} 没有通过 batch-verify（或验证后又加了提交）" "先跑 just batch-verify。"
git merge-base --is-ancestor origin/main HEAD ||
  refuse "origin/main 在开批次之后前进了，本批次已过时" \
    "按同样的卡重开一批（新主题名）：just batch-open <新主题> $(state_get "$BATCH" ISSUES)"
REPORT="$(state_get "$BATCH" REPORT)"
[ -f "$REPORT" ] || refuse "找不到批次报告 ${REPORT}" "重跑 just batch-verify。"
BASE="$(state_get "$BATCH" BASE)"
ISSUES="$(state_get "$BATCH" ISSUES)"
DIR="$(batch_dir "$BATCH")"

step "核对卡状态与卡分支"
CARD_FILES_ALL=""
CORE_CARD_FILES=""
CORE_ADRS=""
TITLES=""
for n in $ISSUES; do
  rec="$(state_get "$BATCH" "CARD_${n}")"
  br="${rec%@*}"
  sha="${rec#*@}"
  load_issue "$n" || die_stuck "batch-pr：${CARD_ERR}"
  has_label status:batched || die_stuck "#${n} 已不是 status:batched（标签：${ISSUE_LABELS}），批次内容与看板不一致" --issue "$n"
  now="$(git rev-parse -q --verify "origin/${br}" 2>/dev/null || echo gone)"
  if [ "$now" != "$sha" ] && [ "$now" != gone ]; then
    die_stuck "#${n} 的卡分支 ${br} 在合批之后又变了（${sha:0:10} → ${now:0:10}），批次里的不是最新交付" --issue "$n"
  fi
  files="$(git -c core.quotepath=false diff --name-only --no-renames "${BASE}...${sha}")"
  CARD_FILES_ALL="${CARD_FILES_ALL}${files}
"
  if has_label core; then
    adrs="$(adopted_adrs "$ISSUE_BODY")"
    if [ -n "$adrs" ]; then
      CORE_CARD_FILES="${CORE_CARD_FILES}${files}
"
      CORE_ADRS="${CORE_ADRS}${adrs}
"
    fi
  fi
  TITLES="${TITLES}${TITLES:+；}${ISSUE_TITLE}"
  eval "T_${n}=\"\$ISSUE_TITLE\""
  eval "B_${n}=\"\$br\""
  eval "S_${n}=\"\$sha\""
done
CORE_ADRS="$(printf '%s' "$CORE_ADRS" | sed '/^$/d' | sort -u)"

step "核心判定"
BATCH_FILES="$(git -c core.quotepath=false diff --name-only --no-renames "${BASE}...HEAD")"
BATCH_CORE=false
UNATTRIB=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  c="$(printf '%s\n' "$f" | bash "${REPO_ROOT}/tools/ci-paths.sh" core - "${REPO_ROOT}/.github/core-paths.txt" 2>/dev/null)"
  [ "$c" = false ] && continue
  BATCH_CORE=true
  printf '%s\n' "$CORE_CARD_FILES" | grep -Fxq "$f" || UNATTRIB="${UNATTRIB} ${f}"
done <<EOF
$BATCH_FILES
EOF
[ -z "$UNATTRIB" ] ||
  die_stuck "批次 ${BATCH} 改到核心文件，但它们不来自任何「带 core 标签且引用已采纳 ADR」的卡：${UNATTRIB# }。core review 不能批"
CARD_SHAS="$(for n in $ISSUES; do eval "printf '%s ' \"\$S_${n}\""; done)"
# shellcheck disable=SC2086
EXTRA="$(git log --no-merges --format='%h %s' "${BASE}..HEAD" --not $CARD_SHAS)"
# 不属于任何卡的提交（owner 在批次分支上的修补）碰了核心 ⇒ 没有定案可依，core review 不能代批。
# shellcheck disable=SC2086
EXTRA_CORE="$(git log --no-merges --format= --name-only --no-renames "${BASE}..HEAD" --not $CARD_SHAS |
  sed '/^$/d' | sort -u | bash "${REPO_ROOT}/tools/ci-paths.sh" core - "${REPO_ROOT}/.github/core-paths.txt" 2>/dev/null)"
if [ -n "$EXTRA" ] && [ "$EXTRA_CORE" != false ]; then
  die_stuck "批次 ${BATCH} 上有不属于任何卡的提交改了核心文件，没有定案可依，core review 不能批：$(printf '%s' "$EXTRA" | tr '\n' ';')"
fi
if [ "$BATCH_CORE" = true ]; then
  okmsg "批次碰了核心，定案：$(printf '%s' "$CORE_ADRS" | tr '\n' ' ')"
else
  okmsg "批次没碰核心"
fi

# ── 推送 ───────────────────────────────────────────────────────────
push_as() { # push_as <远端分支名>：0 成功 / 1 换名重推 / 2 其它失败
  local name="$1" out remote
  remote="$(git ls-remote origin "refs/heads/${name}" 2>/dev/null | cut -f1)"
  [ "$remote" = "$SHA" ] && return 0
  [ -z "$remote" ] || { say "远端已有 ${name} 且内容不同，不覆盖，换名"; return 1; }
  out="$(git push origin "HEAD:refs/heads/${name}" 2>&1)" && { printf '%s\n' "$out" >&2; return 0; }
  printf '%s\n' "$out" >"${DIR}/push-${name##*/}.log"
  printf '%s\n' "$out" >&2
  # 只认这一种误判：被拦的身份全部是 GitHub 的 squash 提交身份。
  local blocked others
  blocked="$(printf '%s\n' "$out" | grep -c '不在白名单内' || true)"
  others="$(printf '%s\n' "$out" | grep '不在白名单内' | grep -vc 'GitHub <noreply@github.com>' || true)"
  if [ "$blocked" -gt 0 ] && [ "$others" -eq 0 ]; then
    say "本机 pre-push 把 GitHub 的 squash 提交误判为身份不在白名单 → 换新分支名重推（不用 --no-verify）"
    return 1
  fi
  return 2
}
step "推送"
PUSHED="$(state_get "$BATCH" PUSHED_AS)"
if [ -z "$PUSHED" ]; then
  for name in "$BATCH" "${BATCH}-r2" "${BATCH}-r3"; do
    push_as "$name"
    case $? in
      0) PUSHED="$name"; break ;;
      1) continue ;;
      *) die_stuck "推送批次分支 ${name} 失败（见日志）" --log "${DIR}/push-${name##*/}.log" ;;
    esac
  done
  [ -n "$PUSHED" ] || die_stuck "换了 3 个分支名都推不上去" --log "${DIR}/push-${BATCH##*/}-r3.log"
  state_set "$BATCH" PUSHED_AS "$PUSHED"
else
  push_as "$PUSHED" || die_stuck "批次曾推送为 ${PUSHED}，现在再推失败或远端已被改动"
fi
okmsg "已推送为 ${PUSHED}"

# ── PR ─────────────────────────────────────────────────────────────
PR="$(state_get "$BATCH" PR)"
if [ -z "$PR" ]; then
  PR="$(gh pr list -R "$REPO" --head "$PUSHED" --state open --json number --jq '.[0].number // empty' 2>/dev/null)"
fi
if [ -z "$PR" ]; then
  step "开 PR"
  topic="$(state_get "$BATCH" TOPIC)"
  d="$(printf '%s' "$BATCH" | sed -E 's#^batch/[0-9]{4}-([0-9]{2})-([0-9]{2})-.*#\1-\2#')"
  title="batch(${d} ${topic}): ${TITLES}"
  [ "${#title}" -le 120 ] || title="$(printf '%s' "$title" | cut -c1-117)..."
  body="${DIR}/pr-body.md"
  {
    printf '## 卡\n\n'
    for n in $ISSUES; do
      eval "printf -- '- closes #%s %s（\`%s\` @ \`%s\`）\n' \"\$n\" \"\$T_${n}\" \"\$B_${n}\" \"\$(printf '%.10s' \"\$S_${n}\")\""
    done
    if [ -n "$EXTRA" ]; then
      printf '\n批次分支上的额外提交（不属于任何卡）：\n\n'
      printf '%s\n' "$EXTRA" | sed 's/^/- /'
    fi
    printf '\n## 核心\n\n'
    if [ "$BATCH_CORE" = true ]; then
      printf '碰了核心，定案：\n\n'
      printf '%s\n' "$CORE_ADRS" | sed 's/^/- /'
    else
      printf '没碰核心（tools/ci-paths.sh core = false）。\n'
    fi
    printf '\n## 验证证据（batch-verify，提交 `%s`）\n\n' "${SHA:0:12}"
    sed -n '/^| 步骤 /,/^BATCH-VERIFY /p' "$REPORT" | sed '/^## 未覆盖项/,$d' | sed 's#| /[^|]*/\([^/|]*\) |#| \1 |#'
    printf '\n## 未覆盖项\n\n'
    sed -n '/^## 未覆盖项/,/^BATCH-VERIFY /p' "$REPORT" | sed -e '1d' -e '/^BATCH-VERIFY /d' -e '/^$/d'
    printf '\n%s\n' "$(grep '^BATCH-VERIFY ' "$REPORT" | tail -1)"
  } >"$body"
  url="$(gh pr create -R "$REPO" --base main --head "$PUSHED" --title "$title" --body-file "$body" 2>&1)" ||
    die_stuck "gh pr create 失败：$(printf '%s' "$url" | tail -1)"
  PR="$(printf '%s' "$url" | grep -oE '[0-9]+$' | tail -1)"
  [ -n "$PR" ] || die_stuck "gh pr create 没返回 PR 号：${url}"
fi
state_set "$BATCH" PR "$PR"
okmsg "PR #${PR}"

# ── core review（环境审批）──────────────────────────────────────────
approve_core() {
  local waited=0 run envs out
  while [ "$waited" -le "$RUN_WAIT" ]; do
    run="$(gh api "repos/${REPO}/actions/workflows/ci-core-review.yml/runs?event=pull_request_target&per_page=30" \
      --jq "[.workflow_runs[] | select(((.pull_requests // []) | map(.number) | index(${PR})) or (.head_branch == \"${PUSHED}\"))][0] | \"\(.id) \(.status)\"" 2>/dev/null)"
    case "$run" in
      *" waiting") break ;;
      *" completed") okmsg "core review 已结束，不需要批"; return 0 ;;
    esac
    sleep 10
    waited=$((waited + 10))
  done
  case "$run" in *" waiting") ;; *) die_stuck "${RUN_WAIT}s 内没等到 PR #${PR} 的 core review 进入待批状态，判定不了" --pr "$PR" ;; esac
  run="${run%% *}"
  envs="$(gh api "repos/${REPO}/actions/runs/${run}/pending_deployments" --jq '.[].environment.id' 2>&1)" ||
    die_stuck "读 core review 待批环境失败：$(printf '%s' "$envs" | head -1)" --pr "$PR"
  [ -n "$envs" ] || die_stuck "core review run ${run} 没有待批环境，判定不了" --pr "$PR"
  local args=() e
  for e in $envs; do args+=(-F "environment_ids[]=${e}"); done
  out="$(gh api -X POST "repos/${REPO}/actions/runs/${run}/pending_deployments" "${args[@]}" \
    -f state=approved -f comment="owner 批准：核心改动已定案（$(printf '%s' "$CORE_ADRS" | tr '\n' ' ')）" 2>&1)" ||
    die_stuck "批准 core review 失败（权限？）：$(printf '%s' "$out" | head -2 | tr '\n' ' ')" --pr "$PR"
  okmsg "已批准 core review（run ${run}）"
}
[ "$BATCH_CORE" = false ] || approve_core

# ── 等全部检查 ───────────────────────────────────────────────────────
checks_json() { gh pr checks "$PR" -R "$REPO" --json name,bucket,link,workflow 2>/dev/null; }
count_bucket() { printf '%s' "$1" | python3 -c "import json,sys; print(sum(1 for c in json.load(sys.stdin) if c['bucket'] in sys.argv[1].split(',')))" "$2"; }

step "等全部检查出结论（PR #${PR}，上限 ${CHECK_TIMEOUT}s）"
sleep "$GRACE"
start=$(date +%s)
J=""
while :; do
  left=$((CHECK_TIMEOUT - ($(date +%s) - start)))
  [ "$left" -gt 0 ] || die_stuck "PR #${PR} 的检查 ${CHECK_TIMEOUT}s 内没出结论" --pr "$PR"
  bash "${REPO_ROOT}/tools/release/with-timeout.sh" "gh pr checks --watch" "$left" 1 -- \
    gh pr checks "$PR" -R "$REPO" --watch --interval 30 >"${DIR}/checks-watch.log" 2>&1
  J="$(checks_json)"
  [ -n "$J" ] && [ "$J" != "[]" ] || die_stuck "PR #${PR} 等了 ${GRACE}s 仍没有任何检查，判定不了" --pr "$PR"
  [ "$(count_bucket "$J" pending)" -eq 0 ] || { sleep 30; continue; }
  # 晚注册的 workflow：再等一轮宽限，确认没有新检查冒出来。
  sleep "$GRACE"
  J2="$(checks_json)"
  [ "$(count_bucket "$J2" pending)" -eq 0 ] && { J="$J2"; break; }
done

bad="$(count_bucket "$J" fail,cancel)"
if [ "$bad" -gt 0 ]; then
  step "检查红了 ${bad} 项：取失败日志，写 PR 评论，停下"
  slice="${DIR}/failed-checks.log"
  : >"$slice"
  printf '%s' "$J" | python3 -c '
import json, sys
for c in json.load(sys.stdin):
    if c["bucket"] in ("fail", "cancel"):
        print("%s\t%s\t%s" % (c["name"], c["bucket"], c.get("link", "")))
' | while IFS="$(printf '\t')" read -r name bucket link; do
    printf '### %s（%s）\n%s\n' "$name" "$bucket" "$link" >>"$slice"
    run="$(printf '%s' "$link" | sed -nE 's#.*/actions/runs/([0-9]+)/job/([0-9]+).*#\1 \2#p')"
    if [ -n "$run" ]; then
      gh run view "${run% *}" -R "$REPO" --job "${run#* }" --log-failed 2>&1 | tail -n 40 >>"$slice"
    fi
    printf '\n' >>"$slice"
  done
  die_stuck "PR #${PR} 有 ${bad} 项检查红，没有合入。在批次分支上修好后重跑 just batch-verify 与 just batch-pr" --pr "$PR" --log "$slice"
fi
okmsg "全部检查通过"

# ── 合入 ───────────────────────────────────────────────────────────
# mergeStateStatus 刚出结论时常是 UNKNOWN（GitHub 还在算），短暂重试。
for _ in 1 2 3 4 5 6; do
  info="$(gh pr view "$PR" -R "$REPO" --json headRefOid,mergeStateStatus --jq '"\(.headRefOid) \(.mergeStateStatus)"' 2>&1)" ||
    die_stuck "读 PR #${PR} 状态失败" --pr "$PR"
  [ "${info#* }" = UNKNOWN ] || break
  sleep 10
done
[ "${info%% *}" = "$SHA" ] || die_stuck "PR #${PR} 的 head 是 ${info%% *}，不是已验证的 ${SHA}，不合入" --pr "$PR"
case "${info#* }" in
  BEHIND) die_stuck "PR #${PR} 落后 main（合批期间 main 有新提交），不合入；按同样的卡重开一批再验证" --pr "$PR" ;;
  BLOCKED | DIRTY | UNKNOWN) die_stuck "PR #${PR} 的合并状态是 ${info#* }，判定不了能否合入" --pr "$PR" ;;
esac
step "squash 合入 PR #${PR}"
out="$(gh pr merge "$PR" -R "$REPO" --squash --match-head-commit "$SHA" 2>&1)" ||
  die_stuck "gh pr merge 失败：$(printf '%s' "$out" | tail -2 | tr '\n' ' ')" --pr "$PR"
state="$(gh pr view "$PR" -R "$REPO" --json state --jq .state 2>/dev/null)"
[ "$state" = MERGED ] || die_stuck "gh pr merge 返回成功，但 PR #${PR} 状态是 ${state:-未知}" --pr "$PR"
state_set "$BATCH" MERGED "$SHA"
for n in $ISSUES; do
  s="$(gh issue view "$n" -R "$REPO" --json state --jq .state 2>/dev/null)"
  [ "$s" = CLOSED ] || say "⚠ #${n} 没有被 closes 自动关闭（状态 ${s:-未知}），手动核对"
done
printf '\nBATCH-PR MERGED #%s %s\n' "$PR" "$SHA"
say "下一步：要出 test 包时 git -C <主仓> fetch 后 just release-test <端...>；清理 just cleanup-local"
