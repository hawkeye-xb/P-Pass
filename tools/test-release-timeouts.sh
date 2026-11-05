#!/usr/bin/env bash
# #772：发布链超时的测试。
#   1. tools/release/with-timeout.sh 的行为：正常透传、失败不重试、挂住在上限内被杀并说清步骤名、
#      按次数重试、子进程一并杀掉、stdin（heredoc）照常可用。
#   2. 门禁：release.yml 每个 job 都有 timeout-minutes；bundle-desktop-macos.sh 里 codesign /
#      hdiutil / osascript 的每次调用都经 with-timeout.sh。
#   3. #1438 --retry-on：只对 stderr 命中模式的非 0 退出退避重试，最多 3 次；其它失败第一次就红；
#      门禁：bundle 脚本里 hdiutil create / attach / detach 都带 --retry-on 'Resource busy'。
# 反证锚点：把 with-timeout.sh 的超时分支删掉（只 wait 不 kill）→「挂住」用例超出 10 秒判红；
#   把 --retry-on 的重试分支删掉 →「busy 两次后成功」用例判红。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 失败留证：外层把整次输出 tee 到临时文件；红了就把失败用例名与完整输出存进
# ${PPF_TEST_FAIL_DIR:-<仓库上一级>/.evidence/test-fail}/test-release-timeouts-<时间>.log，
# 只在终端打一行汇总、截断后查不出是哪条的情况不再发生。绿了不留文件；失败日志只留最近 10 份。
if [ -z "${PPF_TEST_INNER:-}" ]; then
  outer_log="$(mktemp "${TMPDIR:-/tmp}/test-release-timeouts.XXXXXX")" || exit 1
  PPF_TEST_INNER=1 bash "$0" "$@" 2>&1 | tee "$outer_log"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    fail_dir="${PPF_TEST_FAIL_DIR:-$(dirname "$ROOT")/.evidence/test-fail}"
    fail_log="${fail_dir}/test-release-timeouts-$(date +%Y%m%d-%H%M%S)-$$.log"
    if mkdir -p "$fail_dir" && cp "$outer_log" "$fail_log"; then
      echo "失败留证：${fail_log}" >&2
      # 清理条件（占盘 1x）：本测试的失败日志只留最近 10 份，更早的删掉；本次这份一定在最近之列。
      ls -t "$fail_dir"/test-release-timeouts-*.log 2>/dev/null | tail -n +11 |
        while IFS= read -r old; do rm -f "$old"; done
    else
      echo "失败留证写不进 ${fail_dir}，完整输出见上" >&2
    fi
  fi
  rm -f "$outer_log"
  exit "$rc"
fi

WT="$ROOT/tools/release/with-timeout.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1" >&2; fails=$((fails + 1)); failed_names="${failed_names}  - ${1%%：*}
"; }
failed_names=""

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

echo "==> with-timeout.sh --retry-on（#1438）"
# 假 hdiutil：前 N 次（计数文件行数 <= N）报 busy 退 1，之后成功。
fake="$TMP/fake-hdiutil"
cat >"$fake" <<'SH'
#!/usr/bin/env bash
# 用法：fake-hdiutil <计数文件> <busy 次数> [其它错误]
echo x >> "$1"
n=$(wc -l < "$1" | tr -d ' ')
if [ -n "${3:-}" ]; then echo "hdiutil: create failed - $3" >&2; exit 1; fi
if [ "$n" -le "$2" ]; then echo "hdiutil: create failed - Resource busy" >&2; exit 1; fi
echo "created: /tmp/fake.dmg"
SH
# 用 bash "$fake" 读脚本，不直接 exec 新建的可执行文件：macOS 对新文件首次 exec 有安全检查，
# 机器忙时能拖过 5 秒上限，假 hdiutil 一次没跑就被判超时（30 次循环里 5 次，失败留证 runs=0、rc=124）。
export PPF_RETRY_DELAYS="0 0 0"
# 发布 runner 是 macOS /bin/bash 3.2 + UTF-8 locale：日志里 $rc 紧挨中文时变量名会吞进多字节首字节，
# set -u 下 unbound variable 直接退出、重试不发生（check-shell-vars.py 文件头的现场）。这里用 UTF-8 跑，
# 本机 macOS 上能复现；Linux bash 5 不复现，那条由 check-shell-vars.py 兜。
utf8_locale="$(locale -a 2>/dev/null | grep -iE '^(en_US|C)\.utf-?8$' | head -1)"
[ -n "$utf8_locale" ] && export LC_ALL="$utf8_locale"

: > "$TMP/count"
out="$("$WT" --retry-on 'Resource busy' "hdiutil create" 5 1 -- bash "$fake" "$TMP/count" 2 2>"$TMP/err")"; rc=$?
runs=$(wc -l < "$TMP/count" | tr -d ' ')
{ [ "$rc" -eq 0 ] && [ "$runs" -eq 3 ] && [ "$out" = "created: /tmp/fake.dmg" ] \
  && [ "$(grep -c '^RETRY: 「hdiutil create」' "$TMP/err")" -eq 2 ] \
  && [ "$(grep -c '^hdiutil: create failed - Resource busy$' "$TMP/err")" -eq 2 ]; } \
  && pass "busy 两次后成功：跑 3 次、退出码 0、hdiutil 的 stderr 原样回放" || fail "busy 两次后成功：rc=$rc runs=$runs err=$(cat "$TMP/err")"

: > "$TMP/count"
"$WT" --retry-on 'Resource busy' "hdiutil create" 5 1 -- bash "$fake" "$TMP/count" 99 2>"$TMP/err" >/dev/null; rc=$?
runs=$(wc -l < "$TMP/count" | tr -d ' ')
{ [ "$rc" -eq 1 ] && [ "$runs" -eq 4 ] && grep -q "「hdiutil create」退出码 1，stderr 命中「Resource busy」，已重试 3 次仍失败" "$TMP/err"; } \
  && pass "一直 busy：重试 3 次（共跑 4 次）后透传退出码 1 并点名步骤" || fail "一直 busy：rc=$rc runs=$runs err=$(cat "$TMP/err")"

: > "$TMP/count"
"$WT" --retry-on 'Resource busy' "hdiutil create" 5 1 -- bash "$fake" "$TMP/count" 0 "No space left on device" 2>"$TMP/err" >/dev/null; rc=$?
runs=$(wc -l < "$TMP/count" | tr -d ' ')
{ [ "$rc" -eq 1 ] && [ "$runs" -eq 1 ] && ! grep -q '^RETRY:' "$TMP/err" && grep -q "No space left on device" "$TMP/err"; } \
  && pass "其它错误（反证）：只跑 1 次、不重试、立即透传" || fail "其它错误：rc=$rc runs=$runs err=$(cat "$TMP/err")"

: > "$TMP/count"
"$WT" "hdiutil create" 5 1 -- bash "$fake" "$TMP/count" 2 2>"$TMP/err" >/dev/null; rc=$?
runs=$(wc -l < "$TMP/count" | tr -d ' ')
{ [ "$rc" -eq 1 ] && [ "$runs" -eq 1 ]; } \
  && pass "不带 --retry-on：busy 也不重试（旧调用行为不变）" || fail "不带 --retry-on：rc=$rc runs=$runs"

start=$(date +%s)
"$WT" --retry-on 'Resource busy' "挂住的 hdiutil" 1 1 -- sleep 30 2>"$TMP/err"; rc=$?
took=$(( $(date +%s) - start ))
{ [ "$rc" -eq 124 ] && [ "$took" -le 10 ] && grep -q "TIMEOUT: 「挂住的 hdiutil」" "$TMP/err"; } \
  && pass "带 --retry-on 时超时仍以 124 退出" || fail "带 --retry-on 超时：rc=$rc took=${took}s err=$(cat "$TMP/err")"

start=$(date +%s); : > "$TMP/count2"
PPF_RETRY_DELAYS="2" "$WT" --retry-on 'Resource busy' "间隔" 5 1 -- bash "$fake" "$TMP/count2" 99 2>"$TMP/err" >/dev/null; rc=$?
took=$(( $(date +%s) - start ))
runs=$(wc -l < "$TMP/count2" | tr -d ' ')
{ [ "$rc" -eq 1 ] && [ "$runs" -eq 2 ] && [ "$took" -ge 2 ] && grep -q "2s 后重试" "$TMP/err"; } \
  && pass "重试间隔按 PPF_RETRY_DELAYS 生效（1 个间隔 = 最多重试 1 次）" || fail "间隔：rc=$rc runs=$runs took=${took}s"
unset PPF_RETRY_DELAYS LC_ALL

default_delays="$(sed -n 's/^retry_delays="\${PPF_RETRY_DELAYS-\(.*\)}"$/\1/p' "$WT")"
[ "$default_delays" = "5 10 20" ] && pass "默认间隔 5 10 20 秒（最多重试 3 次）" || fail "默认间隔：$default_delays"

echo "==> 门禁：bundle-desktop-macos.sh 的 hdiutil create / attach / detach 带 --retry-on 'Resource busy'"
for sub in create attach detach; do
  grep -qE "^\"\\\$WT\" --retry-on 'Resource busy' \"hdiutil ${sub}[^\"]*\" [0-9]+ [0-9]+ -- hdiutil ${sub} " "$ROOT/tools/bundle-desktop-macos.sh" \
    && pass "hdiutil ${sub} 带 --retry-on" || fail "hdiutil ${sub} 没带 --retry-on 'Resource busy'"
done

echo "==> 门禁：release.yml 每个 job 都有 timeout-minutes"
# #1187：调用外部 workflow 的 job（uses: ./.github/workflows/x.yml）GitHub 不许写 timeout-minutes，
# 改为要求被调用 workflow 里的每个 job 都有——超时由它们各自兜住。
missing="$(python3 - "$ROOT/.github/workflows/release.yml" "$ROOT" <<'PY'
import os, sys, yaml
root = sys.argv[2]
jobs = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["jobs"]
miss = []
def walk(prefix, jobs):
    # 被调用的 workflow 里又有 uses 的 job（#1309：ci-rust 的 e2e 调 e2e.yml）同样递归下去
    for k, v in jobs.items():
        uses = v.get("uses")
        name = f"{prefix}{k}"
        if uses and uses.startswith("./"):
            walk(name + "→", yaml.safe_load(open(os.path.join(root, uses.removeprefix("./")), encoding="utf-8"))["jobs"])
        elif "timeout-minutes" not in v:
            miss.append(name)
walk("", jobs)
print(" ".join(miss))
PY
)"; py_rc=$?
if [ "$py_rc" -ne 0 ]; then fail "解析 release.yml 失败（退出码 ${py_rc}），不能判定 timeout-minutes"
elif [ -z "$missing" ]; then pass "全部 job 都有"
else fail "缺 timeout-minutes：$missing"; fi

echo "==> 门禁：bundle-desktop-macos.sh / daemon-helper-macos.sh 的 codesign / hdiutil / osascript 都经 with-timeout"
# 续行（上一行以 \ 结尾）是同一条命令的后半截，不算裸调用。
bare="$(awk '/^[[:space:]]*#/ {cont=0; next}
  !cont && /^[[:space:]]*(codesign|hdiutil|osascript)([[:space:]]|$)/ {print FILENAME":"FNR": "$0}
  {cont = /\\$/}' "$ROOT/tools/bundle-desktop-macos.sh" "$ROOT/tools/daemon-helper-macos.sh")"
[ -z "$bare" ] && pass "没有裸调用" || fail "裸调用：$bare"

if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails 项" >&2
  printf "失败用例：\n${failed_names}" >&2
  exit 1
fi
echo "ok: 发布链超时测试全部通过"
