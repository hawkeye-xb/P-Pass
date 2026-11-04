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

run_window() { # run_window <证据目录> <故障注入 0|1> <秒>
  local d="$1" fault="$2" secs="$3" rc=0
  mkdir -p "$d"
  win_watch_start "$d/watcher.log" "$secs"
  if [ "$fault" = 1 ]; then
    # 可见控制台：start 会新建一个窗口，watcher 应把它抓成 CONSOLE。
    win_ps "Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = 'cmd.exe /c start \"\" cmd.exe /c \"timeout /t 3\"' } | Out-Null" >/dev/null 2>&1 || true
    sleep 4
  else
    win_app_running || win_start_app >/dev/null 2>&1 || true
    sleep 3
    # 强杀 daemon：壳开着时壳自愈，壳没开时计划任务 1 分钟内拉起。
    win_kill_daemon || true
    sleep 12
    # 停服务 → 恢复
    desktop_click() { win_ui_click "$1" >/dev/null || return 1; sleep 1; }
    if desktop_click '设置'; then
      if win_ui_click '停止后台服务' >/dev/null; then
        sleep 2
        win_ui_dump "$d/stop-dialog.txt" || true
        if win_ui_has "$d/stop-dialog.txt" '确定停止'; then win_ui_dialog_click '确定' || true; fi
        sleep 8
      fi
    fi
    if desktop_click '总览'; then
      win_ui_dump "$d/restore.txt" || true
      if win_ui_has "$d/restore.txt" '启动后台服务'; then win_ui_click '启动后台服务' >/dev/null || true; fi
    fi
    sleep 10
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
  check "watcher 日志没有 CONSOLE 命中" no_line "$d/watcher.log" 'CONSOLE'
  check "动作后 daemon 在跑" grep -qx 'daemon=up' "$d/final-state.txt"
  verdict
}

counter() {
  local d="$OUT"
  # 去掉触发条件：窗口期内人为开一个可见控制台，watcher 必须报红。
  run_window "$d" 1 15
  : >"$d/note.txt"
}

teardown() {
  # 恢复服务与 App（counter 只开了个 timeout 窗口，不影响服务）。
  win_app_running || win_start_app >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 30); do win_daemon_running && break; sleep 1; done
  return 0
}
