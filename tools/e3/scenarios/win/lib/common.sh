# Windows 回归场景的本地共享函数。
#
# 公共库 tools/e3/lib/** 本卡不能改（#1378 在改）；这里放 Windows 场景需要、但公共库
# 还没有的辅助函数，后续再提升到公共库。由各场景脚本 `source`。
#
# 约定：
# - 只在 Git Bash 里跑；Windows 原生程序的参数用 `cygpath -w` 传，避免 MSYS 改写路径。
# - adb 的参数一律加 MSYS2_ARG_CONV_EXCL='*'，否则 /sdcard/... 会被改写成 C:\Program Files\Git\...
# - 手机经 ssh 反向隧道：本机 e3.env 的 ADB_SERVER_SOCKET=tcp:127.0.0.1:<端口>（common.sh 已导入）。
# shellcheck shell=bash

WIN_APP_DIR_WIN="${LOCALAPPDATA}\\P-Pass"
WIN_APP_DIR="$(cygpath -u "$WIN_APP_DIR_WIN" 2>/dev/null || echo "$WIN_APP_DIR_WIN")"
WIN_DATA_DIR_WIN="${LOCALAPPDATA}\\com.hawkeyexb.ppass.desktop"
WIN_DATA_DIR="$(cygpath -u "$WIN_DATA_DIR_WIN" 2>/dev/null || echo "$WIN_DATA_DIR_WIN")"
# 配置文件位置：用户态布局在 WIN_DATA_DIR；perMachine 服务模式下 daemon 的配置
# （含库位置）在 %ProgramData%\P-Pass，由场景设 WIN_CONF_DIR 指定。
WIN_CONF_DIR="${WIN_CONF_DIR:-}"
win_config_file() { # 存在的 config.toml 路径；先看 WIN_CONF_DIR，再回退用户态
  local c
  for c in "${WIN_CONF_DIR:+$WIN_CONF_DIR/config.toml}" "$WIN_DATA_DIR/config.toml"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
WIN_DESKTOP_EXE="$WIN_APP_DIR/p-pass-desktop.exe"
WIN_DAEMON_EXE="$WIN_APP_DIR/ppf-daemon.exe"
WIN_REL_DIR="$E3_STATE/win/releases"
WIN_TOOLS="$E3_STATE/win/tools"
# 本文件在 win/lib/ 下；场景文件（scope.py、gen-photos.ps1 等）在上一级 win/。
WIN_SCN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIN_UIA_PS="$(cygpath -w "$REPO_ROOT/tools/windows/uia-drive.ps1")"
WIN_OUTSIDE_PS="$(cygpath -w "$REPO_ROOT/tools/windows/run-outside-package.ps1")"
WIN_WATCH_PS="$(cygpath -w "$REPO_ROOT/tools/windows/watch-new-windows.ps1")"

# 稳定标签（Latest）与候选标签，场景可用环境变量覆盖。
# 候选版本号从候选标签推导（去掉 v 前缀）：换 test 包只设 E3_WIN_CAND_TAG，
# 场景里的版本断言跟着变，不用改脚本。
WIN_BASE_TAG="${E3_WIN_BASE_TAG:-v2026.10.7}"
WIN_BASE_VER="${E3_WIN_BASE_VER:-0.10.1}"
WIN_BASE_PHONE_VER="${E3_WIN_BASE_PHONE_VER:-0.10.2}"
WIN_CAND_TAG="${E3_WIN_CAND_TAG:-v0.11.0-test.1}"
WIN_CAND_VER="${E3_WIN_CAND_VER:-${WIN_CAND_TAG#v}}"

# —— PowerShell / UI ——

# win_ps <PowerShell 代码>：经 -EncodedCommand 传，中文不会在 Git Bash 里被转码搞乱。
win_ps() {
  local code="$1" enc
  code="\$ProgressPreference='SilentlyContinue'; \$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; $code"
  enc="$(printf '%s' "$code" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand "$enc"
}

# win_ps_file <脚本> [参数…]
win_ps_file() {
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$@"
}

win_is_elevated() {
  local v
  v="$(win_ps '([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)' 2>/dev/null | tr -d '[:space:]')"
  [ "$v" = "True" ]
}

# win_ui_dump <证据文件>：把桌面 App 的 UIA 树写到文件（UTF-8）。
win_ui_dump() {
  local out="$1"
  win_ps "& '$WIN_UIA_PS' -Action dump -Out '$(cygpath -w "$out")'" >/dev/null 2>&1 || true
  [ -s "$out" ]
}

# win_ui_click <按钮文字>：精确匹配，失败重试一次（SOP §9.0b）。
win_ui_click() {
  local name="$1" out rc
  out="$(win_ps "& '$WIN_UIA_PS' -Action click -Name '$name'" 2>&1)" && { echo "$out"; return 0; }
  sleep 1
  out="$(win_ps "& '$WIN_UIA_PS' -Action click -Name '$name'" 2>&1)" && { echo "$out"; return 0; }
  echo "$out" >&2
  return 1
}

# win_ui_has <dump 文件> <文字>：UIA dump 里有这行文字（Text/Button 都算）。
win_ui_has() { [ -f "$1" ] && grep -Fq -- "$2" "$1"; }

# win_ui_wait <dump 文件> <文字> <秒>：反复 dump 直到出现。
win_ui_wait() {
  local out="$1" text="$2" secs="${3:-30}" end=$((SECONDS + ${3:-30}))
  while [ $SECONDS -lt $end ]; do
    if win_ui_dump "$out" && win_ui_has "$out" "$text"; then return 0; fi
    sleep 1
  done
  return 1
}

# win_ui_dialog_click <按钮文字>：原生确认框（如「停止后台服务」的确定/取消）。
# 这些按钮是 CCPushButton，没有 Invoke 模式，只能对 NativeWindowHandle 发 BM_CLICK（SOP §9.0b）；
# 发之前先把它的顶层窗口置前——不置前时第一次点击实测不生效。
win_ui_dialog_click() {
  local btn="$1" code
  code="$(cat <<'PS'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
$A=[Windows.Automation.AutomationElement]
$root=$A::RootElement
$target=$null
for($i=0;$i -lt 50;$i++){
  foreach($e in $root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)){
    if($e.Current.Name -eq '@BTN@' -and $e.Current.ClassName -eq 'CCPushButton'){ $target=$e; break }
  }
  if($target){ break }
  Start-Sleep -Milliseconds 200
}
if(-not $target){ exit 2 }
$h=[IntPtr]$target.Current.NativeWindowHandle
if($h -eq [IntPtr]::Zero){ exit 3 }
if(-not ('Pp.Win32' -as [type])) { Add-Type -Namespace Pp -Name Win32 -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l); [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l); [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);' }
$top=[Pp.Win32]::GetAncestor($h,2)
if($top -ne [IntPtr]::Zero){ [Pp.Win32]::SetForegroundWindow($top) | Out-Null }
[void][Pp.Win32]::SendMessage($h,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
Start-Sleep -Milliseconds 300
[void][Pp.Win32]::PostMessage($h,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
Start-Sleep -Milliseconds 400
$again=$null
foreach($e in $root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)){
  if($e.Current.Name -eq '@BTN@' -and $e.Current.ClassName -eq 'CCPushButton'){ $again=$e; break }
}
if($again -and [IntPtr]$again.Current.NativeWindowHandle -eq $h){ [void][Pp.Win32]::PostMessage($h,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero) }
PS
)"
  code="${code//@BTN@/$btn}"
  win_ps "$code"
}

# win_ui_set_edit <控件名> <值>：WebView2 的 Edit 走 UIA ValuePattern。
win_ui_set_edit() {
  local name="$1" value="$2"
  win_ps "
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
\$A=[Windows.Automation.AutomationElement]
\$p=Get-Process p-pass-desktop -ErrorAction Stop | Select-Object -First 1
\$cond=New-Object Windows.Automation.PropertyCondition(\$A::ProcessIdProperty,\$p.Id)
\$win=\$A::RootElement.FindFirst([Windows.Automation.TreeScope]::Children,\$cond)
\$all=\$win.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
\$done=\$false
foreach(\$e in \$all){ if(\$e.Current.ControlType.ProgrammaticName -eq 'ControlType.Edit' -and (\$e.Current.Name -eq '$name' -or '$name' -eq '')){ \$vp=\$null; if(\$e.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern,[ref]\$vp)){ \$vp.SetValue('$value'); \$done=\$true; break } } }
if(-not \$done){ exit 3 }
" >/dev/null
}

# win_ui_texts <dump 文件>：提取可读文字（控制类型前缀去掉）。
win_ui_texts() { sed -n 's/^ControlType\.[A-Za-z]* | //p' "$1"; }

# —— App / daemon / 计划任务 ——

win_app_running() { powershell.exe -NoProfile -Command "if (Get-Process p-pass-desktop -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }" >/dev/null 2>&1; }
win_daemon_running() { powershell.exe -NoProfile -Command "if (Get-Process ppf-daemon -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }" >/dev/null 2>&1; }

# 经 WMI 起 App（SOP §9.0：不要用 run-outside-package 起 App，它会被常驻进程占住 out.txt）。
win_start_app() {
  # 直接起 GUI exe，不经 `cmd /c start`：cmd 是控制台程序，在 Windows Terminal 作为
  # 默认终端的机器上会闪一个可见终端窗口，W1 的 watcher 会把它当成产品闪窗（#1601）。
  win_ps "\$r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = '\"$(cygpath -w "$WIN_DESKTOP_EXE")\"' }; if(\$r.ReturnValue -ne 0){ exit 1 }" >/dev/null
  local i
  for i in $(seq 1 30); do win_app_running && return 0; sleep 1; done
  return 1
}

win_stop_app() { win_ps "Get-Process p-pass-desktop -ErrorAction SilentlyContinue | Stop-Process -Force" >/dev/null 2>&1 || true; }

win_kill_daemon() {
  local pid
  pid="$(win_daemon_pid)"
  [ -n "$pid" ] || return 1
  win_ps "Stop-Process -Id $pid -Force" >/dev/null 2>&1 || true
}

win_daemon_pid() {
  win_ps "(Get-Process ppf-daemon -ErrorAction SilentlyContinue | Select-Object -First 1).Id" 2>/dev/null | tr -d '[:space:]'
}

win_task_state() {
  win_ps "(Get-ScheduledTask -TaskName 'P-Pass' -ErrorAction SilentlyContinue).State" 2>/dev/null | tr -d '[:space:]'
}

# 任务是「已启用」还是「已禁用」。不能拿 State 判：任务动作就是常驻 daemon，
# 正在跑的实例会让 State 一直是 Running，Disable-ScheduledTask 也不会停掉它（#1599）。
win_task_enabled() {
  win_ps "(Get-ScheduledTask -TaskName 'P-Pass' -ErrorAction SilentlyContinue).Settings.Enabled" 2>/dev/null | tr -d '[:space:]'
}

win_task_action_path() {
  win_ps "(Get-ScheduledTask -TaskName 'P-Pass' -ErrorAction SilentlyContinue).Actions | Select-Object -First 1 -ExpandProperty Execute" 2>/dev/null | tr -d '\r'
}

win_run_value_exists() {
  local v
  v="$(win_ps "(Get-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'P-Pass' -ErrorAction SilentlyContinue).'P-Pass'" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$v" ]
}

win_task_enable() { win_ps "Enable-ScheduledTask -TaskName 'P-Pass' -ErrorAction SilentlyContinue | Out-Null" >/dev/null 2>&1 || true; }
win_task_disable() { win_ps "Disable-ScheduledTask -TaskName 'P-Pass' -ErrorAction SilentlyContinue | Out-Null" >/dev/null 2>&1 || true; }

win_process_parent() { win_ps "(Get-CimInstance Win32_Process -Filter 'ProcessId=$1').ParentProcessId" 2>/dev/null | tr -d '[:space:]'; }
win_process_name() { win_ps "(Get-Process -Id $1 -ErrorAction SilentlyContinue).ProcessName" 2>/dev/null | tr -d '[:space:]'; }

win_unregister_task() {
  # 计划任务带「每分钟看门狗」：不先停任务，杀掉的 daemon 会被它拉回来，覆盖安装时文件被占用。
  win_ps "Stop-ScheduledTask -TaskName 'P-Pass' -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 300; Unregister-ScheduledTask -TaskName 'P-Pass' -Confirm:\$false -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
  win_ps "schtasks /delete /tn 'P-Pass' /f" >/dev/null 2>&1 || true
  [ -z "$(win_task_state)" ]
}

# 停掉壳与 daemon，并确认真的没了（任务看门狗可能中途拉起）。
win_stop_all() {
  local i
  win_stop_app
  win_ps "Get-Process ppf-daemon -ErrorAction SilentlyContinue | Stop-Process -Force" >/dev/null 2>&1 || true
  for i in $(seq 1 10); do
    win_app_running || win_daemon_running || return 0
    win_stop_app
    win_ps "Get-Process ppf-daemon -ErrorAction SilentlyContinue | Stop-Process -Force" >/dev/null 2>&1 || true
    sleep 1
  done
  return 1
}

# —— 诊断包：diag export 是签名 daemon 自己跑的一次性短进程，能拿到 status / devices / logs ——

# win_diag <证据目录>：导出 zip 并解到 <证据目录>/diag/
win_diag() {
  local dir="$1"
  local zip="$dir/diag.zip"
  rm -rf "$dir/diag"
  mkdir -p "$dir"
  win_ps "& '$(cygpath -w "$WIN_DAEMON_EXE")' diag export --out '$(cygpath -w "$zip")' --app-version '$(win_app_version)'" >"$dir/diag-export.txt" 2>&1 || true
  # daemon 退出与文件落盘之间有空档（Defender 也会短暂锁新文件）：等 zip 可读再解。
  local i
  for i in $(seq 1 25); do [ -s "$zip" ] && break; sleep 0.2; done
  if [ -s "$zip" ]; then
    mkdir -p "$dir/diag"
    for i in 1 2 3; do
      unzip -oq "$zip" -d "$dir/diag" >"$dir/unzip.log" 2>&1 && break
      sleep 0.5
    done
  fi
  [ -f "$dir/diag/status.json" ]
}

win_status_field() { # win_status_field <证据目录> <字段>
  jget "$1/diag/status.json" "j['$2']" 2>/dev/null
}

win_devices_json() { [ -f "$1/diag/devices.json" ] && cat "$1/diag/devices.json"; }

# App 安装版本（HKCU 卸载登记的 DisplayVersion；extract 模式由场景自己写）。
win_app_version() {
  win_ps "(Get-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\P-Pass' -ErrorAction SilentlyContinue).DisplayVersion" 2>/dev/null | tr -d '[:space:]'
}

# exe 的 ProductVersion（与安装登记无关）。
win_exe_version() {
  win_ps "(Get-Item '$WIN_APP_DIR_WIN\\p-pass-desktop.exe' -ErrorAction SilentlyContinue).VersionInfo.ProductVersion" 2>/dev/null | tr -d '[:space:]'
}

# —— 照片库 ——

# 库目录以 config.toml 的 data_dir 为准（TOML 字面串或基本串）。
win_library_dir_win() {
  local conf raw
  conf="$(win_config_file)" || return 1
  raw="$(sed -n "s/^data_dir *= *[\"']\(.*\)[\"']\$/\\1/p" "$conf" | head -1)"
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | sed 's/\\\\/\\/g'
}
win_library_dir() { cygpath -u "$(win_library_dir_win)"; }

# 库内 originals 全量哈希：输出 "<sha256>  <相对路径>"。
win_library_hashes() {
  local dir="$1" lib
  lib="$(win_library_dir)" || return 1
  ( cd "$lib" && find originals -type f -print0 2>/dev/null | xargs -0 sha256sum 2>/dev/null | sort ) >"$dir/library-hashes.txt"
  [ -s "$dir/library-hashes.txt" ]
}

# 身份私钥：服务模式在 %ProgramData%\P-Pass 根下；用户态布局在平台数据目录 .ppf/；
# #1260 之前还放在照片库 .ppf/。三处都认。
win_identity_key() {
  local lib key
  lib="$(win_library_dir 2>/dev/null)" || lib=""
  for key in "${WIN_CONF_DIR:+$WIN_CONF_DIR/identity.key}" "$WIN_DATA_DIR/.ppf/identity.key" "${lib:+$lib/.ppf/identity.key}"; do
    [ -n "$key" ] && [ -f "$key" ] && { printf '%s' "$key"; return 0; }
  done
  return 1
}

win_library_count() {
  local lib
  lib="$(win_library_dir)" || { echo 0; return; }
  find "$lib/originals" -type f 2>/dev/null | wc -l | tr -d ' '
}

# —— 手机 ——

win_adb() { MSYS2_ARG_CONV_EXCL='*' adb -s "${E3_ANDROID_SERIAL:?缺 E3_ANDROID_SERIAL}" "$@"; }

win_phone_state() { win_adb get-state 2>/dev/null | tr -d '\r'; }

win_phone_version() {
  win_adb shell dumpsys package com.hawkeyexb.ppass 2>/dev/null | sed -n 's/^ *versionName=//p' | head -1 | tr -d '\r'
}

win_phone_grant() {
  win_adb shell pm grant com.hawkeyexb.ppass android.permission.READ_MEDIA_IMAGES >/dev/null 2>&1 || true
  win_adb shell pm grant com.hawkeyexb.ppass android.permission.READ_MEDIA_VIDEO >/dev/null 2>&1 || true
  win_adb shell pm grant com.hawkeyexb.ppass android.permission.ACCESS_MEDIA_LOCATION >/dev/null 2>&1 || true
  win_adb shell pm grant com.hawkeyexb.ppass android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
  win_adb shell dumpsys deviceidle whitelist +com.hawkeyexb.ppass >/dev/null 2>&1 || true
}

win_phone_start() { win_adb shell am start -n com.hawkeyexb.ppass/.MainActivity >/dev/null 2>&1; sleep 2; }
win_phone_stop() { win_adb shell am force-stop com.hawkeyexb.ppass >/dev/null 2>&1 || true; }

# win_phone_dump <证据文件>：uiautomator dump 后拉到本地（Windows 路径）。
win_phone_dump() {
  local out="$1" i
  for i in 1 2 3; do
    win_adb shell uiautomator dump /sdcard/ppui.xml >/dev/null 2>&1 || true
    win_adb pull /sdcard/ppui.xml "$(cygpath -w "$out")" >/dev/null 2>&1 && [ -s "$out" ] && return 0
    sleep 1
  done
  return 1
}

win_phone_texts() { python3 -I "$E3_LIB/ui.py" texts "$(cygpath -w "$1")" 2>/dev/null; }
win_phone_has() { python3 -I "$E3_LIB/ui.py" has "$(cygpath -w "$1")" "$2" >/dev/null 2>&1; }
win_phone_find() { python3 -I "$E3_LIB/ui.py" find "$(cygpath -w "$1")" "$2" 2>/dev/null; }

win_phone_tap_xml() { # win_phone_tap_xml <dump> <文字>
  local xy
  xy="$(win_phone_find "$1" "$2")" || return 1
  # shellcheck disable=SC2086
  win_adb shell input tap $xy >/dev/null 2>&1
  sleep 1
}
win_phone_tap_edit() { # win_phone_tap_edit <dump>：点第 1 个 EditText（Compose 的输入框）
  local xy
  xy="$(python3 -I "$E3_LIB/ui.py" class "$(cygpath -w "$1")" EditText 2>/dev/null)" || return 1
  # shellcheck disable=SC2086
  win_adb shell input tap $xy >/dev/null 2>&1
  sleep 1
}

win_phone_tap_text() { # win_phone_tap_text <dump> <文字>（先 dump 再点）
  win_phone_dump "$1" || return 1
  win_phone_tap_xml "$1" "$2"
}
win_phone_input() { win_adb shell "input text '$1'" >/dev/null 2>&1; }

# 推测试照片到 DCIM/PPassRegression 并触发媒体扫描（同名覆盖）。
win_phone_push_photos() {
  local dir="$1" f
  win_adb shell mkdir -p /sdcard/DCIM/PPassRegression >/dev/null 2>&1
  for f in "$dir"/*.jpg; do
    win_adb push "$(cygpath -w "$f")" /sdcard/DCIM/PPassRegression/ >/dev/null 2>&1 || return 1
    win_adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
      -d "file:///sdcard/DCIM/PPassRegression/$(basename "$f")" >/dev/null 2>&1 || true
  done
}

win_phone_hashes() { # win_phone_hashes <输出文件>：PPassRegression 里每张的 sha256
  win_adb shell "cd /sdcard/DCIM/PPassRegression && sha256sum *.jpg" 2>/dev/null | tr -d '\r' | sort >"$1"
}

win_phone_clear_photos() {
  win_adb shell rm -rf /sdcard/DCIM/PPassRegression >/dev/null 2>&1 || true
}

# —— 安装 / 卸载（extract 兜底只在非提权、且场景允许时用） ——

win_release_file() { # win_release_file <tag> <匹配模式>
  local tag="$1" pat="$2"
  ls "$WIN_REL_DIR/$tag"/$pat 2>/dev/null | head -1
}

# 从安装包里取出 App 文件并写 HKCU 卸载登记（等价于 NSIS 装出来的位置与登记）。
# 用户态布局（win/install-baseline、win/upgrade-candidate）用它；报告里必须写明安装器路径未验证。
win_provision_extract() { # win_provision_extract <安装包> <版本>
  local exe="$1" ver="$2" seven
  seven="$(ls "$WIN_TOOLS"/7zfull/Files/7-Zip/7z.exe 2>/dev/null | head -1)"
  [ -n "$seven" ] || { echo "找不到 7z.exe（先按 local-state.md 里的办法解出 7-Zip）" >&2; return 77; }
  mkdir -p "$WIN_APP_DIR"
  win_unregister_task >/dev/null 2>&1 || true
  win_stop_all >/dev/null 2>&1 || true
  if ! "$seven" e "$exe" -o"$(cygpath -w "$WIN_APP_DIR")" -y p-pass-desktop.exe ppf-daemon.exe uninstall.exe >/dev/null 2>&1; then
    # 文件被占用时再停一次重试（daemon 可能刚被看门狗拉起）
    win_stop_all >/dev/null 2>&1 || true
    sleep 1
    "$seven" e "$exe" -o"$(cygpath -w "$WIN_APP_DIR")" -y p-pass-desktop.exe ppf-daemon.exe uninstall.exe >/dev/null || return 1
  fi
  win_ps "
\$key='HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\P-Pass'
New-Item -Path \$key -Force | Out-Null
New-ItemProperty -Path \$key -Name 'InstallLocation' -Value '\"$WIN_APP_DIR_WIN\"' -PropertyType String -Force | Out-Null
New-ItemProperty -Path \$key -Name 'DisplayName' -Value 'P-Pass' -PropertyType String -Force | Out-Null
New-ItemProperty -Path \$key -Name 'DisplayVersion' -Value '$ver' -PropertyType String -Force | Out-Null
New-ItemProperty -Path \$key -Name 'UninstallString' -Value '\"$WIN_APP_DIR_WIN\\uninstall.exe\"' -PropertyType String -Force | Out-Null
" >/dev/null
}

# 真正的安装器路径：提权会话才可用；否则返回 77（记 SKIP）。
win_install_silent() { # win_install_silent <setup.exe>
  local exe="$1"
  win_is_elevated || return 77
  win_ps_file "$WIN_OUTSIDE_PS" -Cmd "\"$(cygpath -w "$exe")\" /S" -Wait 300
}

# 覆盖安装（W3 / R1.2）：安装时 daemon 正在跑，不先停服务。
win_install_overlay() { win_install_silent "$1"; }

# 清卸载登记（#1675）：对齐 tools/windows/reset-ppass-env.ps1 的 -Uninstall 分支。
# perMachine 安装器看到残留的 HKLM 登记会认为已经装过，安装/卸载类场景被卡住。
# 非管理员删不掉时返回非 0；调用方按「清不干净就停下」处理，不静默留残留。
win_reset_uninstall_registry() {
  local out
  out="$(win_ps '
$keys = @(
  "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass",
  "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass",
  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass"
)
foreach ($k in $keys) { Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue }
$left = @($keys | Where-Object { Test-Path $_ })
if ($left.Count -gt 0) { Write-Output ("left: " + ($left -join ", ")); exit 1 }
' 2>&1)" || { echo "卸载登记清不掉（需要管理员权限？）：${out}" >&2; return 1; }
}

# 两处 HKLM 卸载登记都不存在 → yes，否则 no（#1675 的判据）。
# installer 的 pre 快照与 install-baseline 的安装前快照共用同一口径。
win_hklm_uninstall_absent() {
  win_ps 'if ((Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass") -or (Test-Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass")) { "no" } else { "yes" }' 2>/dev/null | tr -d '[:space:]'
}

# 把整个桌面状态清到「全新机器」：停进程、删任务、清卸载登记、删数据目录、把旧库挪走（不硬删）。
win_reset_desktop_state() {
  local lib dest
  # 先按 config.toml 找到旧库，再删数据目录（删完就读不到了）。config 丢了（半途失败）
  # 就退回向导的默认库位置，保证「全新机器」一定没有旧照片。
  lib="$(win_library_dir 2>/dev/null)" || lib=""
  [ -n "$lib" ] && [ -d "$lib" ] || lib="$(cygpath -u "${USERPROFILE}\Pictures\P-Pass Library")"
  win_unregister_task
  win_stop_all || true
  win_reset_uninstall_registry || return 1
  if [ -d "$lib" ]; then
    dest="$E3_STATE/win/old-library-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$E3_STATE/win"
    mv "$lib" "$dest" || { echo "旧照片库挪不走：$lib"; return 1; }
    echo "旧照片库已挪到 $dest"
  fi
  rm -rf "$WIN_DATA_DIR" 2>/dev/null || true
}

# —— 配对 ——

# win_pair <证据目录>：桌面「无法扫码？复制配对串」→ 手机手动输入 → 桌面输验证码并允许加入。
# 配对串含令牌，不写进证据；只在变量里传递。
win_pair() {
  local dir="$1"
  local dump="$dir/pair-desktop.txt" phone_dump="$dir/pair-phone.xml" pair code
  win_ui_dump "$dump" || { echo "配对：桌面 UI dump 失败" >&2; return 1; }
  if ! win_ui_has "$dump" '已配对设备 0 台'; then
    # 已经配对过就不重复配（场景的 setup 负责清到 0 台）
    win_ui_dump "$dump"
  fi
  # 0.10.x 文案「复制配对串」，0.11.x 改成「复制配对码」；两个都试。
  win_ui_click '无法扫码？复制配对码' >/dev/null || win_ui_click '无法扫码？复制配对串' >/dev/null     || { echo "配对：点不到复制配对码/串" >&2; return 1; }
  sleep 1
  pair="$(win_ps 'Get-Clipboard -Raw' 2>/dev/null | tr -d '\r\n')"
  case "$pair" in ppf://pair?*) ;; *) echo "配对：剪贴板不是配对串" >&2; return 1 ;; esac
  win_phone_start
  win_phone_dump "$phone_dump" || { echo "配对：手机 dump 失败" >&2; return 1; }
  # 上一轮配对失败留下的错误页：先点「重新扫码」回到欢迎页。
  if win_phone_has "$phone_dump" '没能连上电脑'; then
    win_phone_tap_xml "$phone_dump" '重新扫码' || true
    sleep 2
    win_phone_dump "$phone_dump" || { echo "配对：手机 dump 失败" >&2; return 1; }
  fi
  win_phone_tap_xml "$phone_dump" '无法扫码？手动输入配对串|无法扫码？手动配对' || { echo "配对：点不到手机手动输入" >&2; return 1; }
  sleep 1
  win_phone_dump "$phone_dump"
  win_phone_tap_xml "$phone_dump" '输入配对码' || win_phone_tap_edit "$phone_dump" || true
  win_phone_input "$pair"
  sleep 1
  win_phone_dump "$phone_dump" || true
  # 输入没落进去（还显示占位符 ppf://pair?node=…）就再点一次输入框重输。
  if ! grep -Eq 'ppf://pair\?node=[0-9a-f]{8}' "$phone_dump"; then
    win_phone_tap_edit "$phone_dump" || true
    win_phone_input "$pair"
    sleep 1
    win_phone_dump "$phone_dump" || true
  fi
  win_phone_tap_text "$phone_dump" '连接' || { echo "配对：点不到手机连接" >&2; return 1; }
  # 手机显示 6 位验证码；桌面输入并允许加入
  for _ in $(seq 1 20); do
    win_phone_dump "$phone_dump" && win_phone_has "$phone_dump" '在电脑上输入这 6 位验证码' && break
    sleep 1
  done
  code="$(python3 -I - "$(cygpath -w "$phone_dump")" <<'PY'
import re, sys, xml.etree.ElementTree as ET
try:
    t = ET.parse(sys.argv[1])
except Exception:
    sys.exit(1)
for n in t.getroot().iter('node'):
    m = re.fullmatch(r'(\d{3}) (\d{3})', (n.get('text') or '').strip())
    if m:
        print(m.group(1) + m.group(2))
        break
PY
)"
  [ -n "$code" ] || { echo "配对：手机没显示 6 位验证码" >&2; return 1; }
  win_ui_wait "$dump" '6 位验证码' 20 || { echo "配对：桌面没出现验证码输入框" >&2; return 1; }
  win_ui_set_edit '6 位验证码' "$code" || { echo "配对：验证码写不进" >&2; return 1; }
  # 首次配对是「允许加入」，被断开过的设备是「请求重新加入」+「允许重新加入」。
  win_ui_click '允许加入' >/dev/null || win_ui_click '允许重新加入' >/dev/null     || { echo "配对：点不到允许加入/允许重新加入" >&2; return 1; }
  for _ in $(seq 1 30); do
    win_ui_dump "$dump" && win_ui_has "$dump" '已配对设备 1 台' && return 0
    sleep 1
  done
  echo "配对：30s 内没变成已配对设备 1 台" >&2
  return 1
}

# —— 等待备份 ——

# win_wait_photo_count <证据目录> <期望总数> <秒>
win_wait_photo_count() {
  local dir="$1" want="$2" secs="${3:-180}" end=$((SECONDS + ${3:-180})) got
  while [ $SECONDS -lt $end ]; do
    if win_diag "$dir" 2>/dev/null; then
      got="$(win_status_field "$dir" photo_count)"
      [ "$got" = "$want" ] && return 0
    fi
    sleep 3
  done
  return 1
}

# —— 观察新窗口（W1） ——

win_watch_start() { # win_watch_start <证据文件> <秒>
  win_ps_file "$WIN_WATCH_PS" -Seconds "$2" >"$1" 2>&1 &
  WIN_WATCH_PID=$!
}
win_watch_wait() { # 返回 watcher 退出码
  [ -n "${WIN_WATCH_PID:-}" ] || return 1
  wait "$WIN_WATCH_PID"
  local rc=$?
  WIN_WATCH_PID=
  return $rc
}

# —— 小工具 ——

win_json_array_len() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d if isinstance(d,list) else d.get("devices",[])))' "$1" 2>/dev/null; }
win_sleep() { sleep "$1"; }

# 常见判据的管道封装：check 的行里不能出现管道符（管道会把 check 放进子 shell，E3_FAILS 丢失）。
# 「文件里没有坏行」类判据必须先要求证据文件存在且非空——文件缺失/为空时 no_line 会放过，
# 等于把「没采到证据」当成「没有问题」（评审非阻塞 2）。
no_line_panic() { [ -s "$1" ] && no_line "$1" 'panicked|PANIC'; }
samples_no_daemon() { [ -s "$1" ] && no_line "$1" 'pid=[0-9]'; }
same_nonempty() { [ -s "$1" ] && [ -s "$2" ] && cmp -s "$1" "$2"; }
