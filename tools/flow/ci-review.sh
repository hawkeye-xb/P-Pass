#!/usr/bin/env bash
# CI 上的独立评审（.github/workflows/ci-review.yml 调用）：ci-review.sh <PR号>
#
# 复用 review.sh。结论写成提交状态 review/agent，它是 main 的必需检查（#1435），即合入门禁：
#   - 起跑先在头提交上写 pending，结论出来再改成 success / failure / error；
#   - PPASS_REVIEW_NO_MERGE=1：CI 不开、不撤销自动合入（自动合入由开 PR 的会话开，靠必需检查把关；
#     用 GITHUB_TOKEN 开的自动合入不会触发 main 上的 push 流水线）；
#   - 本脚本永远退出 0，结论只看状态和 PR 评论；
#   - 评审 agent 经本脚本自己的「垫片」调用 claude：非 0 退出、超时、没有 VERDICT 行都算
#     基础设施失败（key、网络、超时），自动重试一次，仍失败就写状态 error + 评论「评审没跑成」，
#     error 不算通过、挡合入，但不当作代码有问题；agent 给出了 VERDICT: FAIL 才是「评审不通过」（状态 failure，review.sh 写）。
#   - 垫片只给 claude 评审要用的环境：去掉 GH_TOKEN / GITHUB_TOKEN（agent 不需要写 GitHub），
#     加 --setting-sources user --strict-mcp-config（不读 PR 检出里的 .claude/ 配置、hooks、MCP，
#     防止被评审的 PR 借 hooks 在 job 里执行命令、伪造结论）。
#
# 环境变量：
#   ANTHROPIC_AUTH_TOKEN / ANTHROPIC_BASE_URL / PPASS_REVIEW_MODEL  交给 claude 与 review.sh
#   PPASS_CI_CLAUDE        真正的评审命令（默认 claude；测试用桩）
#   PPASS_CI_TIMEOUT       单次 agent 调用的超时秒数（默认 600；系统没有 timeout 命令则不限）
#   PPASS_CI_RETRY_SLEEP   重试前等几秒（默认 10）
#   GH_TOKEN               gh 用的令牌（workflow 里是 github.token）

set -uo pipefail

FLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 垫片模式：被 review.sh 当评审 agent 调用，stdin 是提示词，参数是 claude 的参数 ──
if [ "${PPASS_CI_SHIM:-}" = "1" ]; then
  STATE="${PPASS_CI_STATE:?}"
  CLAUDE="${PPASS_CI_CLAUDE:-claude}"
  LIMIT="${PPASS_CI_TIMEOUT:-600}"
  cat >"${STATE}/prompt"
  reason=""
  for attempt in 1 2; do
    run=(env -u GH_TOKEN -u GITHUB_TOKEN "$CLAUDE" "$@" --setting-sources user --strict-mcp-config)
    if command -v timeout >/dev/null 2>&1; then run=(timeout "$LIMIT" "${run[@]}"); fi
    rc=0
    "${run[@]}" <"${STATE}/prompt" >"${STATE}/out" 2>"${STATE}/err" || rc=$?
    last="$(grep -v '^[[:space:]]*$' "${STATE}/out" 2>/dev/null | tail -n 1 | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ "$rc" -eq 0 ] && { [ "$last" = "VERDICT: PASS" ] || [ "$last" = "VERDICT: FAIL" ]; }; then
      printf 'ci-review: agent 返回 %s（第 %s 次）\n' "$last" "$attempt" >"${STATE}/verdict"
      cat "${STATE}/out"
      exit 0
    fi
    if [ "$rc" -ne 0 ]; then
      reason="评审 agent 退出码 ${rc}（超时为 124）：$(head -c 300 "${STATE}/err" | tr '\n' ' ')"
    else
      reason="评审 agent 输出里没有 VERDICT 行"
    fi
    echo "ci-review: 第 ${attempt} 次失败：${reason}" >&2
    [ "$attempt" -eq 2 ] || sleep "${PPASS_CI_RETRY_SLEEP:-10}"
  done
  printf '%s\n' "$reason" >"${STATE}/infra"
  echo "$reason" >&2
  exit 1
fi

# ── 主流程 ───────────────────────────────────────────────────────────
PR="${1:-}"
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "用法：ci-review.sh <PR号>" >&2; exit 2; }
# shellcheck source=worker-lib.sh
. "${FLOW_DIR}/worker-lib.sh"
REPO="$(flow_repo)"

STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
export PPASS_CI_STATE="$STATE"

SHA="$(gh pr view "$PR" -R "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null | tr -d '\r')"

list_fail_comments() {
  gh api "repos/${REPO}/issues/${PR}/comments" --paginate \
    --jq ".[] | select(.body | startswith(\"**独立评审：未通过**（头提交 \`${SHA:0:10}\`\")) | .id" 2>/dev/null
}

# 评审没跑成：状态 error + 评论，不是代码问题。
infra_report() {
  local why="$1"
  echo "ci-review: 评审没跑成：${why}" >&2
  if [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
    gh api -X POST "repos/${REPO}/statuses/${SHA}" -f state=error -f context="review/agent" \
      -f description="评审没跑成（基础设施问题，不是代码问题）" >/dev/null 2>&1 ||
      echo "ci-review: 写状态 error 失败" >&2
  fi
  # review.sh 把 agent 失败当「未通过」贴过一条评论，和这里的结论矛盾，删掉它
  # 只删本次运行贴的（跑之前就存在的是同一提交上更早的真实评审结论，要留着）
  # 跑之前的快照没取全就不删：宁可多留一条矛盾评论，也不误删真实结论
  if [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] && [ "${BEFORE_OK:-0}" = 1 ]; then
    for cid in $(list_fail_comments || true); do
      grep -qx "$cid" "${STATE}/before" 2>/dev/null && continue
      gh api -X DELETE "repos/${REPO}/issues/comments/${cid}" >/dev/null 2>&1 || true
    done
  fi
  printf '**独立评审：评审没跑成**（头提交 `%s`）\n\n基础设施问题（key、网络、超时或脚本异常），**不是代码有问题**（评审 agent 失败时已自动重试一次）。review/agent=error 不算通过，合入会被挡住：在 Actions 里重跑这次评审即可。\n\n原因：%s\n' \
    "${SHA:0:10}" "$why" >"${STATE}/infra.md"
  gh pr comment "$PR" -R "$REPO" --body-file "${STATE}/infra.md" >/dev/null 2>&1 ||
    echo "ci-review: 贴评论失败" >&2
}

# 起跑先写 pending：结论没出来之前，这个头提交上的必需检查不是空着而是「等待中」。
if [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  gh api -X POST "repos/${REPO}/statuses/${SHA}" -f state=pending -f context="review/agent" \
    -f description="独立评审进行中" >/dev/null 2>&1 || echo "ci-review: 写状态 pending 失败" >&2
fi

BEFORE_OK=0
if list_fail_comments >"${STATE}/before"; then BEFORE_OK=1; fi

if [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  infra_report "没有拿到评审用的 key（Secret PPASS_REVIEW_API_KEY 为空；fork 与 Dependabot 的 PR 拿不到 Secret）"
  exit 0
fi

export PPASS_REVIEW_NO_MERGE=1
export PPASS_CI_SHIM=1
export PPASS_REVIEW_AGENT="${FLOW_DIR}/ci-review.sh"
RC=0
bash "${FLOW_DIR}/review.sh" "$PR" >"${STATE}/review.log" 2>&1 || RC=$?
cat "${STATE}/review.log"

# agent 的 stderr 被 review.sh 截走了，这里把垫片记下的结论打进 job 日志（E3 证据）
[ ! -s "${STATE}/verdict" ] || cat "${STATE}/verdict"
if [ -s "${STATE}/infra" ]; then
  infra_report "$(cat "${STATE}/infra")"
elif [ "$RC" -ne 0 ] && ! grep -q 'review/agent=' "${STATE}/review.log"; then
  # review.sh 没走到「写完状态」就退了：agent 之前（读不到 PR、没有 closes #N）或之后（贴评论、写状态的 gh 调用失败）
  infra_report "review.sh 没写出评审状态就退出了（退出码 ${RC}）：$(tail -n 3 "${STATE}/review.log" | tr '\n' ' ')"
fi
exit 0
