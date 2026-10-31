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
; ProgramData 的位置在运行时读环境变量 %ProgramData%（缺省 C:\ProgramData），和 daemon 的
; `windows_programdata::service_root` 同一个口径。NSIS **没有** $PROGRAMDATA 常量：以前写成
; "$PROGRAMDATA\P-Pass" 时 makensis 只报 warning 6000 并把它当字面文字，安装器的 icacls 全部
; 返回 3（路径不存在）、wanted-state 没写，服务起来过不了目录核对就退出（#1167 真机复现）。
; 不用 `SetShellVarContext all` + $APPDATA：那会把同一函数里的 $LOCALAPPDATA 也换成 all 口径。
Var PPassDataDir
!define PPASS_DATA "$PPassDataDir"

!macro PPassResolveDataDir
  ReadEnvStr $PPassDataDir "ProgramData"
  ${If} $PPassDataDir == ""
    StrCpy $PPassDataDir "C:\ProgramData"
  ${EndIf}
  StrCpy $PPassDataDir "$PPassDataDir\P-Pass"
!macroend

; ---- 建服务（幂等）：自动启动 + 失败自动重启（等价 launchd KeepAlive）----
!macro PPassRegisterService
  nsExec::ExecToLog '"$SYSDIR\sc.exe" query "${PPASS_SERVICE}"'
  Pop $0
  ${If} $0 != 0
    ; binPath 里的内层引号必须写成 \"：nsExec 把整行原样交给 CreateProcess，sc 按 CRT
    ; 规则拆参数。写成裸引号（以前的 $\"）时 `""C:\Program Files\...` 在空格处被截断，
    ; sc 打印用法、返回 1639，服务根本没建出来（#1167 真机复现）。
    nsExec::ExecToLog '"$SYSDIR\sc.exe" create "${PPASS_SERVICE}" binPath= "\"$INSTDIR\ppf-daemon.exe\" --service" obj= "NT SERVICE\${PPASS_SERVICE}" start= auto DisplayName= "P-Pass"'
    Pop $0
  ${EndIf}
  ; 服务只保留需要的特权，系统从服务令牌里去掉其余特权。放在 create 分支外：首次安装、
  ; 覆盖升级、应用内更新都重新声明一次。名单与 daemon 启动核对的白名单
  ; （crates/platform/src/service_privileges.rs 的 SERVICE_PRIVILEGE_ALLOWLIST）一致，
  ; 改一边必须同时改另一边（壳的配置锁定测试比对两边）。
  nsExec::ExecToLog '"$SYSDIR\sc.exe" privs "${PPASS_SERVICE}" SeChangeNotifyPrivilege'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\sc.exe" failure "${PPASS_SERVICE}" reset= 86400 actions= restart/5000/restart/5000'
  Pop $0
  ; §5.1：把 start/stop/query 授给交互用户，避免每次启停都要 UAC。
  ; 「谁能操作 App」由 IPC 与主人模型（D3/D5）判定，不靠服务控制权区分。
  ; Administrators 保持 SCM 默认的完全控制（含 SD 删除、WD/WO 改权限）：PREUNINSTALL
  ; 的 `sc delete` 以管理员身份运行，少了 SD 卸载后服务会永久残留（#1063 真机复现）。
  nsExec::ExecToLog '"$SYSDIR\sc.exe" sdset "${PPASS_SERVICE}" "D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWRPWPDTLOCRRC;;;IU)"'
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
  !insertmacro PPassResolveDataDir
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
    ; #1167：失败标记放在 ProgramData（见 UpdateFailureRecover）；老位置一并清掉。
    Delete "${PPASS_DATA}\update-failed"
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
;   1. 用户主动停过服务（wanted-state = stopped）⇒ 不恢复，保持停止；
;      否则服务存在就起它；
;   2. 写 `update-failed` 标记，下次 App 启动读它显示「上次更新失败」横幅；
;   3. 静默安装（应用内更新）不弹窗，提示留给下次启动横幅。
;
; #1167：两个标记都**不**放 $LOCALAPPDATA——安装器是提权进程，换一个管理员来装，
; $LOCALAPPDATA 就是那个管理员的，主人的 App 读不到。
;   - 「用户停过」的正本是 ProgramData 里的 wanted-state（壳在用户点停止时写它，
;     服务开机自检也读它），这里直接读它，不再看壳自己的 desktop-user-stopped。
;   - update-failed 写进 ProgramData，并且**只给这一个文件**授 Users 读 + 删
;     （壳读横幅、用户点关闭时删掉）；目录本身仍然私有，用户只能按全路径打开它。
;     服务没装（首装就失败）时没有 ProgramData 目录可用，退回老位置——那种情况下
;     壳也按老位置读（HostingAdapter::installer_marker_dir）。
Function UpdateFailureRecover
  !insertmacro PPassResolveDataDir
  StrCpy $R9 0
  StrCpy $R8 0
  nsExec::ExecToStack '"$SYSDIR\sc.exe" query "${PPASS_SERVICE}"'
  Pop $0
  Pop $1
  ${If} $0 == 0
    StrCpy $R8 1
    StrCpy $R6 ""
    ClearErrors
    FileOpen $2 "${PPASS_DATA}\wanted-state" r
    ${IfNot} ${Errors}
      FileRead $2 $R6
      FileClose $2
    ${EndIf}
    ${StrStr} $R7 "$R6" "stopped"
    ${If} $R7 == ""
      nsExec::ExecToLog '"$SYSDIR\sc.exe" start "${PPASS_SERVICE}"'
      Pop $0
      StrCpy $R9 1
    ${EndIf}
  ${EndIf}

  ClearErrors
  ${If} $R8 == 1
    StrCpy $R5 "${PPASS_DATA}\update-failed"
  ${Else}
    CreateDirectory "$LOCALAPPDATA\com.hawkeyexb.ppass.desktop"
    StrCpy $R5 "$LOCALAPPDATA\com.hawkeyexb.ppass.desktop\update-failed"
  ${EndIf}
  FileOpen $0 "$R5" w
  IfErrors failed_dialog
  FileWrite $0 "install-failed$\r$\n"
  FileWrite $0 "service=$R9$\r$\n"
  FileClose $0
  ${If} $R8 == 1
    nsExec::ExecToLog '"$SYSDIR\icacls.exe" "$R5" /grant "*S-1-5-32-545:(R,D)"'
    Pop $0
  ${EndIf}

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
