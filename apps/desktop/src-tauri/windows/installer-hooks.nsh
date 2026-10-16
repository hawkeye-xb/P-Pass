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
; The app-side auto-update path (checkForUpdate() in App.svelte) already
; handles this by calling pause_daemon_for_update/resume_daemon_after_update
; around update.downloadAndInstall(). But that JS never runs when the
; user bypasses the in-app updater entirely — downloading and
; double-clicking a new installer.exe directly, or the user closed the
; app and forgot it's still running in the tray. This hook covers that
; path at the NSIS level so it doesn't depend on the app being open at
; all.
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
!macro NSIS_HOOK_POSTINSTALL
  nsExec::ExecToLog '"$SYSDIR\schtasks.exe" /Change /TN "P-Pass" /ENABLE'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\schtasks.exe" /Run /TN "P-Pass"'
  Pop $0
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
