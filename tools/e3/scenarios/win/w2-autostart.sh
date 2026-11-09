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
  # 上次 teardown 没恢复成功时原值还留着：不能拿现在的注册表（可能是反证写的假值）盖掉它。
  if [ -s "$orig" ]; then
    echo "沿用上次未恢复的原 HKCU Run 值（${orig}）"
    return 0
  fi
  win_ps "
\$k=Get-Item -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
\$v=\$k.GetValue('P-Pass', \$null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
if(\$null -eq \$v){ 'ABSENT' } else { 'KIND=' + \$k.GetValueKind('P-Pass'); 'VALUE=' + \$v }
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
  # Get-ScheduledTask 给的是任务 XML 里的枚举名（crates/platform/src/windows.rs:151-152）：
  # InteractiveToken / LeastPrivilege，不是 PowerCLI 习惯的 Interactive / Limited。
  check "任务主体是交互用户、LeastPrivilege（不弹 UAC）" grep -q 'PRINCIPAL=.*/InteractiveToken/LeastPrivilege' "$d/task.txt"
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
  local orig="$E3_STATE/win/w2-run-orig.txt" marker="$E3_STATE/win/w2-counter-wrote" val_file="$E3_STATE/win/w2-run-orig-value.txt" orig_clean kind
  if [ ! -s "$orig" ] || [ ! -f "$marker" ]; then
    # setup 没保存原值（SKIP/失败）或 counter 没跑：不动用户注册表。
    return 0
  fi
  # PowerShell 输出是 CRLF；先去掉 \r 再解析，避免把 ABSENT/VALUE 当成读不到。
  orig_clean="$(tr -d '\r' <"$orig")"
  kind="$(printf '%s\n' "$orig_clean" | sed -n 's/^KIND=//p' | head -1)"
  if printf '%s\n' "$orig_clean" | grep -qx 'ABSENT'; then
    # 测试前明确没有这个值：删除测试写入的值；删完核对确实不存在，失败就保留恢复数据。
    if win_ps "
Remove-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'P-Pass' -ErrorAction SilentlyContinue
\$k=Get-Item -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
if(\$null -ne \$k.GetValue('P-Pass')){ exit 1 }
" >/dev/null 2>&1; then
      rm -f "$orig" "$marker"
    else
      echo "teardown：删除测试写入的 HKCU Run 值失败，保留 ${orig} 供排查" >&2
    fi
  elif printf '%s\n' "$orig_clean" | grep -q '^VALUE=' && { [ "$kind" = String ] || [ "$kind" = ExpandString ]; }; then
    # 原值存在：按原类型和未展开的原文恢复（值里可能有空格/引号/环境变量，用文件传入）。
    printf '%s\n' "$orig_clean" | sed -n 's/^VALUE=//p' >"$val_file"
    if win_ps "
\$path='HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
\$name='P-Pass'
\$v=[IO.File]::ReadAllText('$(cygpath -w "$val_file")').TrimEnd([char]13,[char]10)
Remove-ItemProperty -Path \$path -Name \$name -ErrorAction SilentlyContinue
if('$kind' -eq 'ExpandString'){
  New-ItemProperty -Path \$path -Name \$name -Value \$v -PropertyType ExpandString -Force | Out-Null
} else {
  New-ItemProperty -Path \$path -Name \$name -Value \$v -PropertyType String -Force | Out-Null
}
\$k=Get-Item -Path \$path
\$now=\$k.GetValue(\$name, \$null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
if(\$now -ne \$v -or \$k.GetValueKind(\$name).ToString() -ne '$kind'){ exit 1 }
" >/dev/null 2>&1; then
      rm -f "$val_file" "$orig" "$marker"
    else
      echo "teardown：恢复原 HKCU Run 值失败，原值见 ${val_file}" >&2
    fi
  else
    # 原值读取失败/类型不支持：宁可不碰注册表，保留 orig 供排查。
    echo "teardown：原 HKCU Run 值读取失败或类型不支持（kind=${kind:-?}，见 ${orig}），不动注册表" >&2
  fi
  return 0
}
