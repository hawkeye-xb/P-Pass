; #1063：StrFunc 的用法声明（必须在宏/函数之前）。
${Using:StrFunc} StrStr

; P-Pass NSIS installer hooks (W1 follow-up, 2026-08-26)
;
; Problem: ppf-daemon.exe is a resident background process (registered
; as the per-user scheduled task "P-Pass", run immediately on install per
; crates/platform/src/windows.rs install_autostart()). It stays running
; even after the user closes the main window (tray-hide by design —
; backups keep working). If the user re-runs the installer (manual
; update download, or a second install attempt) without first manually
; stopping the service via the tray, NSIS can't overwrite the exe files
; while they're held open by the running process — install fails.
;
; #1063: Windows 上应用内更新的 install() 把安装器拉起后旧壳就退出了，安装
; 失败时没有任何 App 代码在跑。所以服务恢复和用户提示只能由安装器负责：
;   - PREINSTALL 停服务（disable + taskkill）；
;   - POSTINSTALL 成功时复查文件真的换成了本次版本，再 enable + run；
;   - 失败（包括 NSIS 的 File 覆盖被占用时只置错误位、不触发 .onInstFailed
;     的情况）统一走 UpdateFailureRecover：恢复服务 + 写 update-failed 标记；
;   - 新壳启动读标记，主界面给「上次更新没有完成」横幅（重试 / 手动下载）。
;
; PREINSTALL: kill both processes unconditionally before any files are
; touched. taskkill exiting non-zero (process not found — nothing was
; running, which is the common case) must not abort the installer, so
; every call is wrapped to swallow its exit code.
;
; DESK-65 (#957): the service is now a per-user Task Scheduler task with a
; once-a-minute watchdog. Disable it first, otherwise the watchdog may start
; ppf-daemon.exe again while its file is being replaced. Disabling does not
; end the running instance, so taskkill below is still needed. No task
; (fresh install, or the user stopped the service) = schtasks fails, which
; is swallowed like taskkill's.
!macro NSIS_HOOK_PREINSTALL
  DetailPrint "Stopping P-Pass background service if it's running..."
  nsExec::ExecToLog '"$SYSDIR\schtasks.exe" /Change /TN "P-Pass" /DISABLE'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM ppf-daemon.exe'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM p-pass-desktop.exe'
  Pop $0
  ; Give the OS a moment to actually release the file handles — taskkill
  ; returning doesn't guarantee the handle is closed yet (observed
  ; flakiness without this on a fast machine during dev testing).
  Sleep 500
!macroend

; POSTINSTALL (DESK-65 #957): hand the service back to the system — enable
; the task and run it, the counterpart of launchd's kickstart after an
; update. The new daemon is up without waiting for the desktop shell to be
; relaunched. "How the daemon is started" stays in one place: the task
; definition written by crates/platform/src/windows.rs; NSIS only flips it.
; No task (fresh install, or the user stopped the service) = both calls
; fail harmlessly, so a stopped service stays stopped across updates.
;
; #1063: NSIS 的 `File` 覆盖被占用时只置错误位、仍会走到这里，不会触发
; `.onInstFailed`。所以成功路径必须复查 daemon 真的是本次版本（`--version
; --json` 里含 ${VERSION}）；不是就走失败恢复，而不是继续 enable/run 并
; 清掉失败标记。否则用户会得到「装完了但服务起不来、也没有任何提示」。
!macro NSIS_HOOK_POSTINSTALL
  nsExec::ExecToStack '"$INSTDIR\ppf-daemon.exe" --version --json'
  Pop $0
  Pop $1
  ; 输出里含本次 ${VERSION} 才算换成功（StrStr 找不到时结果为空）。
  ${StrStr} $R7 "$1" "${VERSION}"
  ${If} $0 != 0
  ${OrIf} $R7 == ""
    Call UpdateFailureRecover
  ${Else}
    nsExec::ExecToLog '"$SYSDIR\schtasks.exe" /Change /TN "P-Pass" /ENABLE'
    Pop $0
    nsExec::ExecToLog '"$SYSDIR\schtasks.exe" /Run /TN "P-Pass"'
    Pop $0
    ; 成功装完，清掉上一次失败留下的横幅标记（下次启动不再提示旧失败）。
    Delete "$LOCALAPPDATA\com.p-pass.desktop\update-failed"
  ${EndIf}
!macroend

; PREUNINSTALL: same reasoning as PREINSTALL — an uninstall must be able
; to delete the exe files too.
;
; DESK-65 (#957): also delete the scheduled task, otherwise its watchdog
; keeps trying to start a daemon that no longer exists. Config and the
; photo library are kept, so a reinstall restores the task (#877) unless
; the user had stopped the service.
;
; DESK-72 (#1012): also delete the desktop shell's login item (HKCU Run
; value "P-Pass Desktop", written by the shell at startup; see
; crates/platform/src/windows.rs SHELL_RUN_VALUE). Tauri's template only
; removes the value named after the product ("P-Pass").
!macro NSIS_HOOK_PREUNINSTALL
  DetailPrint "Stopping P-Pass background service before uninstall..."
  nsExec::ExecToLog '"$SYSDIR\schtasks.exe" /Delete /TN "P-Pass" /F'
  Pop $0
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "P-Pass Desktop"
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM ppf-daemon.exe'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM p-pass-desktop.exe'
  Pop $0
  Sleep 500
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
!macroend

; #1063：安装失败 / 文件没换成时共用的恢复路径。
;
;   1. 用户主动停过服务（停止标记在）⇒ 不恢复，保持停止；
;      否则任务存在就 enable + run（任务不存在 = 没登记，什么都不做）；
;   2. 写 `update-failed` 标记（服务是否按规则处理），下次 App
;      启动读它显示「上次更新失败」横幅（重试 / 手动下载）；
;   3. 静默安装（应用内更新）不弹窗，把提示留给下次启动横幅；交互安装
;      （用户双击安装包）才弹错误对话框，这是经典安装器的做法。
Function UpdateFailureRecover
  StrCpy $R9 0
  IfFileExists "$LOCALAPPDATA\com.p-pass.desktop\desktop-user-stopped" failed_marker
    nsExec::ExecToStack '"$SYSDIR\schtasks.exe" /Query /TN "P-Pass"'
    Pop $0
    Pop $1
    ${If} $0 == 0
      nsExec::ExecToLog '"$SYSDIR\schtasks.exe" /Change /TN "P-Pass" /ENABLE'
      Pop $0
      nsExec::ExecToLog '"$SYSDIR\schtasks.exe" /Run /TN "P-Pass"'
      Pop $0
      StrCpy $R9 1
    ${EndIf}

  failed_marker:
  ClearErrors
  FileOpen $0 "$LOCALAPPDATA\com.p-pass.desktop\update-failed" w
  IfErrors failed_dialog
  FileWrite $0 "install-failed$\r$\n"
  FileWrite $0 "service=$R9$\r$\n"
  FileClose $0

  failed_dialog:
  ${IfNot} ${Silent}
    MessageBox MB_ICONEXCLAMATION|MB_OK "P-Pass update failed. The background service has been restored; reopen P-Pass to retry, or download the latest version from the website.$\r$\n$\r$\n更新失败，后台服务已恢复。请重新打开 P-Pass 重试，或从官网下载最新版本。"
  ${EndIf}
FunctionEnd

; NSIS 判定「安装过程失败/中止」时走这里（文件复制失败不一定会到这里，
; 所以 POSTINSTALL 还会复查版本）。
Function .onInstFailed
  Call UpdateFailureRecover
FunctionEnd
