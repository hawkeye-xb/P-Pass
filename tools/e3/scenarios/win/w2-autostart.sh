# W2：自启登记是计划任务（登录触发 + 每分钟看门狗），不是 HKCU Run 值；任务指向安装目录里的 daemon。
#
# 反证：临时写一个 HKCU Run 的 P-Pass 值 ⇒「Run 值不存在」判据变红；teardown 删掉。
DESC="W2：自启是计划任务 P-Pass（指向安装目录 daemon），没有 HKCU Run 值"
COUNTER=on

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

setup() {
  win_app_running || { echo "桌面 App 没在跑"; return 77; }
  win_daemon_running || { echo "daemon 没在跑"; return 77; }
  # 在改任何状态之前保存用户原有的 Run 值；setup 返回 77 时不保存，teardown 也就不会动它。
  local orig="$E3_STATE/win/w2-run-orig.txt"
  mkdir -p "$(dirname "$orig")"
  win_ps "
\$v=(Get-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'P-Pass' -ErrorAction SilentlyContinue).'P-Pass'
if(\$null -eq \$v){ 'ABSENT' } else { 'VALUE=' + \$v }
" >"$orig" 2>&1
}

act() {
  local d="$OUT"
  win_ps "
\$t=Get-ScheduledTask -TaskName 'P-Pass' -ErrorAction SilentlyContinue
if(\$t){
  \$a=(\$t.Actions | Select-Object -First 1)
  'EXECUTE=' + \$a.Execute
  'ARGUMENTS=' + \$a.Arguments
  'STATE=' + \$t.State
  'PRINCIPAL=' + \$t.Principal.UserId + '/' + \$t.Principal.LogonType + '/' + \$t.Principal.RunLevel
  'TRIGGERS=' + ((\$t.Triggers | ForEach-Object { \$_.CimClass.CimClassName }) -join ',')
  'REPETITION=' + ((\$t.Triggers | Where-Object { \$_.Repetition } | ForEach-Object { \$_.Repetition.Interval }) -join ',')
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
  check "计划任务的 Execute 是安装目录里的 ppf-daemon" grep -Fq "EXECUTE=$WIN_APP_DIR_WIN\\ppf-daemon.exe" "$d/task.txt"
  check "计划任务在运行" grep -q 'STATE=Running' "$d/task.txt"
  check "任务主体是交互用户、Limited（不弹 UAC）" grep -q 'PRINCIPAL=.*/Interactive/Limited' "$d/task.txt"
  check "有登录触发" grep -Eq 'TRIGGERS=.*LogonTrigger' "$d/task.txt"
  check "看门狗每分钟重复触发（PT1M）" grep -Eq 'REPETITION=.*PT1M' "$d/task.txt"
  check "HKCU Run 下没有 P-Pass 值" eq_file "$d/run-value.txt" "RUN_VALUE_ABSENT"
  check "daemon 在跑" grep -Eq '^daemon_pid=[0-9]+' "$d/state.txt"
  verdict
}

counter() {
  local d="$OUT" marker="$E3_STATE/win/w2-counter-wrote"
  mkdir -p "$(dirname "$marker")"
  # counter 没跑（--no-counter / main 判红 / setup 失败）时 teardown 不能碰注册表；
  # 这里写下标记，teardown 只在标记存在时才恢复/删除。
  : >"$marker"
  # 去掉触发条件：人为写回一个 HKCU Run 值，判据必须变红。写不进去就是反证本身失败，不能算红。
  win_ps "New-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'P-Pass' -Value 'C:\\fake\\p-pass-desktop.exe' -PropertyType String -Force | Out-Null" >/dev/null 2>&1 ||
    { echo "反证：写 HKCU Run 值失败" >&2; return 1; }
  win_run_value_exists || { echo "反证：写入后读不到 HKCU Run 值" >&2; return 1; }
  echo "RUN_VALUE_PRESENT" >"$d/run-value.txt"
  cp "$EV/main/task.txt" "$d/task.txt" 2>/dev/null || true
  cp "$EV/main/state.txt" "$d/state.txt" 2>/dev/null || true
}

teardown() {
  local orig="$E3_STATE/win/w2-run-orig.txt" marker="$E3_STATE/win/w2-counter-wrote" val_file="$E3_STATE/win/w2-run-orig-value.txt"
  if [ ! -s "$orig" ] || [ ! -f "$marker" ]; then
    # setup 没保存原值（SKIP/失败）或 counter 没跑：不动用户注册表。
    return 0
  fi
  if grep -qx 'ABSENT' "$orig"; then
    # 测试前明确没有这个值：删除测试写入的值。
    win_ps "Remove-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'P-Pass' -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
    rm -f "$orig" "$marker"
  elif grep -q '^VALUE=' "$orig"; then
    # 原值存在：恢复原值（值里可能有空格/引号，用变量传入）。
    sed -n 's/^VALUE=//p' "$orig" >"$val_file" 2>/dev/null || true
    win_ps "
\$v=[IO.File]::ReadAllText('$(cygpath -w "$val_file")').TrimEnd([char]13,[char]10)
Set-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'P-Pass' -Value \$v -Type String
" >/dev/null 2>&1 || echo "teardown：恢复原 HKCU Run 值失败，原值见 $val_file" >&2
    rm -f "$val_file" "$orig" "$marker"
  else
    # 原值读取失败/内容不认识：宁可不碰注册表，保留 orig 供排查。
    echo "teardown：原 HKCU Run 值读取失败（见 ${orig}），不动注册表" >&2
    rm -f "$marker"
  fi
  return 0
}
