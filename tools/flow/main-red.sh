#!/usr/bin/env bash
# main 上某条 CI 流水线红了 / 转绿时，自动开卡 / 追加评论 / 关卡（#1469）。
#
# 口径（产品负责人 2026-11-06 定）：main 红了不冻结、不挡其他合入；卡里列出「上次全绿 → 这次红」之间的
# PR，owner 二分找元凶：修起来简单就往前修，拿不准就回滚元凶 PR。
#
# 输入（环境变量，由 .github/workflows/main-red.yml 从 workflow_run 事件传入）：
#   REPO        owner/repo
#   RUN_ID      触发的 workflow run 的 id
#   WORKFLOW    workflow 名（卡标题用）
#   CONCLUSION  success / failure / timed_out / cancelled …
#   BRANCH      run 的分支；EVENT 触发事件。只处理 main 上 push 触发的 run，其余直接退出 0。
# 红 = failure / timed_out；cancelled、skipped 等不算红也不算绿，不动卡。
# 卡标题固定「[MAIN-RED] <workflow 名>」，同名已开就追加评论，不重复开。
#
# 退出码：0 正常（含「不用处理」）/ 1 缺输入或 gh 调用失败。

set -euo pipefail

: "${REPO:?缺 REPO}" "${RUN_ID:?缺 RUN_ID}" "${WORKFLOW:?缺 WORKFLOW}" "${CONCLUSION:?缺 CONCLUSION}"
BRANCH="${BRANCH:-}"
EVENT="${EVENT:-}"
RECENT_N="${MAIN_RED_RECENT_N:-20}"
TITLE="[MAIN-RED] ${WORKFLOW}"

if [ "$BRANCH" != "main" ] || [ "$EVENT" != "push" ]; then
  echo "main-red: 跳过（${WORKFLOW} 的 run ${RUN_ID} 不是 main 上 push 触发的：branch=${BRANCH} event=${EVENT}）"
  exit 0
fi

# 同名已开的卡（只看标题精确相等，不用搜索：搜索有索引延迟）
find_open_issue() {
  gh issue list --repo "$REPO" --state open --label P0 --limit 200 --json number,title \
    --jq "[.[] | select(.title == \"${TITLE//\"/\\\"}\")] | .[0].number // empty"
}

existing="$(find_open_issue)"

case "$CONCLUSION" in
  success)
    if [ -z "$existing" ]; then
      echo "main-red: ${WORKFLOW} 绿了，没有开着的卡，无事"
      exit 0
    fi
    run_url="$(gh api "repos/${REPO}/actions/runs/${RUN_ID}" --jq '.html_url')"
    gh issue comment "$existing" --repo "$REPO" \
      --body "main 上 ${WORKFLOW} 已转绿：${run_url}。自动关卡。"
    gh issue close "$existing" --repo "$REPO"
    echo "main-red: 已关 #${existing}"
    exit 0
    ;;
  failure | timed_out) ;;
  *)
    echo "main-red: 跳过（结论 ${CONCLUSION} 既不算红也不算绿）"
    exit 0
    ;;
esac

# ── 红：定区间 ───────────────────────────────────────────────────────
run_json="$(gh api "repos/${REPO}/actions/runs/${RUN_ID}")"
head_sha="$(jq -r '.head_sha' <<<"$run_json")"
run_url="$(jq -r '.html_url' <<<"$run_json")"
created_at="$(jq -r '.created_at' <<<"$run_json")"
workflow_id="$(jq -r '.workflow_id' <<<"$run_json")"

# 该 workflow 在 main 上、早于本次 run 的最近一次 success 的提交
# 查询失败按「读不到上次绿」处理（回退到最近提交），不能因此不开卡
base_sha="$(gh api "repos/${REPO}/actions/workflows/${workflow_id}/runs?branch=main&event=push&status=success&per_page=50" \
  --jq "[.workflow_runs[] | select(.created_at < \"${created_at}\")] | sort_by(.created_at) | last | .head_sha // empty")" || base_sha=""

# 提交行：「短 sha 标题」；PR 号从标题末尾的 (#N)（squash 合入的写法）取
if [ -n "$base_sha" ]; then
  commit_lines="$(gh api "repos/${REPO}/compare/${base_sha}...${head_sha}" \
    --jq '.commits[] | "\(.sha[0:8]) \(.commit.message | split("\n")[0])"')"
  scope_note="区间：上次全绿提交 \`${base_sha:0:8}\`（不含）→ 本次红的提交 \`${head_sha:0:8}\`（含）。"
else
  commit_lines="$(gh api "repos/${REPO}/commits?sha=${head_sha}&per_page=${RECENT_N}" \
    --jq '.[] | "\(.sha[0:8]) \(.commit.message | split("\n")[0])"')"
  scope_note="⚠️ 读不到这条流水线在 main 上更早的全绿记录，**无法确定区间**：下面列的是到本次红的提交为止最近 ${RECENT_N} 个提交，元凶可能更早。"
fi

candidates=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if [[ "$line" =~ \(#([0-9]+)\)[[:space:]]*$ ]]; then
    candidates+="- #${BASH_REMATCH[1]}：${line}"$'\n'
  else
    candidates+="- （无 PR 号）${line}"$'\n'
  fi
done <<<"$commit_lines"
[ -n "$candidates" ] || candidates="- （区间内没有提交：可能是重跑或 force-push，请直接看 run 日志）"$'\n'

failed_jobs="$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" \
  --jq '.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out") | "- [\(.name)](\(.html_url))"')"
[ -n "$failed_jobs" ] || failed_jobs="- （没读到失败 job，看 run 页面）"

body="main 上 **${WORKFLOW}** 红了（${CONCLUSION}）：${run_url}

${scope_note}

### 候选 PR（旧 → 新）
${candidates}
### 失败 job
${failed_jobs}

### 处理口径
- main 不冻结，其他 PR 照常合入。
- owner 在候选里二分找元凶：修起来简单就往前修（开新 PR）；拿不准就回滚元凶 PR（\`gh pr revert <号>\`）。
- 同一条流水线下次在 main 上转绿时，本卡自动评论并关闭。"

if [ -n "$existing" ]; then
  gh issue comment "$existing" --repo "$REPO" --body "又红了：${WORKFLOW}（run ${RUN_ID}）

${body}"
  echo "main-red: 已在 #${existing} 追加评论"
else
  gh issue create --repo "$REPO" --title "$TITLE" --label P0 --body "$body"
  echo "main-red: 已开卡「${TITLE}」"
fi
