# W1：安装/启动/看门狗自愈/停服务过程中不闪控制台窗口。
#
# 本轮用 watch-new-windows.ps1（5ms 轮询可见顶层窗口）盯：启动 App（若没开）、强杀 daemon
# 让看门狗/壳自愈、停止后台服务、恢复。安装器与 R1.6 应用内更新是安装器路径（UAC），
# 非提权会话覆盖不到，报告里单列。
# 反证：同一窗口期内开一个可见控制台（cmd start timeout），watcher 必须报 ConsoleWindowClass、
# 退出码 1。
DESC="W1：启动/自愈/停启服务不闪控制台窗口（安装器与更新路径见报告）"
COUNTER=on
WATCH="${E3_WIN_W1_SECONDS:-75}"

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

watcher_no_console() { [ -s "$1" ] && no_line "$1" 'CONSOLE'; }

run_window() { # run_window <证据目录> <故障注入 0|1> <秒>
  local d="$1" fault="$2" secs="$3" rc=0
  mkdir -p "$d"
  win_watch_start "$d/watcher.log" "$secs"
  if [ "$fault" = 1 ]; then
    # 可见控制台：start 会新建一个窗口，watcher 应把它抓成 CONSOLE。
    win_ps "Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = 'cmd.exe /c start \"\" cmd.exe /c \"timeout /t 3\"' } | Out-Null" >/dev/null 2>&1 || true
    sleep 4
  else
    : >"$d/actions.txt"
    # W1 要真的看一次 App 启动窗口：setup 已确保在跑，先停再起。
    win_stop_app >/dev/null 2>&1 || true
    sleep 2
    if win_start_app >/dev/null 2>&1; then echo "start=ok" >>"$d/actions.txt"; else echo "start=fail" >>"$d/actions.txt"; fi
    sleep 3
    # 强杀 daemon：壳开着时壳自愈，壳没开时计划任务 1 分钟内拉起。
    local pid_before pid_after
    pid_before="$(win_daemon_pid)"
    if [ -n "$pid_before" ] && win_kill_daemon >/dev/null 2>&1; then
      echo "kill=ok" >>"$d/actions.txt"
    else
      echo "kill=fail" >>"$d/actions.txt"
    fi
    sleep 12
    pid_after="$(win_daemon_pid)"
    if [ -n "$pid_after" ] && [ "$pid_after" != "$pid_before" ]; then
      echo "recover=ok" >>"$d/actions.txt"
    else
      echo "recover=fail" >>"$d/actions.txt"
    fi
    # 停服务 → 恢复；点击/确认/状态都要真的发生，否则 W1 的窗口期没覆盖到这些动作。
    desktop_click() { win_ui_click "$1" >/dev/null || return 1; sleep 1; }
    if desktop_click '设置' && win_ui_click '停止后台服务' >/dev/null; then
      sleep 2
      win_ui_dump "$d/stop-dialog.txt" || true
      if win_ui_has "$d/stop-dialog.txt" '确定停止'; then win_ui_dialog_click '确定' >/dev/null 2>&1 || true; fi
      sleep 8
      if win_daemon_running; then echo "stop=fail" >>"$d/actions.txt"; else echo "stop=ok" >>"$d/actions.txt"; fi
    else
      echo "stop=fail" >>"$d/actions.txt"
    fi
    if desktop_click '总览'; then
      win_ui_dump "$d/restore.txt" || true
      if win_ui_has "$d/restore.txt" '启动后台服务'; then win_ui_click '启动后台服务' >/dev/null 2>&1 || true; fi
      local j
      for j in $(seq 1 30); do win_daemon_running && break; sleep 1; done
      if win_daemon_running; then echo "restore=ok" >>"$d/actions.txt"; else echo "restore=fail" >>"$d/actions.txt"; fi
    else
      echo "restore=fail" >>"$d/actions.txt"
    fi
    sleep 10
  fi
  # watcher 必须还活着覆盖到全部动作结束；提前退出 = 尾部动作没被盯到。
  if [ -n "${WIN_WATCH_PID:-}" ] && kill -0 "$WIN_WATCH_PID" 2>/dev/null; then
    echo "covered=ok" >>"$d/actions.txt"
  else
    echo "covered=fail" >>"$d/actions.txt"
  fi
  win_watch_wait || rc=$?
  echo "$rc" >"$d/watcher-rc.txt"
  {
    echo "daemon=$(win_daemon_running && echo up || echo down)"
    echo "app=$(win_app_running && echo up || echo down)"
  } >"$d/final-state.txt"
}

setup() {
  win_app_running || { echo "桌面 App 没在跑"; return 77; }
  win_daemon_running || { echo "daemon 没在跑"; return 77; }
}

act() { run_window "$OUT" 0 "$WATCH"; }

judge() {
  local d="$1"
  check "watcher 正常退出（没有可见控制台）" eq_file "$d/watcher-rc.txt" "0"
  check "watcher 报告 0 个控制台窗口" has_line "$d/watcher.log" '^console windows seen: 0$'
  check "watcher 日志没有 CONSOLE 命中" watcher_no_console "$d/watcher.log"
  check "应用启动动作成功" grep -qx 'start=ok' "$d/actions.txt"
  check "强杀 daemon 动作成功" grep -qx 'kill=ok' "$d/actions.txt"
  check "强杀后 daemon 换新 pid 恢复" grep -qx 'recover=ok' "$d/actions.txt"
  check "停服务动作生效（daemon 确实停了）" grep -qx 'stop=ok' "$d/actions.txt"
  check "恢复服务动作生效（daemon 回来了）" grep -qx 'restore=ok' "$d/actions.txt"
  check "watcher 覆盖到动作结束（没有提前退出）" grep -qx 'covered=ok' "$d/actions.txt"
  check "动作后 daemon 在跑" grep -qx 'daemon=up' "$d/final-state.txt"
  verdict
}

counter() {
  local d="$OUT"
  # 去掉触发条件：窗口期内人为开一个可见控制台，watcher 必须报红。
  run_window "$d" 1 15
  # 反证复用主路径的动作证据：反证变红只能因为 watcher 抓到 CONSOLE，不是 actions.txt 缺失。
  cp "$EV/main/actions.txt" "$d/actions.txt" 2>/dev/null || true
  : >"$d/note.txt"
}

teardown() {
  # 恢复服务与 App（counter 只开了个 timeout 窗口，不影响服务）。
  win_app_running || win_start_app >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 30); do win_daemon_running && break; sleep 1; done
  return 0
}
