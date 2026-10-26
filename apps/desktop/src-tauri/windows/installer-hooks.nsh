; #1063 / #1161：P-Pass NSIS 安装钩子（per-machine + Windows 服务）。
;
; D1：daemon 从「每用户计划任务」改成系统服务（SCM）。安装器以管理员身份运行
; （perMachine），服务注册、ProgramData 目录与 ACL 在这里一次做完；之后用户
; 启动/停止服务不再需要 UAC。
;
; 服务名与 crates/platform/src/windows_service.rs 的 SERVICE_NAME（"P-Pass"）一致；
; ProgramData 目录与 brief §5.2 的「%ProgramData%\<目录名>」一致。
;
; 服务账户是虚拟账户 NT SERVICE\P-Pass（不是 LocalSystem）：SID 由服务名派生，
; 重装/升级后不变，所以目录 ACL 与配对都跨版本有效。

; #1063：StrFunc 的用法声明（必须在宏/函数之前）。
${Using:StrFunc} StrStr

!define PPASS_SERVICE "P-Pass"
!define PPASS_DATA "$PROGRAMDATA\P-Pass"

; ---- 建服务（幂等）：自动启动 + 失败自动重启（等价 launchd KeepAlive）----
!macro PPassRegisterService
  nsExec::ExecToLog '"$SYSDIR\sc.exe" query "${PPASS_SERVICE}"'
  Pop $0
  ${If} $0 != 0
    nsExec::ExecToLog '"$SYSDIR\sc.exe" create "${PPASS_SERVICE}" binPath= "$\"$INSTDIR\ppf-daemon.exe$\" --service" obj= "NT SERVICE\${PPASS_SERVICE}" start= auto DisplayName= "P-Pass"'
    Pop $0
  ${EndIf}
  nsExec::ExecToLog '"$SYSDIR\sc.exe" failure "${PPASS_SERVICE}" reset= 86400 actions= restart/5000/restart/5000'
  Pop $0
  ; §5.1：把 start/stop/query 授给交互用户，避免每次启停都要 UAC。
  ; 「谁能操作 App」由 IPC 与主人模型（D3/D5）判定，不靠服务控制权区分。
  nsExec::ExecToLog '"$SYSDIR\sc.exe" sdset "${PPASS_SERVICE}" "D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCLCSWRPWPDTLOCRRC;;;BA)(A;;CCLCSWRPWPDTLOCRRC;;;IU)"'
  Pop $0
!macroend

; ---- ProgramData 目录：受保护 DACL，只给 Administrators + 服务 SID ----
; 口径的正本是 `windows_programdata::ProgramDataDir::verify`（brief §5.2）：白名单只有
; 服务 SID 与 Administrators。**不要**给 SYSTEM / Users / Authenticated Users 加 ACE——
; 多一条 daemon 启动核对就不通过，服务直接被 SCM 记成 7000（拒绝启动）。
; 先少给、后给服务 SID：icacls 解析 "NT SERVICE\..." 要求服务已经存在。
!macro PPassPrepareDataDir
  CreateDirectory "${PPASS_DATA}"
  nsExec::ExecToLog '"$SYSDIR\icacls.exe" "${PPASS_DATA}" /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F"'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\icacls.exe" "${PPASS_DATA}" /grant "NT SERVICE\${PPASS_SERVICE}:(OI)(CI)F"'
  Pop $0
  ; 已经存在的子项（老的 logs\、升级前建的目录）不会自动跟着新 DACL 走：把它们的
  ; ACL 重置成「继承父目录」，否则服务账户照样写不进去（真机踩过：boot 日志整段
  ; 丢失、daemon.log 建不出来）。
  nsExec::ExecToLog '"$SYSDIR\icacls.exe" "${PPASS_DATA}\*" /reset /T'
  Pop $0
  ; §5.1 / #1161：「用户希望服务运行吗」的开关。开机时 SCM 拉起服务，daemon 读到
  ; stopped 就成功退出（= 保持停止）。这个文件**单独**给交互用户读写——目录本身
  ; 仍然私有，用户只能按全路径打开它（SeChangeNotifyPrivilege），列目录依旧被拒。
  ; 已存在就不动：升级不能把用户「我停过」的选择悄悄改回 running。
  IfFileExists "${PPASS_DATA}\wanted-state" ppass_wanted_state_exists
    FileOpen $0 "${PPASS_DATA}\wanted-state" w
    ${If} $0 != ""
      FileWrite $0 "running"
      FileClose $0
    ${EndIf}
  ppass_wanted_state_exists:
  nsExec::ExecToLog '"$SYSDIR\icacls.exe" "${PPASS_DATA}\wanted-state" /grant "*S-1-5-32-545:(R,W)"'
  Pop $0
!macroend

; PREINSTALL：停服务、清掉旧计划任务、关壳、再停 daemon。
; #1075：先关壳再停 daemon——壳还在时会在两次 taskkill 之间把 daemon 自愈拉起来。
!macro NSIS_HOOK_PREINSTALL
  DetailPrint "Closing P-Pass app, then stopping its background service..."
  nsExec::ExecToLog '"$SYSDIR\sc.exe" stop "${PPASS_SERVICE}"'
  Pop $0
  ; 旧版本（#957 计划任务）不做迁移，只清残留；失败无害。
  nsExec::ExecToLog '"$SYSDIR\schtasks.exe" /Delete /TN "${PPASS_SERVICE}" /F'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM p-pass-desktop.exe'
  Pop $0
  Sleep 1500
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM ppf-daemon.exe'
  Pop $0
  Sleep 500
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM ppf-daemon.exe'
  Pop $0
  Sleep 500
!macroend

; POSTINSTALL：确认文件真的换成了本版本，再注册服务、准备目录、起服务。
; #1063：`File` 覆盖被占用时 NSIS 只置错误位、仍会走到这里，所以必须复查版本。
!macro NSIS_HOOK_POSTINSTALL
  nsExec::ExecToStack '"$INSTDIR\ppf-daemon.exe" --version --json'
  Pop $0
  Pop $1
  ${StrStr} $R7 "$1" "${VERSION}"
  ${If} $0 != 0
  ${OrIf} $R7 == ""
    Call UpdateFailureRecover
  ${Else}
    !insertmacro PPassRegisterService
    !insertmacro PPassPrepareDataDir
    nsExec::ExecToLog '"$SYSDIR\sc.exe" start "${PPASS_SERVICE}"'
    Pop $0
    Delete "$LOCALAPPDATA\com.hawkeyexb.ppass.desktop\update-failed"
  ${EndIf}
!macroend

; PREUNINSTALL：停并删除服务、清旧计划任务、删壳的登录项、关壳、再停 daemon。
;
; ProgramData 目录**保留**：身份私钥、配对白名单、库位置都在里面，重装后手机不用
; 重新配对（brief §8 A18 的「按 owner 定」——这里取保守的一侧）。要彻底重置由用户
; 手动删除该目录，发布说明里写明「删目录 = 身份重置」。
!macro NSIS_HOOK_PREUNINSTALL
  DetailPrint "Closing P-Pass app, then stopping its background service..."
  nsExec::ExecToLog '"$SYSDIR\sc.exe" stop "${PPASS_SERVICE}"'
  Pop $0
  Sleep 1500
  nsExec::ExecToLog '"$SYSDIR\sc.exe" delete "${PPASS_SERVICE}"'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\schtasks.exe" /Delete /TN "${PPASS_SERVICE}" /F'
  Pop $0
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "P-Pass Desktop"
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM p-pass-desktop.exe'
  Pop $0
  Sleep 1500
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM ppf-daemon.exe'
  Pop $0
  Sleep 500
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM ppf-daemon.exe'
  Pop $0
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
!macroend

; #1063：安装失败 / 文件没换成时共用的恢复路径。
;
;   1. 用户主动停过服务（停止标记在）⇒ 不恢复，保持停止；
;      否则服务存在就起它；
;   2. 写 `update-failed` 标记，下次 App 启动读它显示「上次更新失败」横幅；
;   3. 静默安装（应用内更新）不弹窗，提示留给下次启动横幅。
Function UpdateFailureRecover
  StrCpy $R9 0
  IfFileExists "$LOCALAPPDATA\com.hawkeyexb.ppass.desktop\desktop-user-stopped" failed_marker
    nsExec::ExecToStack '"$SYSDIR\sc.exe" query "${PPASS_SERVICE}"'
    Pop $0
    Pop $1
    ${If} $0 == 0
      nsExec::ExecToLog '"$SYSDIR\sc.exe" start "${PPASS_SERVICE}"'
      Pop $0
      StrCpy $R9 1
    ${EndIf}

  failed_marker:
  ClearErrors
  FileOpen $0 "$LOCALAPPDATA\com.hawkeyexb.ppass.desktop\update-failed" w
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
