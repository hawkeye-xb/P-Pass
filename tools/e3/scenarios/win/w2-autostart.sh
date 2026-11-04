# W2：自启登记是计划任务（登录触发 + 每分钟看门狗），不是 HKCU Run 值；任务指向安装目录里的 daemon。
#
# 反证：临时写一个 HKCU Run 的 P-Pass 值 ⇒「Run 值不存在」判据变红；teardown 删掉。
DESC="W2：自启是计划任务 P-Pass（指向安装目录 daemon），没有 HKCU Run 值"
COUNTER=on

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

setup() {
  win_app_running || { echo "桌面 App 没在跑"; return 77; }
  win_daemon_running || { echo "daemon 没在跑"; return 77; }
}

act() {
  local d="$OUT"
  win_ps "
\$t=Get-ScheduledTask -TaskName 'P-Pass' -ErrorAction SilentlyContinue
if(\$t){
  (\$t.Actions | Select-Object -First 1).Execute
  'STATE=' + \$t.State
  'PRINCIPAL=' + \$t.Principal.UserId + '/' + \$t.Principal.LogonType + '/' + \$t.Principal.RunLevel
  'TRIGGERS=' + ((\$t.Triggers | ForEach-Object { \$_.CimClass.CimClassName }) -join ',')
} else { 'NO_TASK' }
" >"$d/task.txt" 2>&1
  if win_run_value_exists; then echo "RUN_VALUE_PRESENT" >"$d/run-value.txt"; else echo "RUN_VALUE_ABSENT" >"$d/run-value.txt"; fi
  win_diag "$d" >/dev/null 2>&1 || true
  {
    echo "daemon_pid=$(win_daemon_pid)"
    echo "status_version=$(win_status_field "$d" version)"
  } >"$d/state.txt"
}

judge() {
  local d="$1"
  check "计划任务存在且动作是安装目录里的 ppf-daemon" grep -Fq "$WIN_APP_DIR_WIN\\ppf-daemon.exe" "$d/task.txt"
  check "计划任务在运行" grep -q 'STATE=Running' "$d/task.txt"
  check "任务主体是交互用户、Limited（不弹 UAC）" grep -q 'PRINCIPAL=.*/Interactive/Limited' "$d/task.txt"
  check "有登录触发和看门狗重复触发" grep -Eq 'TRIGGERS=.*LogonTrigger' "$d/task.txt"
  check "HKCU Run 下没有 P-Pass 值" eq_file "$d/run-value.txt" "RUN_VALUE_ABSENT"
  check "daemon 在跑" grep -Eq '^daemon_pid=[0-9]+' "$d/state.txt"
  verdict
}

counter() {
  local d="$OUT"
  # 去掉触发条件：人为写回一个 HKCU Run 值，判据必须变红。
  win_ps "New-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'P-Pass' -Value 'C:\\fake\\p-pass-desktop.exe' -PropertyType String -Force | Out-Null" >/dev/null 2>&1 || true
  cp "$EV/main/task.txt" "$d/task.txt" 2>/dev/null || true
  echo "RUN_VALUE_PRESENT" >"$d/run-value.txt"
  cp "$EV/main/state.txt" "$d/state.txt" 2>/dev/null || true
}

teardown() {
  win_ps "Remove-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'P-Pass' -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
  return 0
}
