#!/usr/bin/env bash
# #772：发布链超时的测试。
#   1. tools/release/with-timeout.sh 的行为：正常透传、失败不重试、挂住在上限内被杀并说清步骤名、
#      按次数重试、子进程一并杀掉、stdin（heredoc）照常可用。
#   2. 门禁：release.yml 每个 job 都有 timeout-minutes；bundle-desktop-macos.sh 里 codesign /
#      hdiutil / osascript 的每次调用都经 with-timeout.sh。
# 反证锚点：把 with-timeout.sh 的超时分支删掉（只 wait 不 kill）→「挂住」用例超出 10 秒判红。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WT="$ROOT/tools/release/with-timeout.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1" >&2; fails=$((fails + 1)); }

echo "==> with-timeout.sh"

out="$("$WT" "快命令" 5 1 -- echo hi 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = "hi" ]; } && pass "正常结束：退出码 0、输出原样" || fail "正常结束：rc=$rc out=$out"

: > "$TMP/count"
"$WT" "会失败的命令" 5 3 -- bash -c "echo x >> '$TMP/count'; exit 3" 2>"$TMP/err"; rc=$?
runs=$(wc -l < "$TMP/count" | tr -d ' ')
{ [ "$rc" -eq 3 ] && [ "$runs" -eq 1 ] && grep -q "「会失败的命令」退出码 3" "$TMP/err"; } \
  && pass "非零退出：透传 3、不重试（只跑 1 次）、说明步骤名" || fail "非零退出：rc=$rc runs=$runs err=$(cat "$TMP/err")"

start=$(date +%s)
"$WT" "挂住的命令" 2 1 -- sleep 30 2>"$TMP/err"; rc=$?
took=$(( $(date +%s) - start ))
{ [ "$rc" -eq 124 ] && [ "$took" -le 10 ] && grep -q "TIMEOUT: 「挂住的命令」超过 2s 没有返回（第 1/1 次）" "$TMP/err"; } \
  && pass "挂住：${took}s 内以 124 退出并点名步骤" || fail "挂住：rc=$rc took=${took}s err=$(cat "$TMP/err")"

: > "$TMP/count"
"$WT" "一直挂住" 1 2 -- bash -c "echo x >> '$TMP/count'; sleep 30" 2>"$TMP/err"; rc=$?
runs=$(wc -l < "$TMP/count" | tr -d ' ')
{ [ "$rc" -eq 124 ] && [ "$runs" -eq 2 ] && grep -q "第 2/2 次" "$TMP/err"; } \
  && pass "重试：一直挂住时跑满 2 次后 124" || fail "重试：rc=$rc runs=$runs err=$(cat "$TMP/err")"

: > "$TMP/count"
"$WT" "第一次挂住" 1 2 -- bash -c "echo x >> '$TMP/count'; [ \$(wc -l < '$TMP/count') -ge 2 ] || sleep 30" 2>/dev/null; rc=$?
runs=$(wc -l < "$TMP/count" | tr -d ' ')
{ [ "$rc" -eq 0 ] && [ "$runs" -eq 2 ]; } && pass "重试：第二次成功即 0" || fail "重试成功：rc=$rc runs=$runs"

marker="pp-wt-child-$$-$RANDOM"
"$WT" "带子进程挂住" 1 1 -- bash -c "sleep 30 # $marker" 2>/dev/null
sleep 1
if pgrep -f "$marker" >/dev/null; then fail "超时后子进程还活着"; pkill -f "$marker"; else pass "超时后子进程一并被杀"; fi

out="$("$WT" "读 stdin" 5 1 -- cat <<'EOF'
from heredoc
EOF
)"
[ "$out" = "from heredoc" ] && pass "stdin（heredoc）照常喂给命令" || fail "stdin：out=$out"

echo "==> 门禁：release.yml 每个 job 都有 timeout-minutes"
missing="$(python3 - "$ROOT/.github/workflows/release.yml" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
print(" ".join(k for k, v in jobs.items() if "timeout-minutes" not in v))
PY
)"
[ -z "$missing" ] && pass "全部 job 都有" || fail "缺 timeout-minutes：$missing"

echo "==> 门禁：bundle-desktop-macos.sh 的 codesign / hdiutil / osascript 都经 with-timeout"
# 续行（上一行以 \ 结尾）是同一条命令的后半截，不算裸调用。
bare="$(awk '/^[[:space:]]*#/ {cont=0; next}
  !cont && /^[[:space:]]*(codesign|hdiutil|osascript)([[:space:]]|$)/ {print NR": "$0}
  {cont = /\\$/}' "$ROOT/tools/bundle-desktop-macos.sh")"
[ -z "$bare" ] && pass "没有裸调用" || fail "裸调用：$bare"

if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails 项" >&2
  exit 1
fi
echo "ok: 发布链超时测试全部通过"
