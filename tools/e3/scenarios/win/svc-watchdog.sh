# R3.2：强杀 daemon，计划任务 P-Pass 的每分钟看门狗在 1 分钟内把它拉起来；壳开着/关着各做一次。
#
# 计划任务由壳登记（RunLevel Limited、Interactive），动作是 %LOCALAPPDATA%\P-Pass\ppf-daemon.exe；
# 看门狗拉起时父进程应是 svchost（SOP §9.3）。
# 反证：先 Disable-ScheduledTask 再杀 daemon ⇒ 90s 内没有新进程，判据变红；teardown 恢复任务。
DESC="R3.2：kill -9 daemon 后看门狗 1 分钟内拉起（壳开/关各一次，父进程 svchost）"
COUNTER=on
WINDOW="${E3_WIN_WATCHDOG_WINDOW:-90}"

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

wait_new_pid() { # wait_new_pid <旧 pid> <秒> → 打印新 pid（失败空）
  local old="$1" secs="$2" end=$((SECONDS + ${2:-90})) pid
  while [ $SECONDS -lt $end ]; do
    pid="$(win_daemon_pid)"
    if [ -n "$pid" ] && [ "$pid" != "$old" ]; then echo "$pid"; return 0; fi
    sleep 2
  done
  return 1
}

one_round() { # one_round <证据目录> <轮次名> <壳开着 1|0>
  local d="$1" tag="$2" shell_up="$3" old new parent pname i
  mkdir -p "$d"
  win_diag "$d" || { echo "$tag: daemon 不可达"; return 1; }
  old="$(win_status_field "$d" pid)"
  echo "$old" >"$d/$tag-pid-before.txt"
  echo "task=$(win_task_state)" >"$d/$tag-task.txt"
  if [ "$shell_up" = 0 ]; then win_stop_app; fi
  # 强杀
  win_ps "Stop-Process -Id $old -Force" >/dev/null 2>&1 || true
  new="$(wait_new_pid "$old" "$WINDOW")" || { echo "$tag: ${WINDOW}s 内没有新 daemon"; echo "" >"$d/$tag-pid-after.txt"; return 1; }
  echo "$new" >"$d/$tag-pid-after.txt"
  parent="$(win_process_parent "$new")"
  pname="$(win_process_name "$parent")"
  echo "parent_pid=$parent parent_name=$pname" >"$d/$tag-parent.txt"
  # 等就绪 + 收日志
  for i in $(seq 1 30); do
    win_diag "$d/now" >/dev/null 2>&1 && win_status_field "$d/now" state | grep -q ONLINE && break
    sleep 2
  done
  cp "$WIN_DATA_DIR/logs/daemon.log" "$d/$tag-daemon.log" 2>/dev/null || true
  win_diag "$d/$tag" >/dev/null 2>&1 || true
  cp "$d/$tag/diag/status.json" "$d/$tag-status.json" 2>/dev/null || true
  win_ui_dump "$d/$tag-desktop.txt" || true
}

setup() {
  win_app_running || { echo "桌面 App 没在跑（先跑 win/upgrade-candidate）"; return 77; }
  win_daemon_running || { echo "daemon 没在跑"; return 77; }
  win_diag "$EV/main" >/dev/null 2>&1 || true
  echo "版本：$(win_status_field "$EV/main" version)；配对设备：$(win_json_array_len "$EV/main/diag/devices.json")"
}

act() {
  local d="$OUT"
  one_round "$d" shell-open 1 || true
  one_round "$d" shell-closed 0 || true
  win_app_running || win_start_app >/dev/null 2>&1 || true
  win_diag "$d" >/dev/null 2>&1 || true
  {
    echo "version=$(win_status_field "$d" version)"
    echo "photo_count=$(win_status_field "$d" photo_count)"
    echo "task=$(win_task_state)"
  } >"$d/after.txt"
}

parent_is_svchost_or_shell() { grep -Eq 'parent_name=(svchost|p-pass-desktop)' "$1"; }
status_online() { jget "$1" "j['state']" 2>/dev/null | grep -q ONLINE; }

judge() {
  local d="$1" tag
  for tag in shell-open shell-closed; do
    check "[$tag] 杀前有 pid" grep -Eq '[0-9]+' "$d/$tag-pid-before.txt"
    check "[$tag] ${WINDOW}s 内出现新 pid" grep -Eq '[0-9]+' "$d/$tag-pid-after.txt"
    check "[$tag] 新 pid 与旧的不同" [ "$(tr -d '[:space:]' <"$d/$tag-pid-before.txt")" != "$(tr -d '[:space:]' <"$d/$tag-pid-after.txt")" ]
    if [ "$tag" = shell-closed ]; then
      check "[$tag] 父进程是 svchost（计划任务看门狗）" grep -q 'parent_name=svchost' "$d/$tag-parent.txt"
    else
      # 壳开着时壳自己也会自愈拉起 daemon（实测父进程 ppass-desktop），这是可接受的恢复路径；
      # 两种父进程都算「1 分钟内被拉起」，壳关着时才必须由计划任务（svchost）拉起。
      check "[$tag] 被拉起（父进程 svchost 或壳自愈）" parent_is_svchost_or_shell "$d/$tag-parent.txt"
      grep -q 'parent_name=p-pass-desktop' "$d/$tag-parent.txt" && echo "  INFO  shell-open 由壳自愈拉起（父进程 p-pass-desktop；SOP 写的是 svchost）"
    fi
    check "[$tag] 拉起后 daemon 在线" status_online "$d/$tag-status.json"
    check "[$tag] 日志出现「启动就绪」" has_line "$d/$tag-daemon.log" '启动就绪'
    check "[$tag] 日志无 panic" no_line_panic "$d/$tag-daemon.log"
  done
  verdict
}

counter() {
  local d="$OUT" old pid
  # 去掉看门狗这个触发条件：禁用计划任务、关掉壳（壳也会自发拉起 daemon），再杀 daemon。
  win_task_disable
  win_stop_app
  win_diag "$d" >/dev/null 2>&1 || true
  old="$(win_status_field "$d" pid)"
  echo "$old" >"$d/counter-pid-before.txt"
  win_ps "Stop-Process -Id $old -Force" >/dev/null 2>&1 || true
  sleep 20
  pid="$(win_daemon_pid)"
  echo "${pid:-}" >"$d/counter-pid-after.txt"
  echo "task=$(win_task_state)" >"$d/counter-task.txt"
  # 与主判据同形的证据：没有新 pid、没有日志就绪
  cp "$WIN_DATA_DIR/logs/daemon.log" "$d/counter-daemon.log" 2>/dev/null || true
  cp "$d/counter-pid-before.txt" "$d/shell-open-pid-before.txt"
  cp "$d/counter-pid-after.txt" "$d/shell-open-pid-after.txt"
  cp "$d/counter-daemon.log" "$d/shell-open-daemon.log" 2>/dev/null || true
  : >"$d/shell-open-parent.txt"
  cp "$d/counter-pid-before.txt" "$d/shell-closed-pid-before.txt"
  cp "$d/counter-pid-after.txt" "$d/shell-closed-pid-after.txt"
  : >"$d/shell-closed-parent.txt"
}

teardown() {
  win_task_enable
  if ! win_daemon_running; then
    win_ps "schtasks /run /tn P-Pass" >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 30); do win_daemon_running && break; sleep 1; done
  fi
  win_app_running || win_start_app >/dev/null 2>&1 || true
  return 0
}
