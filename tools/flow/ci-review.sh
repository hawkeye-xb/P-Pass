#!/usr/bin/env bash
# CI 上的独立评审（.github/workflows/ci-review.yml 调用），分三步，token 只给需要它的步骤：
#
#   ci-review.sh prepare <PR号>   要 GH_TOKEN：头提交上写 review/agent=pending；review.sh 取 PR、建只读检出、写提示词
#   ci-review.sh agent            不给任何 GitHub token：只跑评审 agent，结论写进状态目录（agent.out / agent.err / agent.rc）
#   ci-review.sh publish <PR号>   要 GH_TOKEN：review.sh 判定、贴评论、写 review/agent（success / failure / error）
#   ci-review.sh <PR号>           三步连着跑（本机自测用；agent 那步同样去掉 GH_TOKEN / GITHUB_TOKEN）
#   ci-review.sh override <PR号> <评论ID>   要 GH_TOKEN：owner 复核放行（#1470），见 do_override
#
# 只评正式 PR（#1470）：草稿 PR 不评（prepare 读到 isDraft=true 就整次跳过，不写状态、不调模型）；
# 转正式（ready_for_review）再评。复用、增量、三级结论在 review.sh 里判（见它的头注释）：
# 复用时 agent 那步不调模型。
#
# review/agent 是 main 的必需检查，即合入门禁（#1435）：
#   - PPASS_REVIEW_NO_MERGE=1：CI 不开、不撤销自动合入（自动合入由开 PR 的会话开，靠必需检查把关；
#     用 GITHUB_TOKEN 开的自动合入不会触发 main 上的 push 流水线）；
#   - 本脚本永远退出 0，结论只看状态和 PR 评论；
#   - agent 非 0 退出、超时、没有 VERDICT 行都算基础设施失败（key、网络、超时），自动重试一次，仍失败由 review.sh
#     写 error +「评审没跑成」：error 不算通过、挡合入，但不当作代码有问题；VERDICT: FAIL 才是「评审不通过」（failure）。
#   - agent 那步：环境里不许有 GH_TOKEN / GITHUB_TOKEN，磁盘上的 git 配置里不许有凭据（extraheader），有就不跑、判没跑成；
#     claude 加 --setting-sources user --strict-mcp-config，不读 PR 检出里的 .claude/ 配置、hooks、MCP。
#
# 环境变量：
#   PPASS_CI_STATE         状态目录（默认 ${RUNNER_TEMP:-/tmp}/ppass-ci-review）；三步共用
#   ANTHROPIC_AUTH_TOKEN / ANTHROPIC_BASE_URL  agent 那步用
#   PPASS_REVIEW_MODEL     模型（prepare 那步交给 review.sh）
#   PPASS_CI_CLAUDE        真正的评审命令（默认 claude；测试用桩）
#   PPASS_CI_TIMEOUT       单次 agent 调用的超时秒数（默认 600；系统没有 timeout 命令则不限）
#   PPASS_CI_RETRY_SLEEP   重试前等几秒（默认 10）
#   GH_TOKEN               prepare / publish 用的令牌（workflow 里是 github.token）

set -uo pipefail

FLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${PPASS_CI_STATE:-${RUNNER_TEMP:-/tmp}/ppass-ci-review}"

# 评审没跑成：状态 error + 评论，不是代码问题（只用在 review.sh 自己没写出状态的时候）。
infra_report() {
  local pr="$1" sha="$2" why="$3"
  echo "ci-review: 评审没跑成：${why}" >&2
  if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    gh api -X POST "repos/${REPO}/statuses/${sha}" -f state=error -f context="review/agent" \
      -f description="评审没跑成（基础设施问题，不是代码问题）" >/dev/null 2>&1 ||
      echo "ci-review: 写状态 error 失败" >&2
  fi
  printf '**独立评审：评审没跑成**（头提交 `%s`）\n\n基础设施问题（key、网络、超时或脚本异常），**不是代码有问题**。review/agent=error 不算通过，合入会被挡住：在 Actions 里重跑这次评审即可。\n\n原因：%s\n' \
    "${sha:0:10}" "$why" >"${STATE}/infra.md"
  gh pr comment "$pr" -R "$REPO" --body-file "${STATE}/infra.md" >/dev/null 2>&1 ||
    echo "ci-review: 贴评论失败" >&2
}

load_repo() {
  # shellcheck source=worker-lib.sh
  . "${FLOW_DIR}/worker-lib.sh"
  REPO="$(flow_repo)"
}

do_prepare() {
  local pr="$1" sha rc=0
  load_repo
  rm -rf "$STATE"
  mkdir -p "$STATE"
  # 草稿不评：盯梢、人控级先开草稿、验收后转正式，转正式时（ready_for_review）再评一次。
  if [ "$(gh pr view "$pr" -R "$REPO" --json isDraft --jq .isDraft 2>/dev/null | tr -d '\r')" = true ]; then
    : >"${STATE}/skip"
    echo "ci-review: #${pr} 是草稿，不评审（转正式后再评）"
    return 0
  fi
  sha="$(gh pr view "$pr" -R "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null | tr -d '\r')"
  # 起跑先写 pending：结论没出来之前，这个头提交上的必需检查不是空着而是「等待中」。
  if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    gh api -X POST "repos/${REPO}/statuses/${sha}" -f state=pending -f context="review/agent" \
      -f description="独立评审进行中" >/dev/null 2>&1 || echo "ci-review: 写状态 pending 失败" >&2
  fi
  PPASS_REVIEW_PHASE=prepare PPASS_REVIEW_STATE="$STATE" bash "${FLOW_DIR}/review.sh" "$pr" >"${STATE}/prepare.log" 2>&1 || rc=$?
  cat "${STATE}/prepare.log"
  if [ "$rc" -ne 0 ]; then
    # 读不到 PR、没有 closes #N、头提交在途中变了……：评审没开始，后面两步跳过
    : >"${STATE}/skip"
    infra_report "$pr" "$sha" "评审准备失败（退出码 ${rc}）：$(tail -n 3 "${STATE}/prepare.log" | tr '\n' ' ')"
  fi
}

# agent 步骤失败、不跑：写成 review.sh 认的「没跑成」
agent_refuse() {
  printf '%s\n' "$1" >"${STATE}/agent.err"
  : >"${STATE}/agent.out"
  echo 1 >"${STATE}/agent.rc"
  echo "ci-review: $1" >&2
}

# 只读 agent：在不带任何 GitHub token 的步骤里跑。结论文件：agent.out / agent.err / agent.rc。
do_agent() {
  local claude="${PPASS_CI_CLAUDE:-claude}" limit="${PPASS_CI_TIMEOUT:-600}" attempt rc=1 last top a
  [ ! -e "${STATE}/skip" ] || { echo "ci-review: 准备阶段已跳过或失败，不跑 agent"; return 0; }
  if [ -e "${STATE}/reuse" ]; then
    # 复用上次的结论（头提交评过、PR 整体 diff 没变、或 owner 复核放行）：不调模型
    : >"${STATE}/agent.out"
    echo 0 >"${STATE}/agent.rc"
    echo "ci-review: 复用评审结论（$(cat "${STATE}/reuse")），不调模型"
    return 0
  fi
  if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
    agent_refuse "agent 步骤的环境里有 GH_TOKEN / GITHUB_TOKEN：拒绝运行（评审 agent 不许拿到写 GitHub 的令牌）"
    return 0
  fi
  top="$(git -C "$FLOW_DIR" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$top" ] && git -C "$top" config --get-regexp '^http\..*extraheader$' >/dev/null 2>&1; then
    agent_refuse "磁盘上的 git 配置里留有凭据（http.*.extraheader）：拒绝运行（检出要 persist-credentials: false）"
    return 0
  fi
  if [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    agent_refuse "没有拿到评审用的 key（Secret PPASS_REVIEW_API_KEY 为空；fork 的 PR 拿不到 Secret，Dependabot 的 PR 要另存 Dependabot secret）"
    return 0
  fi
  local args=()
  while IFS= read -r a; do args+=("$a"); done <"${STATE}/agent.args"
  args+=(--setting-sources user --strict-mcp-config)
  for attempt in 1 2; do
    local run=("$claude" "${args[@]}")
    if command -v timeout >/dev/null 2>&1; then run=(timeout "$limit" "${run[@]}"); fi
    rc=0
    (cd "${STATE}/checkout" && "${run[@]}" <"${STATE}/prompt.txt" >"${STATE}/agent.out" 2>"${STATE}/agent.err") || rc=$?
    last="$(grep -v '^[[:space:]]*$' "${STATE}/agent.out" 2>/dev/null | tail -n 1 | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
    if [ "$rc" -eq 0 ] && { [ "$last" = "VERDICT: PASS" ] || [ "$last" = "VERDICT: FAIL" ]; }; then
      echo 0 >"${STATE}/agent.rc"
      echo "ci-review: agent 返回 ${last}（第 ${attempt} 次）"
      return 0
    fi
    echo "ci-review: 第 ${attempt} 次没给出结论（退出码 ${rc}）：$(head -c 300 "${STATE}/agent.err" | tr '\n' ' ')" >&2
    [ "$attempt" -eq 2 ] || sleep "${PPASS_CI_RETRY_SLEEP:-10}"
  done
  # 两次都没结论：退出码原样交给 review.sh（0 但没有 VERDICT 行时它也判「没跑成」）
  echo "$rc" >"${STATE}/agent.rc"
}

do_publish() {
  local pr="$1" rc=0 sha
  load_repo
  [ ! -e "${STATE}/skip" ] || { echo "ci-review: 准备阶段已跳过或失败（失败时已写 error）"; return 0; }
  sha="$(cat "${STATE}/sha" 2>/dev/null)"
  if [ ! -s "${STATE}/agent.rc" ]; then
    echo 1 >"${STATE}/agent.rc"
    echo "agent 步骤没有跑完（被取消或崩溃）" >"${STATE}/agent.err"
  fi
  PPASS_REVIEW_NO_MERGE=1 PPASS_REVIEW_PHASE=publish PPASS_REVIEW_STATE="$STATE" \
    bash "${FLOW_DIR}/review.sh" "$pr" >"${STATE}/publish.log" 2>&1 || rc=$?
  cat "${STATE}/publish.log"
  # 只认 review.sh 在状态真正写成功后才打的标记行（#1441）：报错文案里出现 review/agent 字样不算已写。
  if [ "$rc" -ne 0 ] && ! grep -qE '^REVIEW_STATUS_WRITTEN=(success|failure|error)$' "${STATE}/publish.log"; then
    # review.sh 没走到「写完状态」就退了（贴评论、写状态的 gh 调用失败）
    infra_report "$pr" "$sha" "review.sh 没写出评审状态就退出了（退出码 ${rc}）：$(tail -n 3 "${STATE}/publish.log" | tr '\n' ' ')"
  fi
}

# owner 复核放行（#1470）：评审判不了、或阻断项 owner 判定不成立时，仓库 owner 在 PR 上评论
# 「/review-override <理由>」。只认对本仓有 admin 权限的真人账号（仓库属组织，author_association 是 MEMBER，
# 不能当依据；用 gh api 现查作者与权限，不信事件载荷）；理由不能为空。
# 通过后贴一条带 agent=OVERRIDE 标记的评论（只对当时的头提交有效，推新提交即作废），
# 再走一遍 prepare / publish：复用这个结论，不调模型；盯梢、人控级仍要验收行。
do_override() {
  local pr="$1" cid="$2" meta login utype url body reason perm sha
  load_repo
  rm -rf "$STATE"
  mkdir -p "$STATE"
  meta="$(gh api "repos/${REPO}/issues/comments/${cid}" --jq '[.user.login, .user.type, .html_url] | @tsv' 2>/dev/null | tr -d '\r')" ||
    { echo "ci-review: 读不到评论 ${cid}，不放行" >&2; return 0; }
  IFS=$'\t' read -r login utype url <<<"$meta"
  body="$(gh api "repos/${REPO}/issues/comments/${cid}" --jq .body 2>/dev/null | tr -d '\r' | head -n 1)"
  reason="$(printf '%s' "$body" | sed -n 's|^/review-override[[:space:]][[:space:]]*\([^[:space:]].*\)$|\1|p')"
  if [ -z "$reason" ]; then
    echo "ci-review: 评论 ${cid} 不是「/review-override <理由>」（理由不能为空），不放行" >&2
    return 0
  fi
  perm="$(gh api "repos/${REPO}/collaborators/${login}/permission" --jq .permission 2>/dev/null | tr -d '\r')" || perm=""
  if [ "$utype" != User ] || [ "$perm" != admin ]; then
    echo "ci-review: ${login}（${utype:-?}，权限 ${perm:-无}）不是仓库 owner，/review-override 无效" >&2
    return 0
  fi
  sha="$(gh pr view "$pr" -R "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null | tr -d '\r')"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "ci-review: 读不到 #${pr} 的头提交，不放行" >&2; return 0; }
  {
    printf '**独立评审：owner 复核放行**（头提交 `%s`）\n\n' "${sha:0:10}"
    printf '%s 在 %s 复核放行，理由：%s\n\n' "$login" "$url" "$reason"
    printf '<sub>只对头提交 `%s` 有效，推新提交照常评审；盯梢、人控级仍要验收记录。</sub>\n' "${sha:0:10}"
    printf '<!-- ppass-review sha=%s agent=OVERRIDE -->\n' "$sha"
  } >"${STATE}/override.md"
  gh pr comment "$pr" -R "$REPO" --body-file "${STATE}/override.md" >/dev/null 2>&1 ||
    { infra_report "$pr" "$sha" "贴 owner 复核放行评论失败"; return 0; }
  do_prepare "$pr"
  [ ! -e "${STATE}/skip" ] || return 0
  if [ ! -e "${STATE}/reuse" ]; then
    # 标记没被认出来（例如评论列表读不到）：不能退回去调模型，判没跑成，owner 重发一次即可
    agent_refuse "没认出刚贴的 owner 复核放行标记，未放行（重发 /review-override 即可）"
  else
    : >"${STATE}/agent.out"
    echo 0 >"${STATE}/agent.rc"
  fi
  do_publish "$pr"
}

case "${1:-}" in
  override)
    [[ "${2:-}" =~ ^[0-9]+$ ]] && [[ "${3:-}" =~ ^[0-9]+$ ]] || { echo "用法：ci-review.sh override <PR号> <评论ID>" >&2; exit 2; }
    do_override "$2" "$3"
    ;;
  prepare)
    [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "用法：ci-review.sh prepare <PR号>" >&2; exit 2; }
    do_prepare "$2"
    ;;
  agent) do_agent ;;
  publish)
    [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "用法：ci-review.sh publish <PR号>" >&2; exit 2; }
    do_publish "$2"
    ;;
  *)
    [[ "${1:-}" =~ ^[0-9]+$ ]] || { echo "用法：ci-review.sh prepare|agent|publish …，或 ci-review.sh <PR号>" >&2; exit 2; }
    do_prepare "$1"
    env -u GH_TOKEN -u GITHUB_TOKEN bash "${BASH_SOURCE[0]}" agent
    do_publish "$1"
    ;;
esac
exit 0
