# #1300：服务被停着时打开窗口，窗口不许把它拉起（尊重用户停掉的服务）。
#
# 时序：退出窗口 → launchctl bootout 停服务（「在外面停掉」，登记文件留着）→ 等 5s → 打开窗口 →
# 60s 内每 2s 采样常驻 daemon 进程。触发条件是「窗口启动对账探测内核在不在线的那一刻服务是停着的」，
# 先停后开是确定性的；「开窗口后几秒内停」是同一机制的竞态版，不拿来判定。
# 作用对象是本机已装的那一版（与 mac/svc 相同：已装 daemon 是签名 socket，只用 launchctl、进程表、
# desktop.log 与窗口程序的 stderr 判定）。开始时服务停着就 SKIP；结束时恢复服务、窗口按开始时的样子。
# 反证：开窗口后第 10s 由脚本把服务拉回来，「不被拉起」「stopped outside 之后没回到 running」必须判红。
DESC="服务停着时打开窗口：60s 内不被拉起、窗口停在已停止（launchctl + desktop.log 判定）"
COUNTER=off
source "$E3_LIB/mac-install.sh"
OPEN_WINDOW="${E3_MAC_OPEN_WINDOW:-60}"
MAC_DESKTOP_LOG="$HOME/Library/Application Support/P-Pass/logs/desktop.log"

setup() {
  [ -d "$MAC_APP" ] && [ -f "$MAC_PLIST" ] || { echo "本机没装 P-Pass（$MAC_APP / LaunchAgent）"; return 77; }
  if ! svc_loaded || [ -z "$(svc_pid)" ]; then
    echo "跳过：本机服务是停着的（按用户停的处理，不替用户拉起）"
    return 77
  fi
  SVC_WAS_RUNNING=1
  mac_shell_running && SHELL_WAS_OPEN=1
  return 0
}

# open_cycle <是否在第 10s 偷偷拉起 0|1>
open_cycle() {
  local inject="$1" lines t p
  svc_version >"$OUT/installed-version.json"
  svc_pid >"$OUT/pid-before.txt"
  mac_quit_shell
  mac_shell_running && echo "窗口没退掉" >"$OUT/shell-not-quit.txt"
  svc_stop
  sleep 5
  svc_any_pid >"$OUT/pid-before-open.txt"
  lines=$(wc -l <"$MAC_DESKTOP_LOG" 2>/dev/null || echo 0)
  open --stdout "$OUT/shell.out" --stderr "$OUT/shell.err" "$MAC_APP"
  : >"$OUT/open-samples.txt"
  for t in $(seq 2 2 "$OPEN_WINDOW"); do
    sleep 2
    [ "$inject" = 1 ] && [ "$t" = 10 ] && svc_start
    p=$(svc_any_pid)
    echo "t+${t}s pid=${p}$( [ -n "$p" ] && echo " parent=$(ps -o comm= -p "$(ps -o ppid= -p "$p")" 2>/dev/null)")" >>"$OUT/open-samples.txt"
  done
  pgrep -f "^$MAC_SHELL_EXE( |$)" >"$OUT/shell-pid.txt"
  tail -n +"$((lines + 1))" "$MAC_DESKTOP_LOG" >"$OUT/desktop-log.txt" 2>/dev/null
}

act() { open_cycle 0; }
counter() { open_cycle 1; }

# 窗口这一次启动后：落到「stopped outside」，且那之后没有再翻回 running
stays_stopped() {
  awk '/event=state .*reason=stopped outside/ {s = 1} s && /event=state .*to=running/ {bad = 1} END {exit !(s && !bad)}' "$1/desktop-log.txt"
}

judge() {
  local d="$1"
  echo "  INFO  已装版本 $(jget "$d/installed-version.json" 'j["version"]')"
  [ -s "$d/shell.err" ] && sed 's/^/  INFO  窗口 stderr: /' "$d/shell.err" | head -8
  check "停服务前在线" [ -n "$(tr -d '[:space:]' <"$d/pid-before.txt" 2>/dev/null)" ]
  check "开窗口前窗口已退出" [ ! -f "$d/shell-not-quit.txt" ]
  check "开窗口前服务确实停着" [ -z "$(tr -d '[:space:]' <"$d/pid-before-open.txt" 2>/dev/null)" ]
  check "窗口打开了" [ -n "$(tr -d '[:space:]' <"$d/shell-pid.txt" 2>/dev/null)" ]
  check "开窗口后 ${OPEN_WINDOW}s 内一次都没被拉起" no_line "$d/open-samples.txt" 'pid=[0-9]'
  check "窗口落在「stopped outside」且之后没回到 running" stays_stopped "$d"
  verdict
}

teardown() {
  [ "${SVC_WAS_RUNNING:-}" = 1 ] && svc_start
  if [ "${SHELL_WAS_OPEN:-}" = 1 ]; then mac_shell_running || open "$MAC_APP"; else mac_quit_shell; fi
  return 0
}
