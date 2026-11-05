#!/usr/bin/env bash
# CI 评审（tools/flow/ci-review.sh，#1410）的判据测试：复用 review.sh，试跑期只提示、不挡合入。
#
# 临时仓库（裸 origin 里有 refs/pull/7/head）里走真实路径；gh 与评审 agent 都是桩：
#   gh     读写 $FAKE 目录：pr 头提交、正文，issue 正文；评论与提交状态记在文件里
#   claude 记下调用次数，按 $FAKE/mode 决定怎么回答（ci-review.sh 的垫片调它）
# 每条结论都配一条只改触发条件的反证用例。
#
# 用法: tools/test-ci-review.sh
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
  "pr diff")
    case " $* " in *" --name-only "*) cat "$F/pr.files" ;; *) cat "$F/pr.diff" ;; esac
    ;;
  "pr merge")
    case " $* " in *" --disable-auto "*)
      echo "$*" >>"$F/disables"
      [ ! -e "$F/disable_fail" ] || { echo "${DISABLE_ERR:-HTTP 500}" >&2; exit 1; }
      exit 0 ;;
    esac
    echo "$*" >>"$F/merges"; [ ! -e "$F/merge_fail" ] || { echo "auto-merge not allowed" >&2; exit 1; } ;;
  "pr comment")
    [ ! -e "$F/comment_fail" ] || { echo "HTTP 502" >&2; exit 1; }
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
  "api repos/o/r/issues/7/comments")
    grep -q "独立评审：未通过" "$F/comments" && echo 4242 || true ;;
  "api -X")
    [ "$3" != DELETE ] || { echo "$*" >>"$F/deletes"; exit 0; }
    shift 2
    echo "$*" >>"$F/statuses"
    ;;
  *) echo "stub gh: unsupported $*" >&2; exit 2 ;;
esac
STUB
chmod +x "${TMP}/bin/gh"

# ── 假 claude ────────────────────────────────────────────────────────
cat >"${TMP}/bin/fake-claude" <<'STUB'
#!/usr/bin/env bash
F="$FAKE"
cat >/dev/null
echo x >>"$F/calls"
n="$(wc -l <"$F/calls" | tr -d ' ')"
case "$(cat "$F/mode")" in
  pass) echo "未发现问题。"; echo "VERDICT: PASS" ;;
  fail) echo "tools/x.sh:3 —— 卡上第 2 条没做到。"; echo "VERDICT: FAIL" ;;
  infra) echo "401 invalid api key" >&2; exit 1 ;;
  noverdict) echo "看起来还行。" ;;
  flaky) if [ "$n" -eq 1 ]; then echo "timeout" >&2; exit 1; else echo "ok"; echo "VERDICT: PASS"; fi ;;
esac
STUB
chmod +x "${TMP}/bin/fake-claude"
export PPASS_CI_CLAUDE="${TMP}/bin/fake-claude"
export PPASS_CI_RETRY_SLEEP=0
export ANTHROPIC_AUTH_TOKEN=test-key

git init -q --bare "${TMP}/origin.git"
git init -q "${TMP}/main"
(
  cd "${TMP}/main" || exit 1
  git remote add origin "${TMP}/origin.git"
  mkdir -p tools/flow .github
  cp -R "${SRC}/tools/flow/." tools/flow/
  cp "${SRC}/tools/ci-paths.sh" tools/ci-paths.sh
  printf '+ core/**\n' >.github/core-paths.txt
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
printf 'tools/x.sh\n' >"$FAKE/pr.files"
printf -- '--- a/tools/x.sh\n+++ b/tools/x.sh\n@@\n-echo base\n+echo changed\n' >"$FAKE/pr.diff"
printf '**范围（只许动这些）**：\n```\ntools/x.sh\n```\n\n**验收场景**：x。\n' >"$FAKE/issue.77"
printf 'closes #77\n' >"$FAKE/pr.body"
SHA="$(cat "$FAKE/pr.sha")"
# 假 gh 补一条：pr view --json headRefOid（ci-review.sh 取头提交）
sed -i.bak 's|  "pr view")|  "pr view")\n    case " $* " in *" headRefOid --jq .headRefOid "*) cat "$F/pr.sha"; exit 0 ;; esac|' "${TMP}/bin/gh"

CI() { (cd "${TMP}/main" && bash tools/flow/ci-review.sh "$@"); }
reset() {
  : >"$FAKE/deletes"; : >"$FAKE/comments"; : >"$FAKE/statuses"; : >"$FAKE/merges"; : >"$FAKE/disables"; : >"$FAKE/calls"
  printf '%s' "$1" >"$FAKE/mode"
}
has() { grep -qF -- "$1" "$2"; }
calls() { wc -l <"$FAKE/calls" | tr -d ' '; }

echo "==> 通过"
reset pass
CI 7 >"${TMP}/o1" 2>&1 && ok "通过 → 退出 0" || bad "通过却失败：$(tail -3 "${TMP}/o1")"
has "state=success" "$FAKE/statuses" && has "context=review/agent" "$FAKE/statuses" && ok "状态 review/agent=success" || bad "状态不对：$(cat "$FAKE/statuses")"
has "独立评审：通过" "$FAKE/comments" && ok "评论写通过" || bad "评论不对"
[ ! -s "$FAKE/merges" ] && ok "通过 → 不开自动合入（试跑期）" || bad "通过却开了自动合入：$(cat "$FAKE/merges")"
has "VERDICT: PASS" "${TMP}/o1" && ok "日志里留有 agent 返回的 VERDICT 行" || bad "日志里没有 VERDICT 行"
[ "$(calls)" = 1 ] && ok "通过 → agent 只调一次" || bad "调了 $(calls) 次"

echo "==> 不通过（代码有问题）"
reset fail
CI 7 >/dev/null 2>&1 && ok "不通过 → job 仍退出 0（不挡合入）" || bad "不通过时 job 失败了"
has "state=failure" "$FAKE/statuses" && ok "状态 failure" || bad "状态不对：$(cat "$FAKE/statuses")"
has "独立评审：未通过" "$FAKE/comments" && ok "评论写未通过" || bad "评论不对"
[ ! -s "$FAKE/deletes" ] && ok "反证：真不通过 → 不删「未通过」评论" || bad "真不通过却删了评论"
[ ! -s "$FAKE/merges" ] && [ ! -s "$FAKE/disables" ] && ok "不通过 → 不开也不撤销自动合入" || bad "碰了自动合入：$(cat "$FAKE/merges" "$FAKE/disables")"
[ "$(calls)" = 1 ] && ok "VERDICT: FAIL 是评审结论，不重试" || bad "FAIL 被重试了（$(calls) 次）"
has "评审没跑成" "$FAKE/comments" && bad "不通过被写成评审没跑成" || ok "不通过不写「评审没跑成」"

echo "==> 基础设施失败"
reset infra
CI 7 >/dev/null 2>&1 && ok "infra → job 退出 0" || bad "infra 时 job 失败"
[ "$(calls)" = 2 ] && ok "infra → 重试一次（共 2 次）" || bad "调用次数 $(calls)，应为 2"
tail -n 1 "$FAKE/statuses" | grep -qF "state=error" && ok "状态 error（不是 failure）" || bad "状态不对：$(cat "$FAKE/statuses")"
has "评审没跑成" "$FAKE/comments" && has "不是代码有问题" "$FAKE/comments" && ok "评论写「评审没跑成」" || bad "评论不对：$(cat "$FAKE/comments")"
has "comments/4242" "$FAKE/deletes" && ok "infra → 删掉 review.sh 贴的「未通过」评论，避免与「评审没跑成」矛盾" || bad "没删「未通过」评论：$(cat "$FAKE/deletes")"
[ ! -s "$FAKE/merges" ] && ok "infra → 不碰自动合入" || bad "infra 开了自动合入"
reset infra
printf '**独立评审：未通过**（头提交 `%s`）\n更早一次的真实结论\n-----\n' "${SHA:0:10}" >"$FAKE/comments"
CI 7 >/dev/null 2>&1
[ ! -s "$FAKE/deletes" ] && ok "反证：同一提交上更早的真实「未通过」评论不删" || bad "误删了更早的评论：$(cat "$FAKE/deletes")"
reset noverdict
CI 7 >/dev/null 2>&1
tail -n 1 "$FAKE/statuses" | grep -qF "state=error" && [ "$(calls)" = 2 ] && ok "退出 0 但没有 VERDICT 行 → 也算 infra，重试后 error" || bad "无 VERDICT 处理不对：$(cat "$FAKE/statuses") 调用 $(calls)"
reset flaky
CI 7 >/dev/null 2>&1
[ "$(calls)" = 2 ] && has "state=success" "$FAKE/statuses" && ! has "state=error" "$FAKE/statuses" && ok "反证：第一次失败、重试成功 → success，不留 error" || bad "重试成功的结果不对：$(cat "$FAKE/statuses") 调用 $(calls)"
reset pass
ANTHROPIC_AUTH_TOKEN= CI 7 >/dev/null 2>&1
tail -n 1 "$FAKE/statuses" | grep -qF "state=error" && [ "$(calls)" = 0 ] && has "评审没跑成" "$FAKE/comments" && ok "没有 key → error + 评审没跑成，不调 agent" || bad "没有 key 处理不对"
reset pass
printf 'no card\n' >"$FAKE/pr.body"
CI 7 >/dev/null 2>&1 && tail -n 1 "$FAKE/statuses" | grep -qF "state=error" && ok "review.sh 提前退出（正文没有 closes）→ error，job 仍成功" || bad "提前退出处理不对：$(cat "$FAKE/statuses")"
printf 'closes #77\n' >"$FAKE/pr.body"

echo "==> 不带开关时 review.sh 行为不变（反证）"
reset pass
export PPASS_REVIEW_AGENT="${TMP}/bin/fake-claude"
(cd "${TMP}/main" && env -u PPASS_REVIEW_NO_MERGE bash tools/flow/review.sh 7) >/dev/null 2>&1
has "--auto --squash" "$FAKE/merges" && ok "没设 PPASS_REVIEW_NO_MERGE → 通过后开自动合入" || bad "没开自动合入"
reset fail
(cd "${TMP}/main" && env -u PPASS_REVIEW_NO_MERGE bash tools/flow/review.sh 7) >/dev/null 2>&1
has "--disable-auto" "$FAKE/disables" && ok "没设开关 → 未通过撤销自动合入" || bad "没撤销"

echo "==> review.sh 在 agent 跑完后才失败（贴评论的 gh 调用挂了）"
reset pass
touch "$FAKE/comment_fail"
CI 7 >"${TMP}/o9" 2>&1 && ok "退出 0" || bad "job 失败了"
tail -n 1 "$FAKE/statuses" | grep -qF "state=error" && ok "没写出评审状态 → 补写 error，结论不被静默丢掉" || bad "状态不对：$(cat "$FAKE/statuses")"
rm -f "$FAKE/comment_fail"
reset pass
CI 7 >/dev/null 2>&1
has "state=success" "$FAKE/statuses" && ! has "state=error" "$FAKE/statuses" && ok "反证：gh 正常 → success，不补 error" || bad "反证不对：$(cat "$FAKE/statuses")"

echo "==> 超时预算"
python3 - "${SRC}" <<'PY2' && ok "两次 agent 超时 + 重试间隔 + 安装耗时 < job 超时" || bad "超时预算超过 job 上限"
import re,sys
src=sys.argv[1]
sh=open(src+"/tools/flow/ci-review.sh").read()
yml=open(src+"/.github/workflows/ci-review.yml").read()
per=int(re.search(r'PPASS_CI_TIMEOUT:-(\d+)',sh).group(1))
job=int(re.search(r'timeout-minutes: (\d+)',yml).group(1))*60
sys.exit(0 if 2*per+10+600 < job else 1)
PY2

echo
echo "ci-review: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
