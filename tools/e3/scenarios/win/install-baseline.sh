# R0.1/R0.2/R0.3：手机装基线正式版；桌面装基线 0.10.1；走完首启向导，daemon 起来。
#
# 安装器是 perMachine（manifest requireAdministrator，UAC 必须）；提权会话直接装。
# 非提权会话不能弹 UAC，按 SOP「记下、跳过」处理：
#   - 默认 SKIP（77）并说明需要提权；
#   - 设 E3_WIN_PROVISION=extract 时，用同一个安装包里的文件解到 %LOCALAPPDATA%\P-Pass
#     并写 HKCU 卸载登记（App 只认这个登记），用来在没有提权的回归机上继续跑非安装类用例。
#     报告里必须写明「安装器路径未验证」。
# 反证：装好后不启动 App（向导没走），版本与主界面判据必须变红。
DESC="R0.1/R0.2/R0.3：手机与桌面都装基线 0.10.1/0.10.2，桌面走完向导、daemon 起来"
COUNTER=on

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

setup() {
  win_phone_state | grep -qx device || { echo "adb 看不到手机 ${E3_ANDROID_SERIAL}"; return 77; }
  # R0.1：手机卸载重装基线（清数据，保证首次配对状态）。已经是基线也重装——
  # 上一轮留下的配对/范围会让「首次配对」用例失真。
  local apk
  apk="$(win_release_file "$WIN_BASE_TAG" '*_android.apk')"
  [ -n "$apk" ] || { echo "缺基线 APK（$WIN_REL_DIR/$WIN_BASE_TAG/*_android.apk）"; return 77; }
  win_phone_stop
  win_adb uninstall com.hawkeyexb.ppass >/dev/null 2>&1 || true
  win_adb install -r "$(cygpath -w "$apk")" >/dev/null || { echo "基线 APK 安装失败"; return 1; }
  win_phone_grant
  [ "$(win_phone_version)" = "$WIN_BASE_PHONE_VER" ] || { echo "手机版本不是 ${WIN_BASE_PHONE_VER}：$(win_phone_version)"; return 1; }

  # 桌面清理到全新机器状态（旧库挪走，不硬删）。
  win_reset_desktop_state

  local exe
  exe="$(win_release_file "$WIN_BASE_TAG" '*_x64-setup.exe')"
  [ -n "$exe" ] || { echo "缺基线安装包（$WIN_REL_DIR/$WIN_BASE_TAG/*_x64-setup.exe）"; return 77; }
  echo "基线安装包：$exe"
  echo "sha256：$(sha256sum "$exe" | awk '{print $1}')"
  if win_is_elevated; then
    win_install_silent "$exe" || { echo "安装器失败"; return 1; }
    echo "provision=installer"
  elif [ "${E3_WIN_PROVISION:-}" = extract ]; then
    win_provision_extract "$exe" "$WIN_BASE_VER" || { echo "解包安装失败"; return 1; }
    echo "provision=extract（本机非提权，安装器路径未验证）"
  else
    echo "跳过：安装器需要 UAC 提权（requireAdministrator）；提权会话重跑，或设 E3_WIN_PROVISION=extract 用同一安装包载荷"
    return 77
  fi
  [ -x "$WIN_DESKTOP_EXE" ] && [ -x "$WIN_DAEMON_EXE" ] || { echo "安装目录缺可执行文件"; return 1; }
}

act() {
  local d="$OUT"
  win_start_app || { echo "App 没起来"; return 1; }
  # R0.3：首启向导三步（继续 / 继续 / 完成）。
  win_ui_wait "$d/wizard-1.txt" '照片存在哪' 40 || { echo "向导第 1 步没出现"; return 1; }
  win_ui_click '继续' >/dev/null || { echo "向导第 1 步点不到继续"; return 1; }
  win_ui_wait "$d/wizard-2.txt" '电脑会睡吗' 30 || { echo "向导第 2 步没出现"; return 1; }
  win_ui_click '继续' >/dev/null || { echo "向导第 2 步点不到继续"; return 1; }
  win_ui_wait "$d/wizard-3.txt" '设为常驻服务' 30 || { echo "向导第 3 步没出现"; return 1; }
  win_ui_click '完成' >/dev/null || { echo "向导第 3 步点不到完成"; return 1; }
  # 主界面 + daemon 就绪
  win_ui_wait "$d/desktop-main.txt" '后台服务运行中' 60 || true
  local i
  for i in $(seq 1 30); do win_daemon_running && break; sleep 1; done
  sleep 2
  win_diag "$d" || true
  {
    echo "status_version=$(win_status_field "$d" version)"
    echo "status_state=$(win_status_field "$d" state)"
    echo "exe_version=$(win_exe_version)"
    echo "install_version=$(win_app_version)"
    echo "task_state=$(win_task_state)"
    echo "task_action=$(win_task_action_path)"
    echo "daemon_pid=$(win_daemon_pid)"
    echo "library=$(win_library_dir_win 2>/dev/null)"
    echo "phone_version=$(win_phone_version)"
  } >"$d/versions.txt"
}

judge() {
  local d="$1"
  check "daemon 版本 0.10.1（diag status）" grep -qx "status_version=$WIN_BASE_VER" "$d/versions.txt"
  check "桌面 exe ProductVersion 0.10.1" grep -qx "exe_version=$WIN_BASE_VER" "$d/versions.txt"
  check "安装登记 DisplayVersion 0.10.1" grep -qx "install_version=$WIN_BASE_VER" "$d/versions.txt"
  check "首启向导走完（主界面「后台服务运行中」）" win_ui_has "$d/desktop-main.txt" '后台服务运行中'
  check "计划任务 P-Pass 在运行" grep -qx 'task_state=Running' "$d/versions.txt"
  check "计划任务指向安装目录里的 daemon" grep -Fq "task_action=$WIN_APP_DIR_WIN" "$d/versions.txt"
  check "daemon 进程在" grep -Eq '^daemon_pid=[0-9]+' "$d/versions.txt"
  check "手机基线版本 $WIN_BASE_PHONE_VER" grep -qx "phone_version=$WIN_BASE_PHONE_VER" "$d/versions.txt"
  check "照片库目录已由向导写入" grep -Eq '^library=.+P-Pass' "$d/versions.txt"
  check "daemon 日志无 panic" no_line_panic "$d/diag/daemon.log"
  verdict
}


counter() {
  local d="$OUT"
  # 去掉触发条件：不启动 App、daemon 也停掉，向导不会走，判据应全红。
  win_stop_app
  win_ps "Get-Process ppf-daemon -ErrorAction SilentlyContinue | Stop-Process -Force" >/dev/null 2>&1 || true
  sleep 1
  echo "counter: 不启动 App（故障注入）" >"$d/note.txt"
  win_diag "$d" || true
  win_ui_dump "$d/desktop-main.txt" || true
  {
    echo "status_version=$(win_status_field "$d" version)"
    echo "status_state=$(win_status_field "$d" state)"
    echo "exe_version=$(win_exe_version)"
    echo "install_version=$(win_app_version)"
    echo "task_state=$(win_task_state)"
    echo "task_action=$(win_task_action_path)"
    echo "daemon_pid=$(win_daemon_pid)"
    echo "library=$(win_library_dir_win 2>/dev/null)"
    echo "phone_version=$(win_phone_version)"
  } >"$d/versions.txt"
}

teardown() {
  # 恢复运行（向导已完成，App 起来后看门狗/自愈会把 daemon 拉回来）。
  win_app_running || win_start_app >/dev/null 2>&1 || true
  return 0
}
