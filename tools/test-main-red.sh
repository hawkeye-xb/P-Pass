#!/usr/bin/env bash
# tools/flow/main-red.sh 的判据测试（#1469）：假 gh（api 返回预置 JSON 并真跑 --jq），每条判据配反证。
#
# 用法: tools/test-main-red.sh
# 退出码: 0 全过 / 1 有失败

set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { printf '  ✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

FAKE="${TMP}/fake"
mkdir -p "$FAKE" "${TMP}/bin"
export FAKE
export PATH="${TMP}/bin:${PATH}"

# ── 假 gh ────────────────────────────────────────────────────────────
# api <路径>：按路径取 $FAKE 下的 JSON，有 --jq 就真跑 jq；issue list/create/comment/close 记到 $FAKE/calls，
# 「开着的卡」由 $FAKE/issues.json 给（issue create 会往里加一条，模拟真实状态）。
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
F="$FAKE"
echo "$*" >>"$F/calls"
emit() { # emit <文件> <jq 表达式或空>
  if [ -n "$2" ]; then jq -r "$2" "$1"; else cat "$1"; fi
}
jqx=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[i]}" = "--jq" ] && jqx="${args[i + 1]}"
done
case "$1 $2" in
  "api repos/"*)
    p="$2"
    case "$p" in
      */actions/runs/*/jobs*) emit "$F/jobs.json" "$jqx" ;;
      */actions/runs/*) emit "$F/run.json" "$jqx" ;;
      */actions/workflows/*/runs*) emit "$F/wfruns.json" "$jqx" ;;
      */compare/*) emit "$F/compare.json" "$jqx" ;;
      */commits\?*) emit "$F/commits.json" "$jqx" ;;
      *) echo "stub gh: unsupported $p" >&2; exit 2 ;;
    esac ;;
  "run rerun"*)
    if [ "${FAKE_RERUN_FAIL:-0}" = "1" ]; then
      echo "stub gh: rerun failed" >&2
      exit 1
    fi
    printf '%s\n' "$@" >"$F/rerun.args" ;;
  "issue list") emit "$F/issues.json" "$jqx" ;;
  "issue create")
    n=900
    jq --argjson n "$n" --arg t "$(printf '%s\n' "$@" | awk 'p{print;exit} $0=="--title"{p=1}')" \
      '. + [{number:$n,title:$t}]' "$F/issues.json" >"$F/issues.tmp" && mv "$F/issues.tmp" "$F/issues.json"
    printf '%s\n' "$@" >"$F/create.args" ;;
  "issue comment") printf '%s\n' "$@" >>"$F/comment.args" ;;
  "issue close") : ;;
  *) echo "stub gh: unsupported $*" >&2; exit 2 ;;
esac
STUB
chmod +x "${TMP}/bin/gh"

reset() {
  rm -f "$FAKE"/*
  echo '[]' >"$FAKE/issues.json"
  cat >"$FAKE/run.json" <<'J'
{"head_sha":"bbbbbbbb2222222222222222222222222222222222","html_url":"https://x/run/77","created_at":"2026-11-06T10:00:00Z","workflow_id":5,"run_attempt":1}
J
  cat >"$FAKE/wfruns.json" <<'J'
{"workflow_runs":[
 {"created_at":"2026-11-06T08:00:00Z","head_sha":"eeeeeeee0000000000000000000000000000000000"},
 {"created_at":"2026-11-06T09:00:00Z","head_sha":"aaaaaaaa1111111111111111111111111111111111"},
 {"created_at":"2026-11-06T11:00:00Z","head_sha":"ffffffff9999999999999999999999999999999999"}]}
J
  cat >"$FAKE/compare.json" <<'J'
{"commits":[
 {"sha":"c1c1c1c1c1","commit":{"message":"feat: 第一个 (#101)\n\n正文"}},
 {"sha":"c2c2c2c2c2","commit":{"message":"fix: 第二个 (#102)"}},
 {"sha":"c3c3c3c3c3","commit":{"message":"chore: 直接推的没有 PR 号"}}]}
J
  cat >"$FAKE/commits.json" <<'J'
[{"sha":"d1d1d1d1d1","commit":{"message":"feat: 近期一 (#201)"}},
 {"sha":"d2d2d2d2d2","commit":{"message":"feat: 近期二 (#202)"}}]
J
  cat >"$FAKE/jobs.json" <<'J'
{"jobs":[{"name":"lint","conclusion":"failure","html_url":"https://x/job/1","steps":[{"name":"Set up job","status":"completed","conclusion":"success"},{"name":"Clippy","status":"completed","conclusion":"failure"}]},{"name":"test","conclusion":"success","html_url":"https://x/job/2","steps":[{"name":"Test","status":"completed","conclusion":"success"}]}]}
J
}

run() { # run <conclusion> [脚本路径]；输出到 $FAKE/out
  REPO=o/r RUN_ID=77 WORKFLOW="CI Rust" CONCLUSION="$1" BRANCH="${BRANCH:-main}" EVENT="${EVENT:-push}" \
    bash "${2:-$SRC/tools/flow/main-red.sh}" >"$FAKE/out" 2>&1
}

echo "── 红 → 开卡 ──"
reset
run failure
check "开卡一次，标题固定、带 P0" bash -c "grep -qx '\[MAIN-RED\] CI Rust' '$FAKE/create.args' && grep -qx 'P0' '$FAKE/create.args'"
check "列出区间内的 PR（#101 #102）" bash -c "grep -q '#101' '$FAKE/create.args' && grep -q '#102' '$FAKE/create.args'"
check "区间外的 PR 不列" bash -c "! grep -q '#201' '$FAKE/create.args'"
check "无 PR 号的提交也列出" bash -c "grep -q '无 PR 号' '$FAKE/create.args'"
check "只取早于本次的最近一次绿（不取晚于本次的）" bash -c "grep -q 'compare/aaaaaaaa1111' '$FAKE/calls' && ! grep -q 'ffffffff' '$FAKE/calls' && ! grep -q 'eeeeeeee' '$FAKE/calls'"
check "带失败 job 链接且不列成功 job" bash -c "grep -q 'https://x/job/1' '$FAKE/create.args' && ! grep -q 'https://x/job/2' '$FAKE/create.args'"
check "写明处理口径（往前修 / 回滚）" bash -c "grep -q '回滚元凶' '$FAKE/create.args' && grep -q '不冻结' '$FAKE/create.args'"

echo "── 再红 → 追加评论，不重复开 ──"
: >"$FAKE/calls"
rm -f "$FAKE/create.args"
run failure
check "没有第二次 issue create" bash -c "[ ! -f '$FAKE/create.args' ]"
check "追加了评论到 #900" bash -c "grep -qx '900' '$FAKE/comment.args'"
# 反证：去掉去重判定（找卡永远返回空）→ 同样的输入会重复开卡
sed 's|^existing="\$(find_open_issue)"|existing=""|' "$SRC/tools/flow/main-red.sh" >"$TMP/no-dedup.sh"
cmp -s "$TMP/no-dedup.sh" "$SRC/tools/flow/main-red.sh" && bad "反证准备失败：sed 没改动脚本"
rm -f "$FAKE/create.args"
run failure "$TMP/no-dedup.sh"
check "反证：去掉去重后「再红」会重复开卡（用例变红）" bash -c "[ -f '$FAKE/create.args' ]"

echo "── 转绿 → 关卡 ──"
reset
echo '[{"number":321,"title":"[MAIN-RED] CI Rust"}]' >"$FAKE/issues.json"
run success
check "评论并关闭 #321" bash -c "grep -q 'issue close 321' '$FAKE/calls' && grep -qx '321' '$FAKE/comment.args'"
reset
echo '[{"number":321,"title":"[MAIN-RED] CI Desktop"}]' >"$FAKE/issues.json"
run success
check "反证：别的 workflow 的卡不动" bash -c "! grep -q 'issue close' '$FAKE/calls'"
reset
run success
check "反证：没有开着的卡时绿了无事发生" bash -c "! grep -q 'issue close\|issue create' '$FAKE/calls'"

echo "── 读不到上次绿 ──"
reset
echo '{}' >"$FAKE/wfruns.json"   # jq 取不出 workflow_runs → 查询失败
run failure
check "查询上次绿失败也开卡（回退到最近提交）" bash -c "grep -q '无法确定区间' '$FAKE/create.args'"
reset
echo '{"workflow_runs":[]}' >"$FAKE/wfruns.json"
run failure
check "改列最近提交并写明无法确定区间" bash -c "grep -q '#201' '$FAKE/create.args' && grep -q '无法确定区间' '$FAKE/create.args'"
reset
run failure
check "反证：有上次绿时正文不含「无法确定区间」" bash -c "! grep -q '无法确定区间' '$FAKE/create.args'"

echo "── 其余读取失败也要开卡 ──"
reset
echo '{}' >"$FAKE/compare.json"
run failure
check "compare 读失败：回退到最近提交并开卡" bash -c "grep -q '#201' '$FAKE/create.args' && grep -q '无法确定区间' '$FAKE/create.args'"
reset
echo '{}' >"$FAKE/jobs.json"
run failure
check "失败 job 读失败：开卡并写兜底文案" bash -c "grep -q '没读到失败 job' '$FAKE/create.args' && grep -q '#101' '$FAKE/create.args'"

echo "── 不该处理的 run ──"
reset
BRANCH=feature run failure
check "非 main 分支：不开卡" bash -c "! grep -q 'issue create' '$FAKE/calls' 2>/dev/null"
reset
EVENT=pull_request run failure
check "非 push 触发：不开卡" bash -c "! grep -q 'issue create' '$FAKE/calls' 2>/dev/null"
reset
run cancelled
check "cancelled：不开卡也不关卡" bash -c "! grep -q 'issue create\|issue close' '$FAKE/calls' 2>/dev/null"
reset
echo '[{"number":321,"title":"[MAIN-RED] CI Rust"}]' >"$FAKE/issues.json"
run cancelled
check "cancelled（被并发组替掉的 run）：已有开着的卡也不关、不追加评论" bash -c "! grep -q 'issue close\|issue comment' '$FAKE/calls' && [ ! -f '$FAKE/comment.args' ]"
reset
echo '[{"number":321,"title":"[MAIN-RED] CI Rust"}]' >"$FAKE/issues.json"
run success
check "反证：同样的开着的卡，success 才关" bash -c "grep -q 'issue close 321' '$FAKE/calls'"
reset
run timed_out
check "反证：timed_out 算红，开卡" bash -c "grep -q 'issue create' '$FAKE/calls'"

echo "── 云端 runner 排队掉线（0 步未执行）自动重跑一次 ──"
# 正例 1a：直接单 job 0 步掉线（steps 为空，run_attempt=1）
reset
cat >"$FAKE/jobs.json" <<'J'
{"jobs":[
  {"name":"test","conclusion":"success","html_url":"https://x/job/1","steps":[{"name":"Test","status":"completed","conclusion":"success"}]},
  {"name":"macos-job","conclusion":"failure","html_url":"https://x/job/2","steps":[]}
]}
J
run failure
check "run_attempt=1 且失败 job steps 为空：触发 gh run rerun 77 --failed，不开 P0 卡" \
  bash -c "[ -f '$FAKE/rerun.args' ] && grep -qx '77' '$FAKE/rerun.args' && grep -qx -- '--failed' '$FAKE/rerun.args' && [ ! -f '$FAKE/create.args' ] && ! grep -q 'issue create\|issue comment' '$FAKE/calls'"

# 正例 1b：上游 macOS job cancelled + steps=[]，末尾 CI * gate 汇总步判 failure
reset
echo '[{"number":321,"title":"[MAIN-RED] CI Rust"}]' >"$FAKE/issues.json"
cat >"$FAKE/jobs.json" <<'J'
{"jobs":[
  {"name":"changes (要不要跑 Rust 重型门禁)","conclusion":"success","html_url":"https://x/job/1","steps":[{"name":"Set up job","status":"completed","conclusion":"success"}]},
  {"name":"test (platform, macos)","conclusion":"cancelled","html_url":"https://x/job/2","steps":[]},
  {"name":"CI Rust gate","conclusion":"failure","html_url":"https://x/job/3","steps":[
    {"name":"Set up job","status":"completed","conclusion":"success"},
    {"name":"汇总上游结论","status":"completed","conclusion":"failure"}
  ]}
]}
J
run failure
check "run_attempt=1 且仅上游 runner 0 步掉线 + gate 汇总红：触发重跑，不开卡也不追加已有卡评论" \
  bash -c "[ -f '$FAKE/rerun.args' ] && grep -qx '77' '$FAKE/rerun.args' && grep -qx -- '--failed' '$FAKE/rerun.args' && [ ! -f '$FAKE/create.args' ] && [ ! -f '$FAKE/comment.args' ]"

# 正例 1c：失败 job 仅有 skipped/queued 步（未真正跑任何步骤），run_attempt=1 → 触发重跑
reset
cat >"$FAKE/jobs.json" <<'J'
{"jobs":[
  {"name":"ios (xcodegen + xcodebuild test)","conclusion":"failure","html_url":"https://x/job/2","steps":[
    {"name":"Set up job","status":"queued","conclusion":null},
    {"name":"Checkout","status":"skipped","conclusion":"skipped"}
  ]}
]}
J
run failure
check "run_attempt=1 且失败 job 仅有 queued/skipped 步：触发重跑且不开卡" \
  bash -c "[ -f '$FAKE/rerun.args' ] && [ ! -f '$FAKE/create.args' ]"

# 反例 2a：run_attempt >= 2 仍然 0 步掉线 → 不再无限重跑，立即开 P0 卡
reset
jq '.run_attempt = 2' "$FAKE/run.json" >"$FAKE/run.tmp" && mv "$FAKE/run.tmp" "$FAKE/run.json"
cat >"$FAKE/jobs.json" <<'J'
{"jobs":[
  {"name":"test (platform, macos)","conclusion":"cancelled","html_url":"https://x/job/2","steps":[]},
  {"name":"CI Rust gate","conclusion":"failure","html_url":"https://x/job/3","steps":[
    {"name":"汇总上游结论","status":"completed","conclusion":"failure"}
  ]}
]}
J
run failure
check "反证：run_attempt=2 仍 0 步掉线时不再重跑，立即开 [MAIN-RED] P0 卡" \
  bash -c "[ ! -f '$FAKE/rerun.args' ] && [ -f '$FAKE/create.args' ] && grep -qx '\[MAIN-RED\] CI Rust' '$FAKE/create.args' && grep -q 'https://x/job/2' '$FAKE/create.args'"

# 反例 2b：run_attempt=1 但既有 0 步掉线 job，又有真实步骤失败的业务 job → 不得重跑掩盖，立即开 P0 卡
reset
cat >"$FAKE/jobs.json" <<'J'
{"jobs":[
  {"name":"test (platform, macos)","conclusion":"cancelled","html_url":"https://x/job/2","steps":[]},
  {"name":"test (windows)","conclusion":"failure","html_url":"https://x/job/4","steps":[
    {"name":"Set up job","status":"completed","conclusion":"success"},
    {"name":"Test (nextest)","status":"completed","conclusion":"failure"}
  ]},
  {"name":"CI Rust gate","conclusion":"failure","html_url":"https://x/job/3","steps":[
    {"name":"汇总上游结论","status":"completed","conclusion":"failure"}
  ]}
]}
J
run failure
check "反证：run_attempt=1 但混合真实步骤失败 job 时不重跑，立即开 [MAIN-RED] P0 卡" \
  bash -c "[ ! -f '$FAKE/rerun.args' ] && [ -f '$FAKE/create.args' ] && grep -q 'https://x/job/4' '$FAKE/create.args'"

# 反例 2c：已开始执行业务步骤后中途中断（前序步 success、当前步 in_progress/null）→ 不算 0 步掉线，立即开 P0 卡
reset
cat >"$FAKE/jobs.json" <<'J'
{"jobs":[
  {"name":"ios (xcodegen + xcodebuild test)","conclusion":"timed_out","html_url":"https://x/job/5","steps":[
    {"name":"Set up job","status":"completed","conclusion":"success"},
    {"name":"App unit tests","status":"in_progress","conclusion":null}
  ]}
]}
J
run timed_out
check "反证：已执行步骤后中途超时（conclusion=null）不误判为掉线，立即开 [MAIN-RED] P0 卡" \
  bash -c "[ ! -f '$FAKE/rerun.args' ] && [ -f '$FAKE/create.args' ] && grep -q 'https://x/job/5' '$FAKE/create.args'"

# 反例 2d：run_attempt=1 且 0 步掉线，但 gh run rerun 失败（如权限不足）→ 降级照常开 P0 卡，绝不吞掉告警
reset
cat >"$FAKE/jobs.json" <<'J'
{"jobs":[{"name":"macos-job","conclusion":"failure","html_url":"https://x/job/2","steps":[]}]}
J
FAKE_RERUN_FAIL=1 run failure
check "反证：gh run rerun 失败时降级开 [MAIN-RED] P0 卡，不静默漏报" \
  bash -c "[ -f '$FAKE/create.args' ] && grep -qx '\[MAIN-RED\] CI Rust' '$FAKE/create.args'"

echo
printf '通过 %d / 失败 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
