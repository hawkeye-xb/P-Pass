#!/usr/bin/env bash
# just review <PR号> [--model <模型>]：合入前由一个没参与写代码的 agent 只读评审这个 PR。
#
#   取 PR 头提交的改动 + 正文里 closes #N 的卡的「范围」「验收场景」
#   → 在 PR 头提交的临时只读检出里起一个新 agent（只给 Read / Grep / Glob，不能改文件、不能跑命令）
#   → 结果写成 PR 评论（「通过」或「未通过 + 问题清单」），并在 PR 头提交上写提交状态 review/agent
#
# 评审通过后对所有级别的 PR 执行 gh pr merge --auto --squash（CI 全绿即合）。盯梢、人控级（改动碰界面文案路径
# 或核心路径）多一个条件：PR 正文里必须有「产品负责人 <时间> 真机验收通过」这一行，没有就判未通过、
# 不开自动合入，评论里写明缺这一行（验收即放行，验收发生在开 PR 之前，AGENTS.md「角色」）。
#
# 判定从 agent 输出最后一行的 VERDICT 解析：不是 PASS 就是失败（agent 挂了、没给 VERDICT、
# 评审期间改动了检出，一律按失败，宁可误拦不放过）。
#
# 环境变量：
#   PPASS_REVIEW_AGENT  评审 agent 的命令（默认 claude；其它模型只要接受同样的 -p / --model /
#                       --allowedTools 参数，prompt 走 stdin，即可替换；测试用假 agent）
#   PPASS_REVIEW_MODEL  默认模型（--model 优先）
#   PPASS_REVIEW_MAX_DIFF  diff 超过这个字节数就截断并写明（默认 300000）
#   PPASS_REVIEW_NO_MERGE  设为 1：评审通过不开自动合入，未通过也不撤销（CI 试跑期只提示用，tools/flow/ci-review.sh）

set -euo pipefail

FLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=worker-lib.sh
. "${FLOW_DIR}/worker-lib.sh"

PR=""
MODEL="${PPASS_REVIEW_MODEL:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --model)
      [ $# -ge 2 ] || die "--model 后面要跟模型名"
      MODEL="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '2,15p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    -*) die "不认识的参数：$1" "用法：just review <PR号> [--model <模型>]" ;;
    *)
      [ -z "$PR" ] || die "只能评审一个 PR" "用法：just review <PR号> [--model <模型>]"
      PR="$1"
      shift
      ;;
  esac
done
[[ "$PR" =~ ^[0-9]+$ ]] || die "要给 PR 号（数字）" "用法：just review <PR号> [--model <模型>]"

REPO="$(flow_repo)"
AGENT="${PPASS_REVIEW_AGENT:-claude}"
MAX_DIFF="${PPASS_REVIEW_MAX_DIFF:-300000}"

TOP="$(git rev-parse --show-toplevel)"
WORK="$(mktemp -d)"
WT="${WORK}/checkout"
cleanup() {
  git -C "$TOP" worktree remove --force "$WT" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── 1. PR 的头提交、标题、正文 ────────────────────────────────────────
PR_OUT="$(gh pr view "$PR" -R "$REPO" --json state,headRefOid,title,body \
  --jq '"state:" + .state, "sha:" + .headRefOid, "title:" + .title, "body:", .body' 2>&1)" ||
  die "读取 ${REPO}#${PR} 失败（离线、没登录或 PR 不存在）" "gh 输出：$(printf '%s' "$PR_OUT" | head -3 | tr '\n' ' ')"
PR_OUT="$(printf '%s\n' "$PR_OUT" | tr -d '\r')"
PR_STATE="$(printf '%s\n' "$PR_OUT" | sed -n '1s/^state://p')"
SHA="$(printf '%s\n' "$PR_OUT" | sed -n '2s/^sha://p')"
PR_TITLE="$(printf '%s\n' "$PR_OUT" | sed -n '3s/^title://p')"
PR_BODY="$(printf '%s\n' "$PR_OUT" | sed '1,4d')"
[ "$PR_STATE" = "OPEN" ] || die "#${PR} 不是 open 状态（${PR_STATE}），不评审"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "读不到 #${PR} 的头提交"

# ── 2. 关联卡：正文里的 closes / fixes / resolves #N ─────────────────
CARDS="$(printf '%s\n' "$PR_BODY" | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) +#[0-9]+' | grep -oE '[0-9]+' | sort -un || true)"
[ -n "$CARDS" ] || die "#${PR} 正文里没有 closes #N，评审不知道对照哪张卡" "在 PR 正文补上 closes #N 再评审。"

CARD_TEXT=""
for n in $CARDS; do
  flow_load_issue "$n"
  flow_parse_scope "$I_BODY"
  accept="$(printf '%s\n' "$I_BODY" | awk '/^\*\*验收场景\*\*|^## .*验收/ { on = 1 } on { print }')"
  CARD_TEXT="${CARD_TEXT}
### 卡 #${n}：${I_TITLE}

范围（只许动这些）：
$(printf '  %s\n' "${GLOBS[@]+"${GLOBS[@]}"}")

验收场景：
${accept:-（卡上没找到验收场景）}
"
done

# ── 2b. 级别：碰核心路径或界面文案路径 = 盯梢 / 人控，合入要有真机验收记录 ──
gh pr diff "$PR" -R "$REPO" --name-only >"${WORK}/pr.files" 2>/dev/null ||
  die "读取 #${PR} 的改动文件清单失败"
NEEDS_ACCEPT=""
CORE_RULES="${WORK}/core-paths.txt"
git -C "$TOP" show origin/main:.github/core-paths.txt >"$CORE_RULES" 2>/dev/null || : >"$CORE_RULES"
if [ "$(bash "${TOP}/tools/ci-paths.sh" core - "$CORE_RULES" <"${WORK}/pr.files" 2>/dev/null)" != "false" ]; then
  NEEDS_ACCEPT="碰核心路径（人控级）"
fi
# 界面与文案路径的清单与 owner-triage.sh 共用同一份；读不到就按需要验收处理（宁严勿松）。
UI_GLOBS="$(sed -n 's/^UI_GLOBS="\(.*\)"$/\1/p' "${FLOW_DIR}/owner-triage.sh" 2>/dev/null)"
if [ -z "$UI_GLOBS" ]; then
  NEEDS_ACCEPT="${NEEDS_ACCEPT:-读不到界面路径清单，按盯梢级处理}"
else
  # shellcheck disable=SC2086 # 清单里是空格分隔的 glob，刻意拆开
  set -f
  [ "$(bash "${TOP}/tools/ci-paths.sh" hit - $UI_GLOBS <"${WORK}/pr.files" 2>/dev/null)" != "false" ] &&
    NEEDS_ACCEPT="${NEEDS_ACCEPT:-碰界面或文案路径（盯梢级）}"
  set +f
fi

# ── 3. 改动 diff ─────────────────────────────────────────────────────
gh pr diff "$PR" -R "$REPO" >"${WORK}/pr.diff" 2>"${WORK}/diff.err" ||
  die "读取 #${PR} 的 diff 失败" "$(head -3 "${WORK}/diff.err" | tr '\n' ' ')"
DIFF_NOTE=""
if [ "$(wc -c <"${WORK}/pr.diff")" -gt "$MAX_DIFF" ]; then
  head -c "$MAX_DIFF" "${WORK}/pr.diff" >"${WORK}/pr.diff.cut"
  mv "${WORK}/pr.diff.cut" "${WORK}/pr.diff"
  DIFF_NOTE="（diff 超过 ${MAX_DIFF} 字节，已截断；其余改动请自己到检出里读文件核对）"
fi

# ── 4. PR 头提交的临时检出（agent 的工作目录，只读用）─────────────────
git -C "$TOP" fetch -q origin "refs/pull/${PR}/head" || die "取不到 refs/pull/${PR}/head"
[ "$(git -C "$TOP" rev-parse FETCH_HEAD)" = "$SHA" ] ||
  die "PR 头提交在评审途中变了（${SHA} → $(git -C "$TOP" rev-parse FETCH_HEAD)）" "重跑 just review ${PR}。"
git -C "$TOP" worktree add -q --detach "$WT" "$SHA" || die "建临时检出失败"

# ── 5. 起 agent：只读工具；提示词走 stdin ─────────────────────────────
{
  cat "${FLOW_DIR}/review-prompt.md"
  printf '\n## PR #%s：%s\n\n关联卡：\n%s\n\n## 改动 diff%s\n\n```diff\n' "$PR" "$PR_TITLE" "$CARD_TEXT" "$DIFF_NOTE"
  cat "${WORK}/pr.diff"
  printf '\n```\n'
} >"${WORK}/prompt.txt"

# 读文件和搜索之外，一概不给；--disallowedTools 再兜一层，防配置里默认放开。
AGENT_ARGS=(-p --no-session-persistence
  --allowedTools "Read Grep Glob"
  --disallowedTools "Bash Edit Write NotebookEdit WebFetch WebSearch Agent")
[ -z "$MODEL" ] || AGENT_ARGS+=(--model "$MODEL")

echo "==> 评审 ${REPO}#${PR}（${SHA:0:10}）：${AGENT}${MODEL:+ --model ${MODEL}}"
AGENT_RC=0
(cd "$WT" && "$AGENT" "${AGENT_ARGS[@]}" <"${WORK}/prompt.txt" >"${WORK}/agent.out" 2>"${WORK}/agent.err") || AGENT_RC=$?

# ── 6. 判定 ──────────────────────────────────────────────────────────
VERDICT="FAIL"
REASON=""
if [ "$AGENT_RC" -ne 0 ]; then
  REASON="评审 agent 退出码 ${AGENT_RC}，没有产出可用结论。$(head -c 400 "${WORK}/agent.err" | tr '\n' ' ')"
else
  LAST="$(grep -v '^[[:space:]]*$' "${WORK}/agent.out" | tail -n 1 | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$LAST" in
    "VERDICT: PASS") VERDICT="PASS" ;;
    "VERDICT: FAIL") ;;
    *) REASON="评审输出最后一行不是 VERDICT: PASS / VERDICT: FAIL，按未通过处理。" ;;
  esac
fi
# 盯梢、人控级：PR 正文必须有验收记录；没有就算未通过（即使 agent 说 PASS）。
if [ "$VERDICT" = "PASS" ] && [ -n "$NEEDS_ACCEPT" ] &&
  ! printf '%s\n' "$PR_BODY" | grep -qE '^[*_> -]*产品负责人 ([0-9]{4}-)?[0-9]{2}-[0-9]{2}( +[0-9]{1,2}:[0-9]{2})? *(本地)?真机验收通过([*_ ]*|\*\*.*)$'; then
  VERDICT="FAIL"
  REASON="${NEEDS_ACCEPT}，PR 正文缺「产品负责人 <时间> 真机验收通过」这一行（须单独成行、以「产品负责人」开头、时间处是具体日期如 2026-11-04）：没有验收记录不开自动合入。验收通过后在 PR 正文补上这一行，再重跑 just review。"
fi
# 评审期间检出被改动 = 只读约束被破坏，评审作废。
if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
  VERDICT="FAIL"
  REASON="评审 agent 改动了只读检出，评审作废。"
fi

BODY_FILE="${WORK}/comment.md"
{
  if [ "$VERDICT" = "PASS" ]; then
    echo "**独立评审：通过**（头提交 \`${SHA:0:10}\`）"
  else
    echo "**独立评审：未通过**（头提交 \`${SHA:0:10}\`）"
  fi
  echo
  [ -z "$REASON" ] || { echo "${REASON}"; echo; }
  # 评审正文：去掉最后的 VERDICT 行，原样贴上
  grep -v '^[[:space:]]*VERDICT:[[:space:]]*\(PASS\|FAIL\)[[:space:]]*$' "${WORK}/agent.out" 2>/dev/null || true
  echo
  echo "<sub>评审人：新开的只读 agent${MODEL:+（${MODEL}）}，只看 PR 改动与关联卡 $(printf '#%s ' $CARDS)；结论只对头提交 \`${SHA:0:10}\` 有效，之后有新提交要重评。</sub>"
} >"$BODY_FILE"

gh pr comment "$PR" -R "$REPO" --body-file "$BODY_FILE" >/dev/null 2>&1 ||
  die "往 #${PR} 贴评审评论失败" "评论内容见 ${BODY_FILE}（脚本退出后会被清掉，先复制）"

if [ "$VERDICT" = "PASS" ]; then STATE=success; DESC="独立评审通过"; else STATE=failure; DESC="独立评审未通过"; fi
gh api -X POST "repos/${REPO}/statuses/${SHA}" -f state="$STATE" -f context="review/agent" \
  -f description="$DESC" >/dev/null 2>&1 ||
  die "写提交状态 review/agent 失败（评论已贴）" "手动：gh api -X POST repos/${REPO}/statuses/${SHA} -f state=${STATE} -f context=review/agent"

if [ "$VERDICT" = "PASS" ]; then
  echo "✅ #${PR} 独立评审通过，review/agent=success（${SHA:0:10}）"
  [ "${PPASS_REVIEW_NO_MERGE:-}" != "1" ] || exit 0
  gh pr merge "$PR" -R "$REPO" --auto --squash >"${WORK}/merge.out" 2>&1 ||
    die "开自动合入失败（评审状态已写）" "$(head -3 "${WORK}/merge.out" | tr '\n' ' ')" "手动：gh pr merge ${PR} -R ${REPO} --auto --squash"
  echo "   已开自动合入（squash）：CI 全绿后自动合入。"
else
  [ "${PPASS_REVIEW_NO_MERGE:-}" != "1" ] || {
    echo "✗ #${PR} 独立评审未通过，review/agent=failure（${SHA:0:10}）；不动自动合入（PPASS_REVIEW_NO_MERGE=1）。" >&2
    exit 1
  }
  # 之前通过时开过自动合入：评审判未通过必须撤销，否则 CI 绿了照样合。没开过时 gh 会报「未启用」，只容忍这一种。
  if ! gh pr merge "$PR" -R "$REPO" --disable-auto >"${WORK}/disable.out" 2>&1 &&
    ! grep -qiE "not enabled|isn't enabled|not.*auto.?merge|auto.?merge.*not" "${WORK}/disable.out"; then
    echo "!! 撤销 #${PR} 的自动合入失败，请手动：gh pr merge ${PR} -R ${REPO} --disable-auto（$(head -3 "${WORK}/disable.out" | tr '\n' ' ')）" >&2
  fi
  echo "✗ #${PR} 独立评审未通过，review/agent=failure（${SHA:0:10}）；问题清单已贴在 PR 评论里。" >&2
  exit 1
fi
