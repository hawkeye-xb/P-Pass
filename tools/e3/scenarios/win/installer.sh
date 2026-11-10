# R0.2/R1.2/W3/W5：Windows 真实安装器的语义（desktop-only，不碰手机、不开 adb）。
#
# 覆盖：
#   R0.2  用 Latest v2026.10.7 的真实安装包装 0.10.1（从干净的 ProgramData 开始）：
#         Program Files 落盘、写 HKLM 卸载登记、注册并启动 Windows 服务 P-Pass。
#   R1.2  覆盖安装候选（默认 v0.11.0-test.1，可用 E3_WIN_CAND_TAG 换包；daemon 服务运行中，
#         PREINSTALL 先停服务），版本一致。
#   W3    就是 R1.2 的安装时 daemon 正在跑：不先手动停服务，安装成功、装完是新版本。
#   W5    真实卸载：服务/程序被删、旧计划任务残留被清、70s 内没有 daemon；ProgramData
#         （身份/配对存储 devices.json）、壳数据目录（config.toml）和照片库（originals
#         清单 + daemon photo_count）卸载前后一致；重装候选并打开 App 直接进主界面
#         （不走向导/不用重新配对）、照片不重不计、服务恢复、身份 key 不变。
#         本场景桌面端独立完成、不接手机；配对保留按 devices.json 与身份 key 前后一致判。
#
# 安装器是 perMachine（requireAdministrator）：每一步经 Start-Process -Verb RunAs 弹 UAC，
# 由人点「是」。每步前打印「UAC：请点是 —— <装什么>」，最多等 3 分钟（没人点就停）。
# 提权的那一步顺带做两件事（不额外弹框）：装/卸后等/查服务状态；把 ProgramData 的
# identity.key 哈希和 daemon 启动日志写到证据目录——非提权读不到受保护 DACL 下的文件。
# 干净起点下服务是「未配置」的，W5 前用桌面壳的首启向导配一次库，服务才会铸造身份。
# 反证：卸载后不重装，按同一套判据判 ⇒ 重装后的服务/版本判据必须变红；teardown 装回候选。
DESC="R0.2/R1.2/W3/W5：真实安装器装 0.10.1 → 覆盖候选 → 卸载保留数据 → 重装（每步 UAC）"
COUNTER=on

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

INST_DIR_WIN="${PROGRAMFILES}\\P-Pass"
INST_DIR="$(cygpath -u "$INST_DIR_WIN")"
INST_EXE="$INST_DIR/p-pass-desktop.exe"
INST_DAEMON="$INST_DIR/ppf-daemon.exe"
INST_UNINSTALL="$INST_DIR/uninstall.exe"
PD_DIR_WIN="${ProgramData:-C:\ProgramData}\P-Pass"
PD_DIR="$(cygpath -u "$PD_DIR_WIN")"
# 服务模式下 daemon 的 config.toml（含库位置）在 ProgramData，不在用户态数据目录。
WIN_CONF_DIR="$PD_DIR"
UA_WAIT="${E3_WIN_UAC_WAIT:-180}"

# 提权辅助脚本：装/卸包 +（可选）搬走 ProgramData + 采身份哈希/日志。
# ASCII only：PowerShell 5.1 读无 BOM 的 .ps1 时中文会乱码，这里不写中文。
write_elev_ps() {
  cat >"$ELEV_PS" <<'PS1'
param(
  [string]$Installer = '',
  [string]$InstallerArgs = '/S',
  [string]$Out = '',
  [string]$CopyLogsTo = '',
  [string]$MoveDataDirTo = '',
  [int]$WaitServiceSecs = 0
)
$ErrorActionPreference = 'Stop'
$lines = New-Object 'System.Collections.Generic.List[string]'
function Emit-Out {
  if ($Out -ne '') { $lines | Set-Content -LiteralPath $Out -Encoding ASCII }
}
try {
  $key = Join-Path $env:ProgramData 'P-Pass\identity.key'
  if ($Out -ne '') {
    if (Test-Path -LiteralPath $key) {
      $lines.Add('identity_before_sha256=' + (Get-FileHash -LiteralPath $key -Algorithm SHA256).Hash.ToLower())
    } else {
      $lines.Add('identity_before_sha256=')
    }
    Emit-Out
  }
  if ($MoveDataDirTo -ne '') {
    $src = Join-Path $env:ProgramData 'P-Pass'
    if (Test-Path -LiteralPath $src) {
      if (Test-Path -LiteralPath $MoveDataDirTo) {
        Move-Item -LiteralPath $MoveDataDirTo -Destination ($MoveDataDirTo + '.bak-' + (Get-Date -Format 'yyyyMMddHHmmss')) -Force
      }
      Move-Item -LiteralPath $src -Destination $MoveDataDirTo -Force
      $lines.Add('moved_datadir=' + $MoveDataDirTo)
    } else {
      $lines.Add('moved_datadir=none')
    }
    Emit-Out
  }
  if ($Installer -ne '') {
    $p = Start-Process -FilePath $Installer -ArgumentList $InstallerArgs -PassThru -Wait -ErrorAction Stop
    $lines.Add('installer_exit=' + $p.ExitCode)
    $svc = $null
    if ($WaitServiceSecs -gt 0) {
      $deadline = (Get-Date).AddSeconds($WaitServiceSecs)
      while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name 'P-Pass' -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { break }
        Start-Sleep -Milliseconds 500
      }
    } else {
      $svc = Get-Service -Name 'P-Pass' -ErrorAction SilentlyContinue
    }
    if ($svc) { $lines.Add('svc_state=' + $svc.Status.ToString()) } else { $lines.Add('svc_state=Absent') }
    Emit-Out
  }
  if ($CopyLogsTo -ne '') {
    New-Item -ItemType Directory -Force -Path $CopyLogsTo | Out-Null
    $root = Join-Path $env:ProgramData 'P-Pass'
    $logdir = Join-Path $root 'logs'
    Get-ChildItem -LiteralPath $logdir -File -ErrorAction SilentlyContinue | ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination $CopyLogsTo -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue |
      Select-Object Name, Length, LastWriteTime | Out-File (Join-Path $CopyLogsTo 'datadir-files.txt') -Encoding utf8
    icacls $root | Out-File (Join-Path $CopyLogsTo 'datadir-acl.txt') -Encoding utf8
  }
  if ($Out -ne '') {
    $key = Join-Path $env:ProgramData 'P-Pass\identity.key'
    if (Test-Path -LiteralPath $key) {
      $lines.Add('identity_sha256=' + (Get-FileHash -LiteralPath $key -Algorithm SHA256).Hash.ToLower())
    } else {
      $lines.Add('identity_sha256=')
    }
    $lines.Add('elev_ok=1')
  }
} catch {
  $lines.Add('elev_error=' + $_.Exception.Message)
}
Emit-Out
if ($Out -ne '') { Set-Content -LiteralPath ($Out + '.done') -Value 'done' -Encoding ASCII }
exit 0
PS1
}

# elev_step <说明> <辅助脚本参数…>：打印提示后弹 UAC，等人在 Windows 上点「是」。
# 路径里有空格（Program Files），每个参数都加双引号再交给 Start-Process；
# PS 5.1 的 -ArgumentList 数组只是按空格拼接，不会自动加引号。
elev_step() {
  local desc="$1"; shift
  local psargs='' a v out_win='' prev=''
  for a in "$@"; do
    v="$(printf '%s' "$a" | sed "s/'/''/g")"
    psargs="$psargs,'\"$v\"'"
    [ "$prev" = '-Out' ] && out_win="$a"
    prev="$a"
  done
  echo "UAC：请点是 —— $desc"
  local out rc done_file i code enc
  # 只给「等 UAC 点击」计时：Start-Process 在 UAC 有结果后立即返回（不 -Wait），
  # 180 秒没人点就停（timeout 杀掉请求，不另起新框）；提权进程跑多久由 done 文件等。
  # timeout 只能跑外部命令，不能包 win_ps 这个 shell 函数，所以这里自己编码。
  code="\$ProgressPreference='SilentlyContinue'; \$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; try { \$p = Start-Process powershell.exe -Verb RunAs -PassThru -ErrorAction Stop -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','$ELEV_PS_WIN'$psargs); Write-Output ('STARTED=' + \$p.Id); exit 0 } catch { Write-Output ('UAC_CANCEL: ' + \$_.Exception.Message); exit 122 }"
  enc="$(printf '%s' "$code" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
  out="$(timeout "$UA_WAIT" powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand "$enc" 2>&1)"
  rc=$?
  echo "$out"
  if [ $rc -eq 124 ]; then echo "UAC_TIMEOUT：${desc}（${UA_WAIT}s 内没人点，停止）"; return 1; fi
  [ $rc -eq 0 ] || return 1
  [ -n "$out_win" ] || { echo "elev_step 缺 -Out，无法等完成"; return 1; }
  done_file="$(cygpath -u "$out_win").done"
  for i in $(seq 1 600); do
    [ -f "$done_file" ] && return 0
    sleep 1
  done
  echo "RUN_TIMEOUT：${desc}（提权步骤 600s 未完成）"
  return 1
}

svc_state() { win_ps "(Get-Service -Name 'P-Pass' -ErrorAction SilentlyContinue).Status" 2>/dev/null | tr -d '[:space:]'; }
svc_exists() { win_ps "if (Get-Service -Name 'P-Pass' -ErrorAction SilentlyContinue) { 'yes' } else { 'no' }" 2>/dev/null | tr -d '[:space:]'; }
svc_binpath() { win_ps "(Get-CimInstance Win32_Service -Filter \"Name='P-Pass'\").PathName" 2>/dev/null | tr -d '\r'; }
hklm_version() { win_ps "(Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\P-Pass' -ErrorAction SilentlyContinue).DisplayVersion" 2>/dev/null | tr -d '[:space:]'; }
inst_exe_version() { win_ps "(Get-Item '$INST_DIR_WIN\\p-pass-desktop.exe' -ErrorAction SilentlyContinue).VersionInfo.ProductVersion" 2>/dev/null | tr -d '[:space:]'; }
pd_wanted() { cat "$PD_DIR/wanted-state" 2>/dev/null | tr -d '\r\n'; }
config_hash() { local c; c="$(win_config_file)" || return 0; sha256sum "$c" 2>/dev/null | awk '{print $1}'; }

wait_installed() { # wait_installed <版本>：等安装目录的 exe 出现且版本对上
  local ver="$1" i
  for i in $(seq 1 60); do
    [ -f "$INST_EXE" ] && [ "$(inst_exe_version)" = "$ver" ] && return 0
    sleep 1
  done
  return 1
}
wait_uninstalled() { # 等程序目录的 exe 和服务都消失（NSIS 卸载器会再拉起一个副本，-Wait 可能先返回）
  local i
  for i in $(seq 1 60); do
    [ ! -f "$INST_EXE" ] && [ "$(svc_exists)" = no ] && return 0
    sleep 1
  done
  return 1
}

# 装好后的 diag：用安装目录里的 daemon（服务模式，连 ppf-svc）。
diag_inst() { # diag_inst <证据目录>
  local d="$1" zip="$d/diag.zip" i
  mkdir -p "$d"
  rm -f "$zip"
  rm -rf "$d/diag"
  win_ps "& '$(cygpath -w "$INST_DAEMON")' diag export --out '$(cygpath -w "$zip")' --app-version '$(inst_exe_version)'" >"$d/diag-export.txt" 2>&1 || true
  for i in $(seq 1 25); do [ -s "$zip" ] && break; sleep 0.2; done
  if [ -s "$zip" ]; then
    mkdir -p "$d/diag"
    unzip -oq "$zip" -d "$d/diag" >/dev/null 2>&1 || true
  fi
  [ -f "$d/diag/status.json" ]
}
diag_ver() { jget "$1/diag/status.json" "j['version']" 2>/dev/null; }

snapshot_state() { # snapshot_state <证据目录> <名字>
  local d="$1" tag="$2" ts dev lh
  # diag 先跑：devices / photo_count 从这次导出取；卸载后没有 daemon，这两项为空。
  diag_inst "$d/$tag-diag" || true
  diag_ver "$d/$tag-diag" >"$d/$tag-diag-version.txt" 2>/dev/null || true
  cp "$d/$tag-diag/diag/devices.json" "$d/$tag-devices.json" 2>/dev/null || true
  ts="$(win_task_state)"
  dev="$(win_json_array_len "$d/$tag-devices.json" 2>/dev/null)"
  # 库 originals 全量清单：卸载/重装都不该动文件（不丢、不重传成两份）。
  lh="$d/$tag-library"
  mkdir -p "$lh"
  win_library_hashes "$lh" >/dev/null 2>&1 || true
  {
    echo "inst_exe_version=$(inst_exe_version)"
    echo "hklm_version=$(hklm_version)"
    echo "svc_state=$(svc_state)"
    echo "svc_binpath=$(svc_binpath)"
    echo "pd_dir=$([ -d "$PD_DIR" ] && echo present || echo absent)"
    echo "pd_wanted=$(pd_wanted)"
    echo "config_hash=$(config_hash)"
    echo "daemon_pid=$(win_daemon_pid)"
    echo "inst_exe_present=$([ -f "$INST_EXE" ] && echo yes || echo no)"
    echo "svc_exists=$(svc_exists)"
    echo "task=${ts:-none}"
    echo "devices=${dev}"
    echo "photo_count=$(win_status_field "$d/$tag-diag" photo_count 2>/dev/null)"
    echo "library=$(win_library_dir_win 2>/dev/null || true)"
    echo "library_files=$(wc -l <"$lh/library-hashes.txt" 2>/dev/null | tr -d ' ')"
    echo "library_hash=$(sha256sum "$lh/library-hashes.txt" 2>/dev/null | awk '{print $1}')"
  } >"$d/$tag.txt"
}

# 清掉上一轮的 extract 安装（不是被测对象）；壳数据目录/库不在这里清，
# 由 setup 里的 win_reset_desktop_state 清（残留会让首启向导被跳过，见 #1607）。
clean_extract_install() {
  win_unregister_task >/dev/null 2>&1 || true
  win_stop_all >/dev/null 2>&1 || true
  rm -rf "$WIN_APP_DIR" 2>/dev/null || true
  win_ps "Remove-Item 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\P-Pass' -Recurse -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
}

# 起 Program Files 里装好的壳（不是 %LOCALAPPDATA% 的 extract 版）。按 SOP §9.0 用
# Win32_Process.Create 起，cmd 立即退出，不留输出占用。
start_installed_app() {
  win_ps "\$r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = 'cmd.exe /c start \"\" \"$(cygpath -w "$INST_EXE")\"' }" >/dev/null 2>&1 || true
}

# 干净起点下服务是「未配置」的（没有库位置/主人）。走一遍桌面壳的首启向导：
# 壳建库目录并授服务账户权限，再经 IPC config.set_library 交给服务；服务重启后
# 铸造身份。W5 的身份判据以这次配置为前提。
main_ui_ready() { win_ui_has "$1" '添加设备' || win_ui_has "$1" '后台服务运行中'; }

configure_service() { # configure_service <证据目录>
  local d="$1" i ok=0
  start_installed_app
  # 文案按 Windows 版首启向导（WizardWindows.svelte）取，不是 macOS 那套。
  win_ui_wait "$d/wizard-1.txt" '选择照片库位置' 60 || { echo "向导第 1 步没出现"; win_ui_dump "$d/wizard-1.txt" || true; return 1; }
  win_ui_click '继续' >/dev/null || { echo "点不到继续（第 1 步）"; return 1; }
  win_ui_wait "$d/wizard-2.txt" '防止电脑睡眠' 30 || { echo "向导第 2 步没出现"; win_ui_dump "$d/wizard-2.txt" || true; return 1; }
  win_ui_click '继续' >/dev/null || { echo "点不到继续（第 2 步）"; return 1; }
  win_ui_wait "$d/wizard-3.txt" '设为后台服务' 30 || { echo "向导第 3 步没出现"; win_ui_dump "$d/wizard-3.txt" || true; return 1; }
  win_ui_click '完成' >/dev/null || { echo "点不到完成"; return 1; }
  for i in $(seq 1 40); do
    win_ui_dump "$d/desktop-main.txt" || true
    main_ui_ready "$d/desktop-main.txt" && { ok=1; break; }
    sleep 2
  done
  [ "$ok" = 1 ]
}

setup() {
  ELEV_PS="$EV/install-elev.ps1"
  ELEV_PS_WIN="$(cygpath -w "$ELEV_PS")"
  write_elev_ps
  command -v adb >/dev/null 2>&1 && echo "（本场景不需要 adb，不调用）"
  WIN_BASE_EXE="$(win_release_file "$WIN_BASE_TAG" '*_x64-setup.exe')"
  WIN_CAND_EXE="$(win_release_file "$WIN_CAND_TAG" '*_x64-setup.exe')"
  [ -n "$WIN_BASE_EXE" ] || { echo "缺基线安装包"; return 77; }
  [ -n "$WIN_CAND_EXE" ] || { echo "缺候选安装包"; return 77; }
  echo "基线安装包：${WIN_BASE_EXE}（sha256 $(sha256sum "$WIN_BASE_EXE" | awk '{print $1}')）"
  echo "候选安装包：${WIN_CAND_EXE}（sha256 $(sha256sum "$WIN_CAND_EXE" | awk '{print $1}')）"
  # 从这里开始动机器；teardown 只在动过之后才补装候选。
  TOUCHED=1
  # R0.2 从干净环境开始：先卸掉上一轮留下的真实安装，再把旧 ProgramData 移到一边
  # （不删除，留作对照）。不重置的话，旧身份/ACL 会让「首次安装」用例失真。
  # 卸载必须排在最前：clean_extract_install 里的 win_stop_all 会直接杀掉 ppf-daemon，
  # 而它就是 Windows 服务 P-Pass 的进程；服务配了失败恢复（重启，延迟 5s），被杀后
  # SCM 会把它拉回来，程序目录一直被占用，卸载器删不掉（#1624）。
  if [ -f "$INST_EXE" ] || [ "$(svc_exists)" = yes ]; then
    if [ -f "$INST_UNINSTALL" ]; then
      elev_step "卸载现有 P-Pass（为 R0.2 准备干净环境）" \
        -Installer "$(cygpath -w "$INST_UNINSTALL")" -InstallerArgs '/S' -WaitServiceSecs 0 \
        -Out "$(cygpath -w "$EV/main/setup-uninstall.txt")" || { echo "卸载现有安装失败/取消"; return 1; }
      wait_uninstalled || { echo "卸载后程序目录/服务没消失"; return 1; }
    else
      echo "服务/程序在，但找不到卸载器 $INST_UNINSTALL"
      return 1
    fi
  fi
  clean_extract_install
  # 壳数据目录（config.toml/库位置）也必须清：残留会让 perMachine App 启动时读到
  # 旧配置、跳过首启向导，服务没有库配置就一直 STOPPED（#1607）。旧照片库一并
  # 挪走（不硬删），保证「全新机器」语义。清不干净就停下，否则后续 E3 分不清是
  # 场景没清还是产品没修。
  win_reset_desktop_state || { echo "清桌面状态失败（壳 config 可能残留）"; return 1; }
  if [ -d "$PD_DIR" ]; then
    local pd_old="$PD_DIR_WIN.pre-e3-$(date +%Y%m%d-%H%M%S)"
    elev_step "把旧 ProgramData\\P-Pass 移到一边（R0.2 干净起点，不删除）" \
      -MoveDataDirTo "$pd_old" -Out "$(cygpath -w "$EV/main/setup-move-pd.txt")" || { echo "搬走 ProgramData 失败/取消"; return 1; }
  fi
  snapshot_state "$EV/main" pre
  echo "--- 安装前 ---"; cat "$EV/main/pre.txt"
}

act() {
  local d="$OUT"
  snapshot_state "$d" pre
  # R0.2：真实基线安装器（干净 ProgramData）。顺带把 daemon 启动日志拷出来——
  # 服务如果起不来，启动失败的原文就在里面。
  elev_step "安装基线 P-Pass ${WIN_BASE_VER}（perMachine，服务模式）" \
    -Installer "$(cygpath -w "$WIN_BASE_EXE")" -InstallerArgs '/S' -WaitServiceSecs 15 \
    -CopyLogsTo "$(cygpath -w "$d/after-baseline-logs")" \
    -Out "$(cygpath -w "$d/after-baseline-install.txt")" || { echo "基线安装失败/取消"; return 1; }
  wait_installed "$WIN_BASE_VER" || echo "基线安装后等不到 $WIN_BASE_VER 的 exe"
  sleep 5
  snapshot_state "$d" after-baseline

  # R1.2 + W3：daemon 服务运行中直接覆盖候选（不先停服务）
  echo "svc_state=$(svc_state)" >"$d/pre-candidate-service.txt"
  echo "安装前服务状态：$(svc_state)"
  elev_step "覆盖安装候选 P-Pass ${WIN_CAND_VER}（服务运行中）" \
    -Installer "$(cygpath -w "$WIN_CAND_EXE")" -InstallerArgs '/S' -WaitServiceSecs 60 \
    -Out "$(cygpath -w "$d/after-candidate-install.txt")" || { echo "候选覆盖安装失败/取消"; return 1; }
  wait_installed "$WIN_CAND_VER" || echo "候选安装后等不到 $WIN_CAND_VER 的 exe"
  sleep 5
  snapshot_state "$d" after-candidate

  # 干净起点下服务未配置：用首启向导配一次库（建目录、授服务账户、写库位置），
  # 服务重启后铸造身份——W5 的身份/配对数据保留才有东西可验。
  if configure_service "$d"; then
    echo "服务已配置（向导走完）"
  else
    echo "服务配置失败：W5 身份判据将不成立（继续跑，让 judge 判红）"
  fi
  snapshot_state "$d" after-configure

  # W5 第一半：真实卸载；随后 70s 采样没有 daemon
  elev_step "卸载 P-Pass（W5：验证服务/程序删除、数据保留）" \
    -Installer "$(cygpath -w "$INST_UNINSTALL")" -InstallerArgs '/S' -WaitServiceSecs 0 \
    -Out "$(cygpath -w "$d/after-uninstall-install.txt")" || { echo "卸载失败/取消"; return 1; }
  wait_uninstalled || echo "卸载后程序目录/服务没消失"
  : >"$d/uninstall-samples.txt"
  local i pid
  # 先等满 10s 再采，标签与实际时刻一致；最后一个采样落在 70s（窗口末尾）。
  for i in $(seq 10 10 70); do
    sleep 10
    pid="$(win_daemon_pid)"
    echo "t+${i}s pid=${pid} svc=$(svc_state)" >>"$d/uninstall-samples.txt"
  done
  snapshot_state "$d" after-uninstall

  # W5 第二半：重装候选，服务恢复、ProgramData 身份不变
  elev_step "重装候选 P-Pass ${WIN_CAND_VER}（W5：验证服务恢复、身份保留）" \
    -Installer "$(cygpath -w "$WIN_CAND_EXE")" -InstallerArgs '/S' -WaitServiceSecs 60 \
    -Out "$(cygpath -w "$d/after-reinstall-install.txt")" || { echo "重装失败/取消"; return 1; }
  wait_installed "$WIN_CAND_VER" || echo "重装后等不到 $WIN_CAND_VER 的 exe"
  sleep 8
  snapshot_state "$d" after-reinstall
  # SOP W5：重装并打开 App 后应直接进主界面——配置和配对都还在，不该再出首启向导。
  start_installed_app
  local j ok=0
  for j in $(seq 1 45); do
    win_ui_dump "$d/reinstall-main.txt" || true
    main_ui_ready "$d/reinstall-main.txt" && { ok=1; break; }
    sleep 2
  done
  [ "$ok" = 1 ] || echo "重装后打开 App 没进主界面（可能又出了首启向导）"
}

# ProgramData 里的 identity.key 是服务模式下的身份私钥（受保护 DACL，只有管理员能读哈希）。
# 用卸载步骤里的 before/after 两次哈希：向导配置后已铸造（before 非空），卸载不动它
# （after 相同），重装后还是同一个（reinstall 相同）。
# 提权脚本用 Set-Content 写证据（CRLF），取值时统一去掉 \r。
identity_hash() { grep -o '^identity_sha256=.*' "$1" 2>/dev/null | cut -d= -f2 | tr -d '\r'; }
identity_before_hash() { grep -o '^identity_before_sha256=.*' "$1" 2>/dev/null | cut -d= -f2 | tr -d '\r'; }
identity_present_and_same() {
  local b c d
  b="$(identity_before_hash "$1/after-uninstall-install.txt")"
  c="$(identity_hash "$1/after-uninstall-install.txt")"
  d="$(identity_hash "$1/after-reinstall-install.txt")"
  [ -n "$b" ] && [ "$b" = "$c" ] && [ "$b" = "$d" ]
}
config_unchanged() {
  local a b
  a="$(grep -o '^config_hash=.*' "$1/after-configure.txt" 2>/dev/null | cut -d= -f2)"
  b="$(grep -o '^config_hash=.*' "$1/after-uninstall.txt" 2>/dev/null | cut -d= -f2)"
  [ -n "$a" ] && [ "$a" = "$b" ]
}
same_field() { # same_field <证据目录> <字段> <tagA> <tagB>：两边都有值且相等
  local a b
  a="$(sed -n "s/^$2=//p" "$1/$3.txt" 2>/dev/null | head -1)"
  b="$(sed -n "s/^$2=//p" "$1/$4.txt" 2>/dev/null | head -1)"
  [ -n "$a" ] && [ "$a" = "$b" ]
}

judge() {
  local d="$1"
  # R0.2
  check "R0.2 基线 exe 版本 $WIN_BASE_VER" grep -Fqx "inst_exe_version=$WIN_BASE_VER" "$d/after-baseline.txt"
  check "R0.2 HKLM 卸载登记 $WIN_BASE_VER" grep -Fqx "hklm_version=$WIN_BASE_VER" "$d/after-baseline.txt"
  check "R0.2 服务 P-Pass 在运行" grep -qx 'svc_state=Running' "$d/after-baseline.txt"
  check "R0.2 服务路径指向 Program Files 安装目录" grep -Fq "$INST_DIR_WIN\\ppf-daemon.exe" "$d/after-baseline.txt"
  check "R0.2 daemon 版本 ${WIN_BASE_VER}（服务 diag）" eq_file "$d/after-baseline-diag-version.txt" "$WIN_BASE_VER"
  check "R0.2 ProgramData 已由安装器建立" grep -qx 'pd_dir=present' "$d/after-baseline.txt"
  # R1.2 / W3
  check "W3 覆盖安装前服务是运行中" grep -qx 'svc_state=Running' "$d/pre-candidate-service.txt"
  check "R1.2 候选 exe 版本 $WIN_CAND_VER" grep -Fqx "inst_exe_version=$WIN_CAND_VER" "$d/after-candidate.txt"
  check "R1.2 HKLM 卸载登记 $WIN_CAND_VER" grep -Fqx "hklm_version=$WIN_CAND_VER" "$d/after-candidate.txt"
  check "R1.2 服务仍在运行" grep -qx 'svc_state=Running' "$d/after-candidate.txt"
  check "R1.2 服务路径仍是 Program Files 安装目录" grep -Fq "$INST_DIR_WIN\ppf-daemon.exe" "$d/after-candidate.txt"
  check "R1.2 daemon 版本 ${WIN_CAND_VER}（服务 diag）" eq_file "$d/after-candidate-diag-version.txt" "$WIN_CAND_VER"
  # W5
  check "W5 前置：服务已配置（向导走完，主界面总览）" main_ui_ready "$d/desktop-main.txt"
  check "W5 卸载后程序目录里没有 exe" grep -qx 'inst_exe_present=no' "$d/after-uninstall.txt"
  check "W5 卸载后服务不存在" grep -qx 'svc_exists=no' "$d/after-uninstall.txt"
  check "W5 卸载后 70s 内没有 daemon" samples_no_daemon "$d/uninstall-samples.txt"
  check "W5 卸载后 ProgramData 保留" grep -qx 'pd_dir=present' "$d/after-uninstall.txt"
  check "W5 卸载后壳 config.toml 不变" config_unchanged "$d"
  check "W5 卸载后库目录不变（config.toml 的 data_dir）" same_field "$d" library after-configure after-uninstall
  check "W5 卸载后照片库 originals 清单不变（库还在、没丢图）" same_field "$d" library_hash after-configure after-uninstall
  check "W5 卸载后计划任务已删除（旧任务无残留）" grep -qx 'task=none' "$d/after-uninstall.txt"
  check "W5 卸载前后身份 key 是同一个（读 ProgramData）" identity_present_and_same "$d"
  check "W5 重装后服务在运行" grep -qx 'svc_state=Running' "$d/after-reinstall.txt"
  check "W5 重装后 daemon 版本 $WIN_CAND_VER" eq_file "$d/after-reinstall-diag-version.txt" "$WIN_CAND_VER"
  check "W5 重装后配对存储 devices.json 不变" same_nonempty "$d/after-configure-devices.json" "$d/after-reinstall-devices.json"
  check "W5 重装后配对台数不变" same_field "$d" devices after-configure after-reinstall
  check "W5 重装后照片数不变（不重传/不重复入库）" same_field "$d" photo_count after-configure after-reinstall
  check "W5 重装后照片库 originals 清单不变（不重传/不重复）" same_field "$d" library_hash after-configure after-reinstall
  check "W5 重装后打开 App 直接进主界面（不用重新配对/配置）" main_ui_ready "$d/reinstall-main.txt"
  verdict
}

counter() {
  local d="$OUT"
  # 故障条件：卸载后不重装（去掉「已安装」状态），再按同一套判据判 ⇒
  # 重装后的服务/版本判据必须变红。前半段安装证据照抄主路径，只重放卸载与「不重装」。
  echo "counter: 卸载后不重装（去掉已安装状态）" >"$d/note.txt"
  cp "$EV/main"/*.txt "$d/" 2>/dev/null || true
  cp -r "$EV/main"/*-diag "$d/" 2>/dev/null || true
  if [ -x "$INST_UNINSTALL" ]; then
    elev_step "卸载 P-Pass（反证：卸载后不重装）" \
      -Installer "$(cygpath -w "$INST_UNINSTALL")" -InstallerArgs '/S' -WaitServiceSecs 0 \
      -Out "$(cygpath -w "$d/after-uninstall-install.txt")" || true
    wait_uninstalled || true
  fi
  sleep 3
  snapshot_state "$d" after-uninstall
  # 「重装」这一步没有发生：after-reinstall 的证据就是卸载后的机器现状。
  # 身份哈希沿用卸载步骤采到的那一份（没有重装动作可采）。
  cp "$d/after-uninstall-install.txt" "$d/after-reinstall-install.txt" 2>/dev/null || true
  snapshot_state "$d" after-reinstall
}

teardown() {
  # setup 在返回 77 之前什么都没动：不弹 UAC、不往本场景没碰过的机器上装东西。
  [ "${TOUCHED:-0}" = 1 ] || return 0
  # 若最后没装回来（counter/失败），重新装候选并等服务恢复。
  if [ ! -f "$INST_EXE" ]; then
    echo "收尾：重新安装候选"
    if [ -f "$WIN_CAND_EXE" ]; then
      elev_step "收尾重装候选 P-Pass $WIN_CAND_VER" \
        -Installer "$(cygpath -w "$WIN_CAND_EXE")" -InstallerArgs '/S' -WaitServiceSecs 60 \
        -Out "$(cygpath -w "$EV/teardown-install.txt")" || return 0
      wait_installed "$WIN_CAND_VER" || true
    fi
  fi
  return 0
}
