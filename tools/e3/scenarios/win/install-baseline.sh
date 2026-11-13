# R0.1/R0.2/R0.3：手机装基线正式版；桌面装基线 0.10.1；走完首启向导，daemon 起来。
#
# 本场景只搭**用户态**基线：用安装包载荷解到 %LOCALAPPDATA%\P-Pass 并写 HKCU 卸载登记
# （App 只认这个登记）。perMachine 真实安装器（Program Files + HKLM + Windows 服务）
# 由 tools/e3/scenarios/win/installer.sh 覆盖；R0.2 的安装器语义以那个场景为准。
# 与安装器无关的用例用本场景的用户态基线，提权/非提权会话都一样，避免两套布局混用。
# 反证：装好后不启动 App（向导没走），版本与主界面判据必须变红。
DESC="R0.1/R0.2/R0.3：手机与桌面都装基线 0.10.1/0.10.2，桌面走完向导、daemon 起来"
COUNTER=on

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

setup() {
  win_phone_state | grep -qx device || { echo "adb 看不到手机 ${E3_ANDROID_SERIAL}"; return 77; }
  # R0.1：手机卸载重装基线（清数据，保证首次配对状态）。已经是基线也重装——
  # 上一轮留下的配对/范围会让「首次配对」用例失真。
  # 先把所有 SKIP 前提（APK、安装包）查完，再动手机/桌面状态——
  # 报 SKIP 的一次运行不能把机器改了一半。
  local apk exe
  apk="$(win_release_file "$WIN_BASE_TAG" '*_android.apk')"
  [ -n "$apk" ] || { echo "缺基线 APK（$WIN_REL_DIR/$WIN_BASE_TAG/*_android.apk）"; return 77; }
  exe="$(win_release_file "$WIN_BASE_TAG" '*_x64-setup.exe')"
  [ -n "$exe" ] || { echo "缺基线安装包（$WIN_REL_DIR/$WIN_BASE_TAG/*_x64-setup.exe）"; return 77; }
  echo "基线安装包：$exe"
  echo "sha256：$(sha256sum "$exe" | awk '{print $1}')"
  # 解包要 7-Zip 完整版；缺了在动手机/桌面之前 SKIP，不把机器改一半。
  [ -n "$(ls "$WIN_TOOLS"/7zfull/Files/7-Zip/7z.exe 2>/dev/null | head -1)" ] || {
    echo "找不到 7z.exe（先按 local-state.md 里的办法解出 7-Zip）"
    return 77
  }

  # R0.1：手机卸载重装基线（清数据，保证首次配对状态）。已经是基线也重装——
  # 上一轮留下的配对/范围会让「首次配对」用例失真。
  win_phone_stop
  win_adb uninstall com.hawkeyexb.ppass >/dev/null 2>&1 || true
  win_adb install -r "$(cygpath -w "$apk")" >/dev/null || { echo "基线 APK 安装失败"; return 1; }
  win_phone_grant
  [ "$(win_phone_version)" = "$WIN_BASE_PHONE_VER" ] || { echo "手机版本不是 ${WIN_BASE_PHONE_VER}：$(win_phone_version)"; return 1; }

  # 桌面清理到全新机器状态（旧库挪走，不硬删），再解包安装用户态基线。
  # 清不干净（非管理员删不掉 HKLM 卸载登记）就停下，不带着残留继续解包/判 PASS（#1675）。
  APP_TOUCHED=1
  win_reset_desktop_state || { echo "桌面清场失败：旧状态没清干净（上一行是原因）"; return 1; }
  win_provision_extract "$exe" "$WIN_BASE_VER" || { echo "解包安装失败"; return 1; }
  echo "provision=extract（用户态基线；perMachine 真实安装器见 win/installer）"
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
    echo "hklm_uninstall_absent=$(win_hklm_uninstall_absent)"
    echo "task_state=$(win_task_state)"
    echo "task_action=$(win_task_action_path)"
    echo "daemon_pid=$(win_daemon_pid)"
    echo "library=$(win_library_dir_win 2>/dev/null)"
    echo "phone_version=$(win_phone_version)"
  } >"$d/versions.txt"
}

task_action_is_expected() { # 整条比较，避免 ...\P-Pass-old\ppf-daemon.exe 这种前缀冒充
  [ "$(sed -n 's/^task_action=//p' "$1" | tr -d '
')" = "$WIN_APP_DIR_WIN\ppf-daemon.exe" ]
}

judge() {
  local d="$1"
  check "R0.1 安装前没有残留的 HKLM 卸载登记（#1675）" grep -qx 'hklm_uninstall_absent=yes' "$d/versions.txt"
  check "daemon 版本 0.10.1（diag status）" grep -Fqx "status_version=$WIN_BASE_VER" "$d/versions.txt"
  check "桌面 exe ProductVersion 0.10.1" grep -Fqx "exe_version=$WIN_BASE_VER" "$d/versions.txt"
  check "安装登记 DisplayVersion 0.10.1" grep -Fqx "install_version=$WIN_BASE_VER" "$d/versions.txt"
  check "首启向导走完（主界面「后台服务运行中」）" win_ui_has "$d/desktop-main.txt" '后台服务运行中'
  check "计划任务 P-Pass 在运行" grep -qx 'task_state=Running' "$d/versions.txt"
  check "计划任务指向安装目录里的 daemon" task_action_is_expected "$d/versions.txt"
  check "daemon 进程在" grep -Eq '^daemon_pid=[0-9]+' "$d/versions.txt"
  check "手机基线版本 $WIN_BASE_PHONE_VER" grep -Fqx "phone_version=$WIN_BASE_PHONE_VER" "$d/versions.txt"
  check "照片库目录已由向导写入" grep -Eq '^library=.+P-Pass' "$d/versions.txt"
  check "daemon 日志无 panic" no_line_panic "$d/diag/daemon.log"
  verdict
}


counter() {
  local d="$OUT"
  # 故障条件：清场没清掉注册表（去掉清理逻辑时的机器状态，或非管理员会话删不掉）——
  # judge 的「安装前没有残留的 HKLM 卸载登记」必须变红。
  COUNTER_REG_INJECTED=0
  if win_is_elevated; then
    echo "counter: 清场没清掉 HKLM 卸载登记（故障注入）" >"$d/note.txt"
    # 先记标志再写：两处里只成功了一处（第二处抛错）时，teardown 也要把已建的那处清掉。
    COUNTER_REG_INJECTED=1
    win_ps "New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass' -Force | Out-Null; New-Item -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass' -Force | Out-Null" >/dev/null 2>&1 ||
      { echo "注入 HKLM 卸载登记失败"; return 1; }
  else
    # 非管理员造不出 HKLM 残留（真残留时 setup 已经按清场失败停下）。
    # 这条注入只在管理员会话跑；本机仍用「不启动 App」让其它判据变红。
    echo "counter: 非管理员会话，跳过 HKLM 注入" >"$d/note.txt"
  fi
  # 去掉触发条件：不启动 App、daemon 也停掉，向导不会走，判据应全红。
  win_stop_app
  win_ps "Get-Process ppf-daemon -ErrorAction SilentlyContinue | Stop-Process -Force" >/dev/null 2>&1 || true
  sleep 1
  echo "counter: 不启动 App（故障注入）" >>"$d/note.txt"
  win_diag "$d" || true
  win_ui_dump "$d/desktop-main.txt" || true
  {
    echo "status_version=$(win_status_field "$d" version)"
    echo "status_state=$(win_status_field "$d" state)"
    echo "exe_version=$(win_exe_version)"
    echo "install_version=$(win_app_version)"
    echo "hklm_uninstall_absent=$(win_hklm_uninstall_absent)"
    echo "task_state=$(win_task_state)"
    echo "task_action=$(win_task_action_path)"
    echo "daemon_pid=$(win_daemon_pid)"
    echo "library=$(win_library_dir_win 2>/dev/null)"
    echo "phone_version=$(win_phone_version)"
  } >"$d/versions.txt"
}

teardown() {
  # 反证注入的 HKLM 登记只属于本次反证，收尾时只清这两处。
  # 不能调 win_reset_uninstall_registry：它连 HKCU 一起删，而 HKCU 是 setup 的
  # win_provision_extract 刚写的正常登记，后续 win/upgrade-candidate 等靠它取版本。
  if [ "${COUNTER_REG_INJECTED:-0}" = 1 ]; then
    win_ps '$keys = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass"); foreach ($k in $keys) { Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue }' >/dev/null 2>&1 || true
  fi
  # 只恢复本场景动过的 App；setup SKIP（77）时什么都没停，不能凭空启动一个 App。
  [ "${APP_TOUCHED:-0}" = 1 ] || return 0
  win_app_running || win_start_app >/dev/null 2>&1 || true
  return 0
}
