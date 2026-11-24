#!/usr/bin/env bash
# CI 独立评审（tools/flow/ci-review.sh + flow.py review）判据测试：
# 覆盖：token 物理隔离、草稿跳过、三级结论（仅阻断挡合入）、owner 复核放行、碰核心必验已采纳方案、
# 以及【彻底废除增量盲区：二次推送提交必须审阅完整 origin/main...HEAD 全量 diff】。
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { printf '  ✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }

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

cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
F="$FAKE"
case "$1 $2" in
  "pr view")
    case " $* " in *" headRefOid --jq .headRefOid "*) cat "$F/pr.sha"; exit 0 ;; esac
    case " $* " in *" --json isDraft "*) cat "$F/pr.draft" 2>/dev/null || echo false; exit 0 ;; esac
    case " $* " in *" --json author "*) cat "$F/pr.author" 2>/dev/null; exit 0 ;; esac
    printf 'state:%s\nsha:%s\ntitle:%s\nbody:\n' "$(cat "$F/pr.state")" "$(cat "$F/pr.sha")" "T-7 title"
    cat "$F/pr.body"
    ;;
  "pr diff")
    case " $* " in *" --name-only "*) cat "$F/pr.files" ;; *) cat "$F/pr.diff" ;; esac
    ;;
  "pr merge")
    case " $* " in *" --disable-auto "*) echo "$*" >>"$F/disables"; exit 0 ;; esac
    echo "$*" >>"$F/merges" ;;
  "pr comment")
    [ ! -e "$F/comment_fail" ] || { echo "HTTP 502" >&2; exit 1; }
    shift 3
    while [ $# -gt 0 ]; do
      if [ "$1" = "--body-file" ]; then
        cat "$2" >>"$F/comments"; echo "-----" >>"$F/comments"
        id=$(( $(cat "$F/cid" 2>/dev/null || echo 100) + 1 )); echo "$id" >"$F/cid"
        cp "$2" "$F/c.$id"
        m="$(sed -n 's/.*<!-- ppass-review \([^>]*\) -->.*/\1/p' "$2" | tail -n 1)"
        [ -z "$m" ] || printf '%s\t%s\t%s\n' "$(cat "$F/commenter" 2>/dev/null || echo 'github-actions[bot]')" "$id" "$m" >>"$F/marks"
      fi
      shift
    done
    ;;
  "issue view")
    printf 'state:OPEN\ntitle:%s\nlabels:status:doing\nbody:\n' "card $3"
    cat "$F/issue.$3"
    ;;
  "api repos/o/r/issues/7/comments")
    cat "$F/marks" 2>/dev/null || true ;;
  "api repos/o/r/issues/comments/"*)
    id="${2##*/}"
    case " $* " in *" --jq .body "*) cat "$F/c.$id" ;; *) cat "$F/c.$id.meta" ;; esac ;;
  "api repos/o/r/collaborators/"*)
    login="${2#repos/o/r/collaborators/}"; login="${login%/permission}"
    cat "$F/perm.$login" 2>/dev/null || echo read ;;
  "api graphql")
    cat "$F/threads" 2>/dev/null || true ;;
  "api -X")
    shift 2
    echo "$*" >>"$F/statuses"
    ;;
  *) echo "stub gh: unsupported $*" >&2; exit 2 ;;
esac
STUB
chmod +x "${TMP}/bin/gh"

cat >"${TMP}/bin/fake-claude" <<'STUB'
#!/usr/bin/env bash
F="$FAKE"
cat >"$F/agent.stdin"
echo x >>"$F/calls"
printf 'args:%s\ngh_token:%s\n' "$*" "${GH_TOKEN:-}${GITHUB_TOKEN:-}" >"$F/agent.env"
case "$(cat "$F/mode")" in
  pass) echo "未发现问题。"; echo "VERDICT: PASS" ;;
  fail) echo "- [阻断] tools/x.sh:3 —— 卡上第 2 条没做到。"; echo "VERDICT: FAIL" ;;
  suggest) echo "- [建议] tools/x.sh:3 —— 可以再加一条用例。"; echo "- [风格] tools/x.sh:1 —— 措辞。"; echo "VERDICT: PASS" ;;
  block_says_pass) echo "- [阻断] tools/x.sh:3 —— 判定会误放行。"; echo "VERDICT: PASS" ;;
  infra) echo "401 invalid api key" >&2; exit 1 ;;
esac
STUB
chmod +x "${TMP}/bin/fake-claude"
export PPASS_CI_CLAUDE="${TMP}/bin/fake-claude"
export PPASS_CI_RETRY_SLEEP=0
export ANTHROPIC_AUTH_TOKEN=test-key

git init --template= -q --bare "${TMP}/origin.git"
git init --template= -q "${TMP}/main"
(
  cd "${TMP}/main" || exit 1
  git remote add origin "${TMP}/origin.git"
  mkdir -p tools/flow .github docs/decisions
  cp -R "${SRC}/tools/flow/." tools/flow/
  cp "${SRC}/tools/ci-paths.sh" tools/ci-paths.sh
  printf '+ core/**\n' >.github/core-paths.txt
  printf 'echo base\n' >tools/x.sh
  printf '# 方案\n\n- 状态：已采纳\n' >docs/decisions/2026-11-01-adopted.md
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
printf 'tools/x.sh\n' >"$FAKE/pr.files"
printf -- '--- a/tools/x.sh\n+++ b/tools/x.sh\n@@\n-echo base\n+echo changed\n' >"$FAKE/pr.diff"
printf '**验收场景**：x。\n' >"$FAKE/issue.77"
printf 'closes #77\n' >"$FAKE/pr.body"
printf 'someone' >"$FAKE/pr.author"
export GH_TOKEN=stub-gh-token
export PPASS_CI_STATE="${TMP}/state"

CI() { (cd "${TMP}/main" && bash tools/flow/ci-review.sh "$@"); }
reset() {
  : >"$FAKE/comments"; : >"$FAKE/statuses"; : >"$FAKE/merges"; : >"$FAKE/disables"; : >"$FAKE/calls"
  : >"$FAKE/marks"; rm -f "$FAKE/commenter" "$FAKE/pr.draft" "$FAKE/threads" "$FAKE/agent.stdin"
  printf '%s' "$1" >"$FAKE/mode"
}
again() { : >"$FAKE/statuses"; : >"$FAKE/calls"; : >"$FAKE/comments"; rm -f "$FAKE/agent.stdin"; printf '%s' "$1" >"$FAKE/mode"; }
has() { grep -qF -- "$1" "$2"; }
calls() { wc -l <"$FAKE/calls" | tr -d ' '; }

reset pass
CI 7 >/dev/null 2>&1 && has "state=success" "$FAKE/statuses" && grep -qx 'gh_token:' "$FAKE/agent.env" &&
  ok "通过 → review/agent=success 且 agent 物理隔离无 GH_TOKEN" || bad "首评通过或 token 隔离异常"

reset fail
CI 7 >/dev/null 2>&1 && has "state=failure" "$FAKE/statuses" && [ "$(calls)" = 1 ] &&
  ok "阻断项 → review/agent=failure" || bad "阻断项未判 failure"

reset block_says_pass
CI 7 >/dev/null 2>&1 && has "state=failure" "$FAKE/statuses" &&
  ok "有 [阻断] 行即使写 VERDICT: PASS 仍判 failure" || bad "阻断行被绕过"

reset suggest
CI 7 >/dev/null 2>&1 && has "state=success" "$FAKE/statuses" &&
  ok "仅建议/风格 → success 不挡合入" || bad "建议项误挡合入"

reset infra
CI 7 >/dev/null 2>&1 && tail -n 1 "$FAKE/statuses" | grep -qF "state=error" && [ "$(calls)" = 2 ] &&
  ok "基础设施异常重试 1 次后写 error" || bad "infra 处理异常"

reset pass
printf 'true' >"$FAKE/pr.draft"
CI 7 >/dev/null 2>&1 && [ "$(calls)" = 0 ] && ok "草稿 PR 跳过评审" || bad "草稿误评"
rm -f "$FAKE/pr.draft"

reset pass
printf 'core/c.txt\ntools/test-c.sh\n' >"$FAKE/pr.files"
CI 7 >/dev/null 2>&1 && tail -n 1 "$FAKE/statuses" | grep -qF "state=failure" &&
  ok "碰核心缺已采纳方案 → 即使 agent PASS 仍判 failure" || bad "核心缺方案漏放"
printf 'tools/x.sh\n' >"$FAKE/pr.files"

# 关键防漏审硬判据：推第 2 个提交时，必须审阅完整全量 diff（包含第 1 个提交的 ROUND1-BUG），绝不走增量盲区！
reset pass
printf -- '--- a/tools/x.sh\n+++ b/tools/x.sh\n+echo ROUND1-UTF8-SLICE-BUG\n' >"$FAKE/pr.diff"
CI 7 >/dev/null 2>&1
(
  cd "${TMP}/main" && git checkout -q pr7 &&
    printf 'echo round2\n' >tools/y.sh && git add tools/y.sh && git commit -q -m "round 2" &&
    git push -q origin HEAD:refs/pull/7/head && git rev-parse HEAD >"${FAKE}/pr.sha" && git checkout -q main
)
printf 'tools/x.sh\ntools/y.sh\n' >"$FAKE/pr.files"
printf -- '--- a/tools/x.sh\n+++ b/tools/x.sh\n+echo ROUND1-UTF8-SLICE-BUG\n--- /dev/null\n+++ b/tools/y.sh\n+echo round2\n' >"$FAKE/pr.diff"
again pass
CI 7 >/dev/null 2>&1
[ "$(calls)" = 1 ] && grep -qF "ROUND1-UTF8-SLICE-BUG" "$FAKE/agent.stdin" && ! grep -qF "本次只评增量" "$FAKE/agent.stdin" &&
  ok "彻底废除增量盲区：第 2 次推送仍将第 1 轮完整 diff 喂给评审模型" || bad "二轮推送漏掉了第一轮 diff！"

# owner 复核放行
printf 'admin' >"$FAKE/perm.690591397"
reset fail
CI 7 >/dev/null 2>&1
again pass
printf '/review-override 核实无误\n' >"$FAKE/c.903"
printf '690591397\tUser\thttps://github.com/o/r/pull/7#issuecomment-903\n' >"$FAKE/c.903.meta"
(cd "${TMP}/main" && bash tools/flow/ci-review.sh override 7 903) >/dev/null 2>&1
[ "$(calls)" = 0 ] && tail -n 1 "$FAKE/statuses" | grep -qF "state=success" &&
  ok "owner /review-override 正常生效" || bad "override 失败"

echo
echo "ci-review: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
