# R1.1/R1.2/R1.4：从基线 0.10.1 覆盖升级到候选 0.11.0-test.1（桌面 + 手机），版本一致，
# 配对、身份、照片库都不丢。
#
# 桌面安装器提权才可用；非提权且 E3_WIN_PROVISION=extract 时用候选安装包载荷覆盖
# %LOCALAPPDATA%\P-Pass 并改 HKCU 卸载登记（安装器路径未验证，报告写明）。
# 反证：不装候选、直接对升级前快照跑同一套判据 ⇒ 版本判据必须变红（用 setup 里
# 真实采集的 before 证据，不降级、不动库）。
DESC="R1.1/R1.2/R1.4：覆盖升级到候选 0.11.0-test.1，桌面/daemon/手机版本一致，配对与照片不丢"
COUNTER=on

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

snapshot() { # snapshot <证据目录> <前缀>
  local d="$1" p="$2" lib
  lib="$(win_library_dir)" || return 1
  win_diag "$d" || true
  cp "$d/diag/status.json" "$d/$p-status.json" 2>/dev/null || true
  cp "$d/diag/devices.json" "$d/$p-devices.json" 2>/dev/null || true
  cp "$d/diag/daemon.log" "$d/$p-daemon.log" 2>/dev/null || true
  local ikey
  ikey="$(win_identity_key 2>/dev/null)" || ikey=""
  if [ -n "$ikey" ]; then sha256sum "$ikey" | awk '{print $1}' >"$d/$p-identity.txt"; else : >"$d/$p-identity.txt"; fi
  win_library_hashes "$d" >/dev/null 2>&1 || true
  cp "$d/library-hashes.txt" "$d/$p-library-hashes.txt" 2>/dev/null || true
  {
    echo "exe_version=$(win_exe_version)"
    echo "install_version=$(win_app_version)"
    echo "phone_version=$(win_phone_version)"
    echo "status_version=$(win_status_field "$d" version)"
    echo "photo_count=$(win_status_field "$d" photo_count)"
    echo "devices=$(win_json_array_len "$d/diag/devices.json")"
  } >"$d/$p-versions.txt"
}

setup() {
  win_app_running || { echo "桌面 App 没在跑（先跑 win/install-baseline）"; return 77; }
  win_daemon_running || { echo "daemon 没在跑（先跑 win/install-baseline）"; return 77; }
  [ "$(win_app_version)" = "$WIN_BASE_VER" ] || { echo "桌面安装版本不是基线 ${WIN_BASE_VER}：$(win_app_version)（先跑 win/install-baseline）"; return 77; }
  [ "$(win_phone_version)" = "$WIN_BASE_PHONE_VER" ] || { echo "手机不是基线 ${WIN_BASE_PHONE_VER}：$(win_phone_version)"; return 77; }
  win_diag "$EV/main" >/dev/null 2>&1 || true
  [ "$(win_json_array_len "$EV/main/diag/devices.json")" = 1 ] || { echo "桌面没有 1 台配对设备（先跑 win/pair-backup）"; return 77; }
  # 候选包
  local exe
  exe="$(win_release_file "$WIN_CAND_TAG" '*_x64-setup.exe')"
  [ -n "$exe" ] || { echo "缺候选安装包（$WIN_REL_DIR/$WIN_CAND_TAG/*_x64-setup.exe）"; return 77; }
  echo "候选安装包：$exe"
  echo "sha256：$(sha256sum "$exe" | awk '{print $1}')"
  echo "--- 升级前快照 ---"
  snapshot "$EV/main" pre
  cat "$EV/main/pre-versions.txt"
}

act() {
  local d="$OUT" exe
  snapshot "$d" pre
  exe="$(win_release_file "$WIN_CAND_TAG" '*_x64-setup.exe')"
  # 覆盖安装：先停壳与 daemon（安装器的 PREINSTALL 钩子在 extract 路径下没有，手动做）。
  # **保留计划任务**：真实安装器不删它，POSTINSTALL 会重新运行任务；删了壳会以为没装过、重走向导。
  win_stop_all || { echo "停不掉桌面 App/daemon"; return 1; }
  if win_is_elevated; then
    win_install_silent "$exe" || { echo "候选安装器失败"; return 1; }
    echo "provision=installer" >"$d/provision.txt"
  elif [ "${E3_WIN_PROVISION:-}" = extract ]; then
    win_provision_extract "$exe" "$WIN_CAND_VER" || { echo "候选解包安装失败"; return 1; }
    echo "provision=extract" >"$d/provision.txt"
  else
    echo "跳过：安装器需要 UAC 提权（requireAdministrator）；提权会话重跑，或设 E3_WIN_PROVISION=extract"
    return 1
  fi
  # 手机覆盖安装候选 APK（保留数据）。
  local apk
  apk="$(win_release_file "$WIN_CAND_TAG" '*_android.apk')"
  [ -n "$apk" ] || { echo "缺候选 APK"; return 1; }
  win_adb install -r "$(cygpath -w "$apk")" >/dev/null || { echo "候选 APK 覆盖安装失败"; return 1; }
  win_phone_grant
  # 模拟安装器的 POSTINSTALL：运行计划任务拉起新 daemon；任务不在才手动起。
  local i
  if [ -n "$(win_task_state)" ]; then
    win_ps "schtasks /run /tn P-Pass" >/dev/null 2>&1 || true
  fi
  if ! win_daemon_running; then
    win_ps "\$r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = 'cmd.exe /c start \"\" \"$(cygpath -w "$WIN_DAEMON_EXE")\"' }" >/dev/null 2>&1 || true
  fi
  for i in $(seq 1 60); do win_daemon_running && break; sleep 1; done
  # 起壳（daemon 已就绪，壳不应再走向导）。
  win_start_app || { echo "候选 App 没起来"; return 1; }
  win_ui_wait "$d/desktop-main.txt" '后台服务运行中' 60 || true
  sleep 3
  # 等手机版本号刷新
  for i in $(seq 1 20); do [ "$(win_phone_version)" = "$WIN_CAND_VER" ] && break; sleep 1; done
  snapshot "$d" post
}

photo_count_unchanged() {
  local a b
  a="$(sed -n 's/^photo_count=//p' "$1/pre-versions.txt" 2>/dev/null)"
  b="$(sed -n 's/^photo_count=//p' "$1/post-versions.txt" 2>/dev/null)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" = "$b" ]
}

judge() {
  local d="$1"
  check "桌面 exe 版本 = $WIN_CAND_VER" grep -qx "exe_version=$WIN_CAND_VER" "$d/post-versions.txt"
  check "安装登记 = $WIN_CAND_VER" grep -qx "install_version=$WIN_CAND_VER" "$d/post-versions.txt"
  check "daemon 版本 = $WIN_CAND_VER" grep -qx "status_version=$WIN_CAND_VER" "$d/post-versions.txt"
  check "手机版本 = $WIN_CAND_VER" grep -qx "phone_version=$WIN_CAND_VER" "$d/post-versions.txt"
  check "配对设备仍在（1 台）" grep -qx 'devices=1' "$d/post-versions.txt"
  check "身份 key 未变（升级不重配）" same_nonempty "$d/pre-identity.txt" "$d/post-identity.txt"
  check "照片库哈希未变（升级不丢/不重入库）" same_nonempty "$d/pre-library-hashes.txt" "$d/post-library-hashes.txt"
  check "照片数未变" photo_count_unchanged "$d"
  check "daemon 日志无 panic" no_line_panic "$d/post-daemon.log"
  verdict
}

counter() {
  local d="$OUT"
  # 去掉触发条件：不装候选。用 setup 里真实采集的升级前快照当证据（不降级、不动库），
  # 同一套判据必须因为版本不对而变红。
  echo "counter: 不执行升级（使用升级前真实快照）" >"$d/note.txt"
  cp "$EV/main/pre-status.json" "$d/post-status.json"
  cp "$EV/main/pre-devices.json" "$d/post-devices.json"
  cp "$EV/main/pre-daemon.log" "$d/post-daemon.log"
  cp "$EV/main/pre-identity.txt" "$d/post-identity.txt"
  cp "$EV/main/pre-library-hashes.txt" "$d/post-library-hashes.txt"
  cp "$EV/main/pre-versions.txt" "$d/post-versions.txt"
}

teardown() { return 0; }
