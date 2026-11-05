#!/usr/bin/env bash
# just pr-thread / just pr-status（tools/flow/pr-thread.sh、pr-status.sh）的判据测试（#1421）。
#
# gh 是桩：记下每次 graphql 调用的查询与变量，按 $FAKE 下的文件决定成功、失败与返回内容。
# 每条拒绝 / 卡点都配一条只去掉触发条件的放行用例作反证。
#
# 用法: tools/test-flow-pr.sh
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
check() { # check <描述> <命令…>：命令成功记一条通过，否则记失败
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

FAKE="${TMP}/fake"
mkdir -p "$FAKE" "${TMP}/bin"
export FAKE
export PATH="${TMP}/bin:${PATH}"
export PPASS_HOOK_REPO="o/r"

# ── 假 gh：只认 api graphql ───────────────────────────────────────────
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
F="$FAKE"
[ "$1 $2" = "api graphql" ] || { echo "stub gh: unsupported $*" >&2; exit 2; }
shift 2
q="" id="" body="" owner="" name="" n=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f | -F)
      case "$2" in
        query=*) q="${2#query=}" ;;
        id=*) id="${2#id=}" ;;
        body=*) body="${2#body=}" ;;
        owner=*) owner="${2#owner=}" ;;
        name=*) name="${2#name=}" ;;
        n=*) n="${2#n=}" ;;
      esac
      shift 2 ;;
    --jq) shift 2 ;;
    *) shift ;;
  esac
done
case "$q" in
  *addPullRequestReviewThreadReply*)
    echo "reply $id" >>"$F/calls"
    printf '%s' "$q" >"$F/reply.query"
    printf '%s' "$body" >"$F/reply.body"
    [ ! -e "$F/reply_fail" ] || { echo "GraphQL: Resource not accessible by integration" >&2; exit 1; }
    echo "https://github.com/o/r/pull/7#discussion_r1"
    ;;
  *resolveReviewThread*)
    echo "resolve $id" >>"$F/calls"
    [ ! -e "$F/resolve_fail" ] || { echo "GraphQL: resolve denied" >&2; exit 1; }
    cat "$F/resolved" 2>/dev/null || echo true
    ;;
  *pullRequest\(number*)
    echo "status $owner/$name#$n" >>"$F/calls"
    [ ! -e "$F/status_fail" ] || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
    cat "$F/status.json"
    ;;
  *) echo "stub gh: unknown query" >&2; exit 2 ;;
esac
STUB
chmod +x "${TMP}/bin/gh" || {
  printf '%s\n' "无法让假 gh 可执行，终止测试（否则会调到本机真 gh）" >&2
  exit 1
}

reset() { rm -f "$FAKE"/*; }
calls() { cat "$FAKE/calls" 2>/dev/null; }

THREAD="${SRC}/tools/flow/pr-thread.sh"
STATUS="${SRC}/tools/flow/pr-status.sh"

# 跑命令，记下退出码、stdout、stderr
run() {
  "$@" >"${TMP}/out" 2>"${TMP}/err"
  RC=$?
}
out_has() { grep -qF -- "$1" "${TMP}/out"; }
err_has() { grep -qF -- "$1" "${TMP}/err"; }

echo "== just pr-thread"

reset
BODY='已改：引号 " 与 } 不会破坏查询
第二行 $(rm -rf /) 原样传'
run bash "$THREAD" PRRT_abc "$BODY"
check "回复 + 关闭：退出 0" [ "$RC" = 0 ]
check "先回复后关闭，线程 ID 原样传" [ "$(calls)" = "$(printf 'reply PRRT_abc\nresolve PRRT_abc')" ]
check "回复正文逐字传入（含引号、花括号、换行）" [ "$(cat "$FAKE/reply.body")" = "$BODY" ]
check "回复正文走变量，不拼进查询字符串" bash -c '! grep -qF "破坏查询" "$1"' _ "$FAKE/reply.query"
check "输出回复链接与已关闭" bash -c 'grep -qF "discussion_r1" "$1" && grep -qF "已关闭线程 PRRT_abc" "$1"' _ "${TMP}/out"

reset
run bash "$THREAD" PRRT_abc "   "
check "拒绝：空回复 → 退出 2，不调 gh" bash -c '[ "$1" = 2 ] && [ ! -e "$2" ]' _ "$RC" "$FAKE/calls"

reset
run bash "$THREAD" IC_kwDO123 "理由"
check "拒绝：不是 PRRT_ 开头的 ID → 退出 2，不调 gh" bash -c '[ "$1" = 2 ] && [ ! -e "$2" ]' _ "$RC" "$FAKE/calls"
check "拒绝提示说明线程 ID 的形状" err_has "PRRT_"

reset
run bash "$THREAD" PRRT_abc
check "拒绝：缺回复参数 → 退出 2" [ "$RC" = 2 ]

reset
touch "$FAKE/reply_fail"
run bash "$THREAD" PRRT_abc "理由"
check "回复失败 → 退出 1，不再关闭" bash -c '[ "$1" = 1 ] && [ "$(cat "$2")" = "reply PRRT_abc" ]' _ "$RC" "$FAKE/calls"
check "回复失败带 gh 原文" err_has "Resource not accessible by integration"

reset
touch "$FAKE/resolve_fail"
run bash "$THREAD" PRRT_abc "理由"
check "关闭失败 → 退出 1" [ "$RC" = 1 ]
check "关闭失败说明回复已发出、给只关闭的重试命令" bash -c 'grep -qF "已发出" "$1" && grep -qF -- "--resolve-only PRRT_abc" "$1" && grep -qF "resolve denied" "$1"' _ "${TMP}/err"

reset
printf 'false\n' >"$FAKE/resolved"
run bash "$THREAD" PRRT_abc "理由"
check "GitHub 回报没关上 → 退出 1" [ "$RC" = 1 ]

reset
run bash "$THREAD" --resolve-only PRRT_abc
check "--resolve-only：只关闭、不回复，退出 0" bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "resolve PRRT_abc" ]' _ "$RC" "$FAKE/calls"

echo "== just pr-status"

# 造 PR 状态：mk <选项…>，默认是全清的 OPEN PR
mk() {
  python3 -I -X utf8 - "$@" >"$FAKE/status.json" <<'PY'
import json, sys
opts = dict(a.split("=", 1) for a in sys.argv[1:])
checks = [{"__typename": "CheckRun", "name": "CI gate", "status": "COMPLETED", "conclusion": "SUCCESS", "detailsUrl": "u1"},
          {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "SKIPPED", "detailsUrl": "u2"},
          {"__typename": "StatusContext", "context": "review/agent", "state": "SUCCESS", "targetUrl": ""}]
if opts.get("check") == "fail":
    checks[0]["conclusion"] = "FAILURE"
if opts.get("check") == "cancel":
    checks[0]["conclusion"] = "CANCELLED"
if opts.get("check") == "run":
    checks[0]["status"] = "IN_PROGRESS"; checks[0]["conclusion"] = None
if opts.get("status") == "fail":
    checks[2]["state"] = "FAILURE"
threads = [{"id": "PRRT_done", "isResolved": True, "isOutdated": False, "path": "a.sh", "line": 3, "originalLine": 3,
            "comments": {"nodes": [{"author": {"login": "coderabbitai"}, "body": "**Done thread**"}]}}]
if opts.get("thread") == "open":
    threads.append({"id": "PRRT_open", "isResolved": False, "isOutdated": True, "path": "tools/x.sh", "line": None, "originalLine": 42,
                    "comments": {"nodes": [{"author": {"login": "coderabbitai"}, "body":
                        "<!-- coderabbit-ai-generated:v1 -->\n\n**<picture><img src=\"x.svg\"></picture> Major** · **Functional Correctness**\n\n**`teardown` 不恢复后台服务。**\n\n细节……"}]}})
pr = {"number": 7, "title": "T", "url": "https://github.com/o/r/pull/7", "state": opts.get("state", "OPEN"), "isDraft": False,
      "mergeable": opts.get("mergeable", "MERGEABLE"), "mergeStateStatus": opts.get("mss", "CLEAN"),
      "autoMergeRequest": {"mergeMethod": "SQUASH"} if opts.get("auto") == "on" else None,
      "commits": {"nodes": [{"commit": {"oid": "abc", "statusCheckRollup": {"contexts": {"pageInfo": {"hasNextPage": opts.get("more") == "checks"}, "nodes": checks}}}}]},
      "reviewThreads": {"pageInfo": {"hasNextPage": opts.get("more") == "threads"}, "nodes": threads}}
print(json.dumps({"data": {"repository": {"pullRequest": pr}}}))
PY
}

reset; mk
run bash "$STATUS" 7
check "全清 → 退出 0（SKIPPED 不算失败，已解决线程不列）" bash -c '[ "$1" = 0 ] && grep -qF "全清" "$2" && ! grep -qF "PRRT_done" "$2"' _ "$RC" "${TMP}/out"
check "查的是 PPASS_HOOK_REPO 的仓库与 PR 号" [ "$(calls)" = "status o/r#7" ]
check "自动合入没开时写「没开」" out_has "自动合入：没开"

reset; mk check=fail
run bash "$STATUS" 7
check "CheckRun 失败 → 退出 1，列出检查名与链接" bash -c '[ "$1" = 1 ] && grep -qF "✗ CI gate（FAILURE）u1" "$2"' _ "$RC" "${TMP}/out"

reset; mk check=cancel
run bash "$STATUS" 7
check "CheckRun 被取消也算没过 → 退出 1" [ "$RC" = 1 ]

reset; mk status=fail
run bash "$STATUS" 7
check "StatusContext 失败 → 退出 1" bash -c '[ "$1" = 1 ] && grep -qF "review/agent（FAILURE）" "$2"' _ "$RC" "${TMP}/out"

reset; mk check=run
run bash "$STATUS" 7
check "检查还在跑 → 退出 3，不算全清" bash -c '[ "$1" = 3 ] && grep -qF "… CI gate" "$2" && ! grep -qF "全清" "$2"' _ "$RC" "${TMP}/out"

reset; mk thread=open
run bash "$STATUS" 7
check "未解决线程 → 退出 1" [ "$RC" = 1 ]
check "线程行：ID、文件:原行号（line 为空时）、作者、级别、已过时" out_has "PRRT_open  tools/x.sh:42  @coderabbitai  [Major，已过时]"
check "线程要点取加粗标题，去掉徽章与 HTML" out_has "teardown 不恢复后台服务。"
check "提示用 just pr-thread 关闭" out_has "just pr-thread"

reset; mk mss=DIRTY mergeable=CONFLICTING
run bash "$STATUS" 7
check "冲突 → 退出 1" bash -c '[ "$1" = 1 ] && grep -qF "冲突：有" "$2"' _ "$RC" "${TMP}/out"

reset; mk mergeable=UNKNOWN mss=UNKNOWN
run bash "$STATUS" 7
check "冲突未知 → 退出 3，不当成无冲突" bash -c '[ "$1" = 3 ] && grep -qF "冲突：未知" "$2"' _ "$RC" "${TMP}/out"

reset; mk more=threads
run bash "$STATUS" 7
check "评审线程超过 100 条没读全 → 退出 3，不报全清" bash -c '[ "$1" = 3 ] && ! grep -qF "全清" "$2" && grep -qF "结果不完整" "$2"' _ "$RC" "${TMP}/out"

reset; mk more=checks
run bash "$STATUS" 7
check "检查超过 100 个没读全 → 退出 3，不报全清" bash -c '[ "$1" = 3 ] && ! grep -qF "全清" "$2"' _ "$RC" "${TMP}/out"

reset; mk auto=on
run bash "$STATUS" 7
check "自动合入已开时写明合并方式" out_has "自动合入：已开（SQUASH）"

reset; mk state=MERGED check=fail
run bash "$STATUS" 7
check "已合入 → 退出 0" bash -c '[ "$1" = 0 ] && grep -qF "已合入" "$2"' _ "$RC" "${TMP}/out"

reset; mk; touch "$FAKE/status_fail"
run bash "$STATUS" 7
check "gh 读失败 → 退出 2，带 gh 原文" bash -c '[ "$1" = 2 ] && grep -qF "Bad credentials" "$2"' _ "$RC" "${TMP}/err"

reset
run bash "$STATUS" abc
check "拒绝：PR 号不是数字 → 退出 2，不调 gh" bash -c '[ "$1" = 2 ] && [ ! -e "$2" ]' _ "$RC" "$FAKE/calls"

echo
echo "pr-thread / pr-status：${PASS} 过，${FAIL} 失败"
[ "$FAIL" = 0 ]
