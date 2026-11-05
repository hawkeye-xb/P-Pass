# R3.3/R4.1：桌面「停止后台服务」后 2 分钟不被拉起、计划任务被删；恢复后 daemon 回来。
# R4.1：手机「断开与这台电脑的连接」后桌面把设备标为已断开。
#
# 反证：不执行停止（daemon 一直跑），停服务窗口的采样里出现 pid ⇒ 判据变红。
# teardown 保证服务恢复运行；若手机被断开，重新配对，给下一轮留下配对态。
DESC="R3.3/R4.1：停服务后 2 分钟保持停止、任务被删；恢复后回来；手机断开后桌面标记已断开"
COUNTER=on
STOP_WINDOW="${E3_WIN_STOP_WINDOW:-120}"

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

desktop_click() { win_ui_click "$1" >/dev/null || { echo "点不到：$1"; return 1; }; sleep 1; }

stop_via_app() {
  desktop_click '设置' || return 1
  win_ui_dump "$OUT/stop-dialog.txt" || true
  win_ui_has "$OUT/stop-dialog.txt" '停止后台服务' || { echo "设置页没有停止后台服务"; return 1; }
  win_ui_click '停止后台服务' >/dev/null || { echo "点不到停止后台服务"; return 1; }
  sleep 2
  win_ui_dump "$OUT/stop-dialog.txt" || true
  if win_ui_has "$OUT/stop-dialog.txt" '确定停止'; then
    win_ui_dialog_click '确定' || { echo "确认框点不到确定"; return 1; }
    sleep 2
  fi
  win_ui_dump "$OUT/stop-dialog.txt" || true
  win_ui_has "$OUT/stop-dialog.txt" '已停止' || { echo "App 没显示已停止"; return 1; }
}

restore_via_app() {
  desktop_click '总览' || return 1
  win_ui_dump "$OUT/restore.txt" || true
  win_ui_has "$OUT/restore.txt" '启动后台服务' || { echo "总览页没有启动后台服务"; return 1; }
  win_ui_click '启动后台服务' >/dev/null || { echo "点不到启动后台服务"; return 1; }
  local i
  for i in $(seq 1 30); do win_daemon_running && break; sleep 1; done
  win_daemon_running
}

phone_disconnect() {
  local d="$OUT" dump="$d/phone-disconnect.xml"
  win_phone_start
  win_phone_dump "$dump" || return 1
  win_phone_tap_xml "$dump" '^设置$' || win_phone_tap_xml "$dump" '设置' || return 1
  sleep 1
  win_phone_dump "$dump" || return 1
  win_phone_tap_xml "$dump" '更多' || { echo "手机设置没有更多"; return 1; }
  sleep 1
  win_phone_dump "$dump" || return 1
  win_phone_tap_xml "$dump" '存储电脑' || { echo "手机没有存储电脑"; return 1; }
  sleep 1
  win_phone_dump "$dump" || return 1
  win_phone_tap_xml "$dump" '断开与这台电脑的连接' || { echo "手机没有断开连接"; return 1; }
  sleep 2
  win_phone_dump "$dump" || true
  # 确认框标题是「断开连接？」，按钮是「断开」；用带分隔符的正则精确点按钮而不是标题。
  if win_phone_has "$dump" '断开连接？'; then
    win_phone_tap_xml "$dump" '^断开␟' || win_phone_tap_xml "$dump" '^断开' || true
  fi
  sleep 3
  win_phone_dump "$dump" || true
}

setup() {
  win_app_running || { echo "桌面 App 没在跑"; return 77; }
  win_daemon_running || { echo "daemon 没在跑"; return 77; }
  win_diag "$EV/main" >/dev/null 2>&1 || true
  [ "$(win_json_array_len "$EV/main/diag/devices.json")" = 1 ] || { echo "桌面没有 1 台配对设备（先跑 win/pair-backup）"; return 77; }
  echo "版本：$(win_status_field "$EV/main" version)"
}

act() {
  local d="$OUT" i pid
  # 1) 停服务，采样 2 分钟
  stop_via_app || return 1
  : >"$d/stop-samples.txt"
  for i in $(seq 10 10 "$STOP_WINDOW"); do
    pid="$(win_daemon_pid)"
    echo "t+${i}s pid=${pid} task=$(win_task_state)" >>"$d/stop-samples.txt"
    sleep 10
  done
  win_diag "$d" >/dev/null 2>&1 || true
  # 2) 恢复
  restore_via_app || echo "恢复服务失败"
  sleep 5
  win_diag "$d" >/dev/null 2>&1 || true
  cp "$d/diag/devices.json" "$d/devices-after-restore.json" 2>/dev/null || true
  {
    echo "restored_pid=$(win_daemon_pid)"
    echo "restored_task=$(win_task_state)"
    echo "restored_state=$(win_status_field "$d" state)"
  } >"$d/restore.txt"
  # 3) R4.1 手机断开
  phone_disconnect || echo "手机断开流程失败"
  sleep 5
  win_diag "$d" >/dev/null 2>&1 || true
  cp "$d/diag/devices.json" "$d/devices-after-disconnect.json" 2>/dev/null || true
  win_phone_dump "$d/phone-after-disconnect.xml" || true
}

task_not_seen() { [ -s "$1" ] && no_line "$1" 'task=Running|task=Ready'; }
phone_welcome() { grep -Eq '扫码连接|无法扫码' "$1"; }

judge() {
  local d="$1"
  check "停服务期间 daemon 一次都没出现" samples_no_daemon "$d/stop-samples.txt"
  check "停服务期间计划任务被删" task_not_seen "$d/stop-samples.txt"
  check "App 显示已停止" win_ui_has "$d/stop-dialog.txt" '已停止'
  check "恢复后 daemon 在跑" grep -Eq '^restored_pid=[0-9]+' "$d/restore.txt"
  check "恢复后计划任务在运行" grep -qx 'restored_task=Running' "$d/restore.txt"
  check "恢复后 daemon 在线" grep -qx 'restored_state=ONLINE_DIRECT' "$d/restore.txt"
  check "断开后桌面把该设备标为未配对" grep -q '"paired": false' "$d/devices-after-disconnect.json"
  check "手机回到欢迎页（出现扫码/手动配对）" phone_welcome "$d/phone-after-disconnect.xml"
  verdict
}

counter() {
  local d="$OUT" i pid
  # 去掉「停止」这个触发条件：不点停止，daemon 一直跑；同一套采样判据必须变红。
  echo "counter: 不执行停止（daemon 保持运行）" >"$d/note.txt"
  : >"$d/stop-samples.txt"
  for i in 10 20 30; do
    pid="$(win_daemon_pid)"
    echo "t+${i}s pid=${pid} task=$(win_task_state)" >>"$d/stop-samples.txt"
    sleep 10
  done
  win_ui_dump "$d/stop-dialog.txt" || true
  cp "$EV/main/restore.txt" "$d/restore.txt" 2>/dev/null || true
  cp "$EV/main/devices-after-disconnect.json" "$d/devices-after-disconnect.json" 2>/dev/null || true
  cp "$EV/main/phone-after-disconnect.xml" "$d/phone-after-disconnect.xml" 2>/dev/null || true
}

teardown() {
  # 服务必须恢复；手机被断开了就重新配对（下一轮起点要求配对态）。
  if ! win_daemon_running; then
    win_app_running || win_start_app >/dev/null 2>&1 || true
    desktop_click '总览' >/dev/null 2>&1 || true
    win_ui_click '启动后台服务' >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 30); do win_daemon_running && break; sleep 1; done
  fi
  local d="$E3_STATE/win/teardown-pair"
  mkdir -p "$d"
  win_diag "$d" >/dev/null 2>&1 || true
  if [ "$(win_json_array_len "$d/diag/devices.json")" != 1 ]; then
    win_app_running || win_start_app >/dev/null 2>&1 || true
    win_pair "$d" >/dev/null 2>&1 || true
  fi
  return 0
}
