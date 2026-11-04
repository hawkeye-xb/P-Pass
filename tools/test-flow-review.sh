#!/usr/bin/env bash
# just review（tools/flow/review.sh）的判据测试。
#
# 临时仓库（裸 origin 里有 refs/pull/7/head）里走真实路径；gh 与评审 agent 都是桩：
#   gh     读写 $FAKE 目录：pr 头提交、正文，issue 正文；评论与提交状态记在文件里
#   agent  记下收到的参数、工作目录、stdin，按 $FAKE/mode 决定怎么回答
# 每条拒绝都配一条只去掉触发条件的放行用例作反证。
#
# 用法: tools/test-flow-review.sh
# 退出码: 0 全过 / 1 有失败

set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() {
  printf '  ✅ %s\n' "$1"
  PASS=$((PASS + 1))
}
bad() {
  printf '  ❌ %s\n' "$1"
  FAIL=$((FAIL + 1))
}

export HOME="${TMP}/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
mkdir -p "$HOME"
git config --global user.name "Review Test"
git config --global user.email "review-test@example.invalid"
git config --global init.defaultBranch main
export PPASS_HOOK_REPO="o/r"

FAKE="${TMP}/fake"
mkdir -p "$FAKE" "${TMP}/bin"
export FAKE
export PATH="${TMP}/bin:${PATH}"

# ── 假 gh ─────────────────────────────────────────────────────────────
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
F="$FAKE"
case "$1 $2" in
  "pr view")
    printf 'state:%s\nsha:%s\ntitle:%s\nbody:\n' "$(cat "$F/pr.state")" "$(cat "$F/pr.sha")" "T-7 title"
    cat "$F/pr.body"
    ;;
  "pr diff") cat "$F/pr.diff" ;;
  "pr comment")
    n="$3"; shift 3
    while [ $# -gt 0 ]; do
      [ "$1" = "--body-file" ] && { cat "$2" >>"$F/comments"; echo "-----" >>"$F/comments"; }
      shift
    done
    ;;
  "issue view")
    printf 'state:OPEN\ntitle:%s\nlabels:status:doing\nbody:\n' "card $3"
    cat "$F/issue.$3"
    ;;
  "api -X")
    shift 2
    echo "$*" >>"$F/statuses"
    ;;
  *) echo "stub gh: unsupported $*" >&2; exit 2 ;;
esac
STUB
chmod +x "${TMP}/bin/gh"

# ── 假评审 agent ──────────────────────────────────────────────────────
cat >"${TMP}/bin/fake-agent" <<'STUB'
#!/usr/bin/env bash
F="$FAKE"
printf '%s\n' "$@" >"$F/agent.args"
pwd -P >"$F/agent.cwd"
cat >"$F/agent.stdin"
case "$(cat "$F/mode")" in
  pass) echo "未发现正确性问题。"; echo "VERDICT: PASS" ;;
  fail) echo "tools/x.sh:3 —— MAC_GLOBS 没加引号，会被 shell 展开。"; echo "VERDICT: FAIL" ;;
  noverdict) echo "看起来还行。" ;;
  crash) echo "boom" >&2; exit 3 ;;
  tamper) echo "x" >>tools/x.sh; echo "VERDICT: PASS" ;;
esac
STUB
chmod +x "${TMP}/bin/fake-agent"
export PPASS_REVIEW_AGENT="${TMP}/bin/fake-agent"

# ── 仓库：裸 origin + 主仓，PR #7 的头提交在 refs/pull/7/head ─────────
git init -q --bare "${TMP}/origin.git"
git init -q "${TMP}/main"
(
  cd "${TMP}/main" || exit 1
  git remote add origin "${TMP}/origin.git"
  mkdir -p tools/flow
  cp -R "${SRC}/tools/flow/." tools/flow/
  printf 'echo base\n' >tools/x.sh
  git add -A && git commit -q -m init
  git push -q origin HEAD:refs/heads/main
  git checkout -q -b pr7
  printf 'echo changed\n' >tools/x.sh
  git commit -q -am "change x"
  git push -q origin HEAD:refs/pull/7/head
  git rev-parse HEAD >"${FAKE}/pr.sha"
  git checkout -q main
)
printf 'OPEN' >"$FAKE/pr.state"
printf -- '--- a/tools/x.sh\n+++ b/tools/x.sh\n@@\n-echo base\n+echo changed-DIFFLINE\n' >"$FAKE/pr.diff"
printf '**范围（只许动这些）**：\n```\ntools/x.sh\n```\n\n**验收场景**：MARK-ACCEPT 引号必须加。\n' >"$FAKE/issue.77"
printf 'closes #77\n\n改了 x。\n' >"$FAKE/pr.body"
SHA="$(cat "$FAKE/pr.sha")"

REVIEW() { (cd "${TMP}/main" && bash tools/flow/review.sh "$@"); }
reset() {
  : >"$FAKE/comments"
  : >"$FAKE/statuses"
  rm -f "$FAKE/agent.args" "$FAKE/agent.cwd" "$FAKE/agent.stdin"
  printf '%s' "$1" >"$FAKE/mode"
}
has() { grep -qF -- "$1" "$2"; }

echo "==> 通过"
reset pass
REVIEW 7 >"${TMP}/o1" 2>&1 && ok "VERDICT: PASS → 退出 0" || bad "PASS 却失败：$(tail -3 "${TMP}/o1")"
has "独立评审：通过" "$FAKE/comments" && ok "评论写「通过」" || bad "评论不对：$(cat "$FAKE/comments")"
has "state=success" "$FAKE/statuses" && has "context=review/agent" "$FAKE/statuses" && ok "提交状态 review/agent=success" || bad "状态不对：$(cat "$FAKE/statuses")"
grep -q "${SHA}" "$FAKE/statuses" && ok "状态写在 PR 头提交上" || bad "状态没写在头提交上"
has "VERDICT" "$FAKE/comments" && bad "评论里留了 VERDICT 行" || ok "评论里不带 VERDICT 行"

echo "==> 只读权限与输入"
ARGS="$FAKE/agent.args"
has "Read Grep Glob" "$ARGS" && ok "allowedTools 只有 Read Grep Glob" || bad "allowedTools 不对：$(cat "$ARGS")"
python3 - "$ARGS" <<'PY' && ok "allowedTools 里没有 Bash / Edit / Write" || bad "allowedTools 里混进了写权限或 Bash"
import sys
a = open(sys.argv[1]).read().split("\n")
i = a.index("--allowedTools")
allowed = a[i + 1].split()
sys.exit(1 if set(allowed) & {"Bash", "Edit", "Write", "NotebookEdit"} else 0)
PY
has "--disallowedTools" "$ARGS" && has "Bash Edit Write" "$ARGS" && ok "disallowedTools 兜底禁写与 Bash" || bad "没有 disallowedTools"
[ "$(cat "$FAKE/agent.cwd")" != "$(cd "${TMP}/main" && pwd -P)" ] && ok "agent 的工作目录不是主仓" || bad "agent 在主仓里跑"
has "MARK-ACCEPT" "$FAKE/agent.stdin" && ok "prompt 带卡上的验收场景" || bad "prompt 缺验收场景"
has "tools/x.sh" "$FAKE/agent.stdin" && has "DIFFLINE" "$FAKE/agent.stdin" && ok "prompt 带范围与 diff" || bad "prompt 缺范围或 diff"
has "VERDICT: PASS" "$FAKE/agent.stdin" && ok "prompt 说明了 VERDICT 约定" || bad "prompt 没写 VERDICT 约定"
has "--model" "$ARGS" && bad "没指定模型却带了 --model" || ok "没指定模型 → 不带 --model"
reset pass
REVIEW 7 --model deepseek-x >/dev/null 2>&1
has "deepseek-x" "$FAKE/agent.args" && ok "--model 传给 agent" || bad "--model 没传到 agent"

echo "==> 未通过"
reset fail
REVIEW 7 >"${TMP}/o2" 2>&1 && bad "VERDICT: FAIL 却退出 0" || ok "VERDICT: FAIL → 退出非 0"
has "独立评审：未通过" "$FAKE/comments" && has "MAC_GLOBS" "$FAKE/comments" && ok "评论写「未通过」并带问题清单" || bad "评论不对：$(cat "$FAKE/comments")"
has "state=failure" "$FAKE/statuses" && ok "提交状态 review/agent=failure" || bad "状态不对：$(cat "$FAKE/statuses")"
reset noverdict
REVIEW 7 >/dev/null 2>&1 && bad "没有 VERDICT 却通过" || ok "没有 VERDICT → 按未通过（反证：有 VERDICT: PASS 才通过）"
has "state=failure" "$FAKE/statuses" && ok "没有 VERDICT → 状态 failure" || bad "没有 VERDICT 状态不是 failure"
reset crash
REVIEW 7 >/dev/null 2>&1 && bad "agent 崩了却通过" || ok "agent 退出非 0 → 未通过"
has "state=failure" "$FAKE/statuses" && has "退出码 3" "$FAKE/comments" && ok "agent 崩溃 → 状态 failure，评论写明原因" || bad "agent 崩溃的记录不对"
reset tamper
REVIEW 7 >/dev/null 2>&1 && bad "agent 改了检出却通过" || ok "agent 改动检出 → 评审作废（即使它说 PASS）"
has "state=failure" "$FAKE/statuses" && has "改动了只读检出" "$FAKE/comments" && ok "改动检出 → failure 并写明" || bad "改动检出的记录不对"
git -C "${TMP}/main" worktree list | grep -q checkout && bad "临时检出没清掉" || ok "临时检出评审后清掉"

echo "==> 拒绝评审"
reset pass
printf 'no card here\n' >"$FAKE/pr.body"
REVIEW 7 >/dev/null 2>&1 && bad "PR 正文没有 closes #N 却评审了" || ok "正文没有 closes #N → 拒绝"
[ ! -s "$FAKE/comments" ] && [ ! -s "$FAKE/statuses" ] && ok "拒绝时不贴评论、不写状态" || bad "拒绝时仍写了评论或状态"
printf 'closes #77\n' >"$FAKE/pr.body"
REVIEW 7 >/dev/null 2>&1 && ok "反证：补上 closes #77 → 评审通过" || bad "补上 closes 仍失败"
printf 'MERGED' >"$FAKE/pr.state"
reset pass
REVIEW 7 >/dev/null 2>&1 && bad "已合并的 PR 也评审了" || ok "PR 不是 open → 拒绝"
printf 'OPEN' >"$FAKE/pr.state"
REVIEW abc >/dev/null 2>&1 && bad "非数字 PR 号被接受" || ok "PR 号不是数字 → 拒绝"
REVIEW >/dev/null 2>&1 && bad "没给 PR 号被接受" || ok "没给 PR 号 → 拒绝"

echo
echo "flow-review: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
