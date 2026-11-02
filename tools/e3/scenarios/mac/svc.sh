# 冒烟②④（M-svc）：已装 P-Pass 的常驻服务在线；用户停掉服务后 60s 内不被拉起；
# 恢复后强杀（kill -9）30s 内由 launchd 拉起、日志重新「启动就绪」、无 panic。
#
# 作用对象是本机 ~/Applications/P-Pass.app 里**已装的那一版**（版本号写进证据；与候选版本不同时
# judge 会打 INFO，不能当成候选已通过）。整个过程约 2 分钟。开始时服务停着（用户停的）就 SKIP、不替用户拉起；
# 开始时在跑的，结束时一定恢复运行。
# 反证：停服务期间第 10s 由脚本把服务拉回来，「不被拉起」必须判红。
DESC="已装服务在线；停服务不被拉起；强杀自恢复（launchctl + 日志判定）"
COUNTER=off
STOP_WINDOW="${E3_MAC_STOP_WINDOW:-60}"

setup() {
  [ -d "$MAC_APP" ] && [ -f "$MAC_PLIST" ] || { echo "本机没装 P-Pass（$MAC_APP / LaunchAgent）"; return 77; }
  # 尊重用户停掉的服务：没在跑就不替用户拉起，记 SKIP
  if ! svc_loaded || [ -z "$(svc_pid)" ]; then
    echo "跳过：本机服务是停着的（按用户停的处理，不替用户拉起）"
    return 77
  fi
  SVC_WAS_RUNNING=1
}

# run_cycle <是否在停服务期间偷偷拉起 0|1>
run_cycle() {
  local inject="$1" mark p0 p1 p2 i t
  svc_version >"$OUT/installed-version.json"
  "$(cand_daemon)" --version --json >"$OUT/candidate-version.json" 2>/dev/null
  mark=$(log_mark)
  p0=$(svc_pid)
  echo "$p0" >"$OUT/pid-before.txt"
  # 1) 用户停服务：bootout 后每 5s 采样一次进程表
  svc_stop
  : >"$OUT/stop-samples.txt"
  for t in $(seq 5 5 "$STOP_WINDOW"); do
    sleep 5
    [ "$inject" = 1 ] && [ "$t" = 10 ] && svc_start
    echo "t+${t}s pid=$(svc_any_pid)" >>"$OUT/stop-samples.txt"
  done
  # 2) 恢复（相当于用户点「启动后台服务」）
  svc_start
  for i in $(seq 1 30); do p1=$(svc_pid); [ -n "$p1" ] && break; sleep 1; done
  echo "$p1" >"$OUT/pid-restarted.txt"
  wait_ready "$mark"
  log_since "$mark" >"$OUT/daemon-log-restarted.txt"
  mark=$(log_mark)
  # 3) 强杀：launchd 应在 30s 内拉起新进程
  [ -n "$p1" ] && kill -9 "$p1"
  p2=
  for i in $(seq 1 30); do
    p2=$(svc_pid)
    [ -n "$p2" ] && [ "$p2" != "$p1" ] && break
    sleep 1
  done
  echo "$p2" >"$OUT/pid-after-kill.txt"
  echo "$i" >"$OUT/recover-seconds.txt"
  wait_ready "$mark"
  launchctl print "$MAC_DOMAIN/$MAC_LABEL" >"$OUT/launchctl-print.txt" 2>&1
  log_since "$mark" >"$OUT/daemon-log-after-kill.txt"
}

# wait_ready <打点>：等日志里出现打点之后的「启动就绪」（最多 60s；没等到交给 judge 判）
wait_ready() {
  local i
  for i in $(seq 1 60); do
    log_since "$1" | grep -q '启动就绪$' && return 0
    sleep 1
  done
  return 0
}

act() { run_cycle 0; }

new_pid() {
  local a b
  a=$(tr -d '[:space:]' <"$1/pid-restarted.txt" 2>/dev/null)
  b=$(tr -d '[:space:]' <"$1/pid-after-kill.txt" 2>/dev/null)
  [ -n "$b" ] && [ "$a" != "$b" ]
}

no_line_any() { ! cat "$1"/daemon-log-*.txt 2>/dev/null | grep -Eq -- "$2"; }

judge() {
  local d="$1" iv cv
  iv=$(jget "$d/installed-version.json" 'j["version"]')
  cv=$(jget "$d/candidate-version.json" 'j["version"]')
  echo "  INFO  已装版本 ${iv:-?}；候选版本 ${cv:-?}"
  [ "$iv" = "$cv" ] || echo "  INFO  已装的不是候选构建：本场景验的是已装那一版的服务行为"
  check "停服务前在线" [ -n "$(tr -d '[:space:]' <"$d/pid-before.txt" 2>/dev/null)" ]
  check "停服务 ${STOP_WINDOW}s 内一次都没被拉起" no_line "$d/stop-samples.txt" 'pid=[0-9]'
  check "恢复后在线" [ -n "$(tr -d '[:space:]' <"$d/pid-restarted.txt" 2>/dev/null)" ]
  check "强杀后 30s 内换了新进程" new_pid "$d"
  check "launchd 状态 running" has_line "$d/launchctl-print.txt" 'state = running'
  check "恢复后日志「启动就绪」" has_line "$d/daemon-log-restarted.txt" '启动就绪$'
  check "强杀后日志「启动就绪」" has_line "$d/daemon-log-after-kill.txt" '启动就绪$'
  check "日志无 panic" no_line_any "$d" 'panicked|PANIC'
  verdict
}

counter() { run_cycle 1; }

# 只恢复到 setup 前的状态：本场景开始时服务在跑，才保证结束时也在跑
teardown() { [ "${SVC_WAS_RUNNING:-}" = 1 ] && svc_start; return 0; }
