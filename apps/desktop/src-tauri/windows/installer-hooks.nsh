; P-Pass NSIS installer hooks (W1 follow-up, 2026-08-26)
;
; Problem: ppf-daemon.exe is a resident background process (registered
; via HKCU Run key, started immediately on install per
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
!macro NSIS_HOOK_PREINSTALL
  DetailPrint "Stopping P-Pass background service if it's running..."
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM ppf-daemon.exe'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM p-pass-desktop.exe'
  Pop $0
  ; Give the OS a moment to actually release the file handles — taskkill
  ; returning doesn't guarantee the handle is closed yet (observed
  ; flakiness without this on a fast machine during dev testing).
  Sleep 500
!macroend

; POSTINSTALL: the daemon was stopped above (if it was running) but
; never explicitly restarted here. main.rs registers autostart via the
; HKCU Run key, which only takes effect on next login — matching the
; same-class fix already made in install_autostart() (crates/platform/
; src/windows.rs spawn_windowless call). We don't duplicate that spawn
; logic in NSIS; instead the freshly-installed app's own first-run flow
; (wizard finishSetup(), or App.svelte's refresh() self-heal for an
; already-configured install) brings the daemon back up. This keeps
; "how the daemon gets started" in exactly one place (the Rust code)
; instead of forking that logic into NSIS script as well.
!macro NSIS_HOOK_POSTINSTALL
!macroend

; PREUNINSTALL: same reasoning as PREINSTALL — an uninstall must be able
; to delete the exe files too.
!macro NSIS_HOOK_PREUNINSTALL
  DetailPrint "Stopping P-Pass background service before uninstall..."
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM ppf-daemon.exe'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM p-pass-desktop.exe'
  Pop $0
  Sleep 500
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
!macroend
