#Requires -Version 5.1
# reset-ppass-env.ps1 - Wipe local P-Pass state for a clean re-test.
#
# Removes everything a normal install leaves behind on this machine:
#   1. HKCU autostart Run values (Software\Microsoft\Windows\CurrentVersion\Run):
#      "P-Pass" (legacy daemon) and "P-Pass Desktop" (shell login item), plus
#      their StartupApproved\Run state.
#   2. The per-user scheduled task "P-Pass" (DESK-65 #957) and, with
#      -Uninstall, the Windows services "P-Pass" / "PPassPocSvc" and their
#      %ProgramData% roots (the #1161 service-mode experiment).
#   3. The platform data dir (config.toml, logs\, keys\ DPAPI blob) in BOTH
#      locations, because DESK-24 (#173) moved it:
#        - %LOCALAPPDATA%\com.hawkeyexb.ppass.desktop   <- current
#        - %APPDATA%\P-Pass                    <- legacy (pre-#173 installs)
#      plus any com.hawkeyexb.ppass.desktop.migrating-* staging dir left behind by an
#      interrupted move, and the two installer failure markers:
#        update-failed, desktop-user-stopped
#   4. The photo library directory and its .ppf/ sidecar (identity.key, blobs,
#      staging, thumbs, index.db) - ONLY if --LibraryDir is given or one of the
#      known defaults exists; never guesses beyond those.
#   5. Any resident daemon process still running - ppf-daemon.exe (the
#      installed build), ppf-daemon-debug.exe, daemon.exe (raw dogfood binary) -
#      killed before deleting its data dir, otherwise files stay locked.
#   6. With -Uninstall, the NSIS-installed program (Programs and Features),
#      its install dir(s), shortcuts, uninstall registry entries and the
#      Windows Firewall allow rules Windows created for the daemon.
#
# Service-mode note (#1161): the installer registers "P-Pass" as a per-machine
# service running from %ProgramData%\P-Pass, with a protected DACL and a
# "wanted-state" file. The service ACL gives interactive users stop/start but
# NOT delete, and %ProgramData%\P-Pass is only readable by Administrators and
# the service SID. This script never elevates: it stops what it can, attempts
# the delete once, and lets the final self-check report anything that still
# needs an administrator. It never prompts for UAC.
#
# Does NOT touch: the P-Pass git repo/source checkout, vcpkg/rustup/pnpm/
# node toolchain, or anything under tools\windows\ - those are dev
# environment, not app state.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\reset-ppass-env.ps1 [-DryRun] [-Uninstall] [-LibraryDir <path>]
#
# -DryRun     : print what would be removed, remove nothing. Self-check is skipped.
# -Uninstall  : also run the NSIS uninstaller for a per-user "P-Pass" install
#               if found in the registry uninstall keys, then remove install
#               dirs, Windows services, %ProgramData% roots and shortcuts.
# -LibraryDir : explicit photo library path to wipe (in case it's not the
#               default "<Pictures>\P-Pass 家庭照片库" or "<Pictures>\P-Pass Library",
#               e.g. user picked a custom folder during the wizard). Pass the folder
#               itself, not the .ppf subfolder.

param(
    [switch]$DryRun,
    [switch]$Uninstall,
    [string]$LibraryDir = ""
)

$ErrorActionPreference = 'Stop'
$actions = New-Object System.Collections.Generic.List[string]
$residuals = New-Object System.Collections.Generic.List[string]
$firewallCheckAvailable = $null
$isAdmin = $false
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    # Non-fatal: only used for an informational banner.
}

function Say([string]$msg) { Write-Output $msg }

# Test-Path throws when the caller cannot read the parent (e.g.
# %ProgramData%\P-Pass has a protected DACL). For the reset self-check,
# "access denied" must count as "still present", never as "absent".
function Test-TargetExists {
    param([string]$Path)
    try {
        return [bool](Test-Path -LiteralPath $Path -ErrorAction Stop)
    } catch {
        return $true
    }
}

function Remove-Target {
    param([string]$Path, [string]$Label)
    if (Test-TargetExists $Path) {
        $actions.Add("$Label : $Path")
        if ($DryRun) {
            Say "[DRY-RUN] would remove: $Label -> $Path"
        } else {
            try {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
                Say "[REMOVED] $Label -> $Path"
            } catch {
                Say "[WARN] failed to remove $Label ($Path): $($_.Exception.Message)"
            }
        }
    } else {
        Say "[SKIP] $Label not found: $Path"
    }
}

function Remove-RegValue {
    param([string]$Path, [string]$Name, [string]$Label)
    $value = $null
    $present = $false
    try {
        $value = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
        $present = $true
    } catch {
        $present = $false
    }
    if (-not $present) {
        Say "[SKIP] $Label not present: $Path\$Name"
        return
    }
    $actions.Add("$Label : $Path\$Name")
    if ($DryRun) {
        Say "[DRY-RUN] would remove: $Label -> $Path\$Name = $value"
        return
    }
    try {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        Say "[REMOVED] $Label -> $Path\$Name"
    } catch {
        Say "[WARN] failed to remove $Label ($Path\$Name): $($_.Exception.Message)"
    }
}

function Remove-RegKey {
    param([string]$Path, [string]$Label)
    if (Test-TargetExists $Path) {
        $actions.Add("$Label : $Path")
        if ($DryRun) {
            Say "[DRY-RUN] would remove: $Label -> $Path"
        } else {
            try {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
                Say "[REMOVED] $Label -> $Path"
            } catch {
                Say "[WARN] failed to remove $Label ($Path): $($_.Exception.Message)"
            }
        }
    } else {
        Say "[SKIP] $Label not found: $Path"
    }
}

# Stop a service once. The #1161 installer grants Interactive Users SERVICE_STOP
# (and SERVICE_START) but not DELETE, so stopping works without elevation while
# deleting does not. Returns after the service reaches STOPPED or times out.
function Stop-PPassService {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Say "[SKIP] service not installed: $Name"
        return
    }
    if ($DryRun) {
        Say "[DRY-RUN] would stop service: $Name (current: $($svc.Status))"
        return
    }
    if ($svc.Status -eq 'Stopped') {
        Say "[SKIP] service already stopped: $Name"
        return
    }

    $scOut = & sc.exe stop $Name 2>&1
    $scCode = $LASTEXITCODE
    Say "[STOP] service $Name requested (sc.exe exit $scCode)"
    if ($scOut) { Say "       $((($scOut | Out-String).Trim()))" }
    if ($scCode -ne 0 -and $scCode -ne 1062) {
        Say "[WARN] could not stop service $Name (sc.exe exit $scCode)"
        return
    }

    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $s -or $s.Status -eq 'Stopped') { break }
        Start-Sleep -Milliseconds 500
    }
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne 'Stopped') {
        Say "[WARN] service $Name still $($s.Status)"
    } else {
        Say "[STOPPED] service $Name"
    }
}

# Delete a service once. If the SCM ACL denies DELETE, record the exact sc.exe
# failure and let the self-check fail; do not retry and do not try to elevate.
function Remove-PPassService {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Say "[SKIP] service not installed: $Name"
        return
    }
    $actions.Add("service : $Name")
    if ($DryRun) {
        Say "[DRY-RUN] would delete service: $Name (current: $($svc.Status))"
        return
    }

    $scOut = & sc.exe delete $Name 2>&1
    $scCode = $LASTEXITCODE
    if ($scCode -eq 0) {
        Say "[REMOVED] service: $Name"
    } else {
        Say "[WARN] failed to delete service $Name (sc.exe exit $scCode): $((($scOut | Out-String).Trim()))"
        return
    }

    # DeleteService only marks the service for deletion; wait briefly so a
    # subsequent Get-Service check does not race the SCM.
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $s) { break }
        Start-Sleep -Milliseconds 250
    }
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($s) { Say "[WARN] service $Name still visible after delete (status $($s.Status))" }
}

function Remove-PPassTask {
    $task = Get-ScheduledTask -TaskName 'P-Pass' -ErrorAction SilentlyContinue
    if (-not $task) {
        Say "[SKIP] scheduled task not present: P-Pass"
        return
    }
    $actions.Add("scheduled task : P-Pass")
    if ($DryRun) {
        Say "[DRY-RUN] would delete scheduled task: P-Pass (state: $($task.State))"
        return
    }
    try {
        Stop-ScheduledTask -TaskName 'P-Pass' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName 'P-Pass' -Confirm:$false -ErrorAction Stop
        Say "[REMOVED] scheduled task: P-Pass"
    } catch {
        Say "[WARN] failed to delete scheduled task P-Pass: $($_.Exception.Message)"
    }
}

# Windows creates inbound allow rules the first time the daemon listens. They
# survive an uninstall and are part of a fresh-machine reset. Removing them
# requires administrator on a normal Windows install; the self-check reports
# them if this fails.
function Get-PPassFirewallRules {
    try {
        $rules = @(Get-NetFirewallRule -ErrorAction Stop | Where-Object {
            $_.DisplayName -match '(?i)ppf-daemon|p-pass|ppass'
        })
        $script:firewallCheckAvailable = $true
        return $rules
    } catch {
        $script:firewallCheckAvailable = $false
        return @()
    }
}

function Remove-PPassFirewallRules {
    $rules = @(Get-PPassFirewallRules)
    if (-not $script:firewallCheckAvailable) {
        Say "[WARN] could not query Windows Firewall rules; skipping firewall cleanup"
        return
    }
    if ($rules.Count -eq 0) {
        Say "[SKIP] no P-Pass firewall rules found"
        return
    }
    $actions.Add("firewall rules : $($rules.Count) rule(s)")
    if ($DryRun) {
        Say "[DRY-RUN] would remove $($rules.Count) P-Pass firewall rule(s):"
        foreach ($r in $rules) { Say "          - $($r.DisplayName)" }
        return
    }
    try {
        $rules | Remove-NetFirewallRule -ErrorAction Stop
        Say "[REMOVED] firewall rules: $($rules.Count)"
    } catch {
        Say "[WARN] failed to remove P-Pass firewall rules: $($_.Exception.Message)"
    }
}

# If the service could not be deleted, leave it stopped at boot too. The
# installer grants interactive users read/write on this single file even though
# the parent directory is private.
function Set-WantedStateStopped {
    $path = Join-Path $env:ProgramData 'P-Pass\wanted-state'
    if (-not (Test-TargetExists $path)) { return }
    try {
        [IO.File]::WriteAllText($path, 'stopped')
        Say "[WROTE] wanted-state=stopped: $path"
    } catch {
        Say "[WARN] could not write wanted-state=stopped ($path): $($_.Exception.Message)"
    }
}

function Assert-Absent {
    param([string]$Label, [string]$Path)
    if (Test-TargetExists $Path) {
        Say "[FAIL] $Label still present: $Path"
        $script:residuals.Add("$Label : $Path")
    } else {
        Say "[OK] absent: $Label"
    }
}

function Assert-RegValueAbsent {
    param([string]$Label, [string]$Path, [string]$Name)
    $present = $false
    try {
        Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop | Out-Null
        $present = $true
    } catch {
        $present = $false
    }
    if ($present) {
        Say "[FAIL] $Label still present: $Path\$Name"
        $script:residuals.Add("$Label : $Path\$Name")
    } else {
        Say "[OK] absent: $Label"
    }
}

function Assert-ServiceAbsent {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($svc) {
        Say "[FAIL] service still installed: $Name (status $($svc.Status))"
        $script:residuals.Add("service : $Name (status $($svc.Status))")
    } else {
        Say "[OK] service absent: $Name"
    }
}

function Assert-TaskAbsent {
    try {
        $task = Get-ScheduledTask -TaskName 'P-Pass' -ErrorAction Stop
        Say "[FAIL] scheduled task still present: P-Pass (state $($task.State))"
        $script:residuals.Add("scheduled task : P-Pass")
    } catch {
        if ($_.Exception.Message -match 'MSFT_ScheduledTask') {
            Say "[OK] scheduled task absent: P-Pass"
        } else {
            Say "[FAIL] could not verify scheduled task P-Pass: $($_.Exception.Message)"
            $script:residuals.Add("scheduled task P-Pass unverifiable: $($_.Exception.Message)")
        }
    }
}

Say '=== P-Pass local env reset ==='
if ($DryRun) { Say '(DRY RUN - nothing will actually be deleted)' }
if ($Uninstall -and -not $isAdmin) {
    Say '[INFO] not elevated: service delete and %ProgramData%\P-Pass removal may be denied; the self-check will report it.'
}
Say ''

# --- 1. Stop resident services so no watchdog restarts the daemon ---
# Stop both the #1161 service and the PoC service whenever they exist. Deleting
# them is part of -Uninstall below; stopping is safe in both modes.
foreach ($name in @('P-Pass', 'PPassPocSvc')) {
    Stop-PPassService -Name $name
}
Say ''

# --- 2. Kill any running daemon / desktop shell so files aren't locked ---
$procNames = @('ppf-daemon', 'ppf-daemon-debug', 'daemon', 'p-pass-desktop', 'testclient')
foreach ($name in $procNames) {
    $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($procs) {
        foreach ($p in $procs) {
            if ($DryRun) {
                Say "[DRY-RUN] would kill process: $name (pid $($p.Id))"
            } else {
                try {
                    Stop-Process -Id $p.Id -Force -ErrorAction Stop
                    Say "[KILLED] $name (pid $($p.Id))"
                } catch {
                    Say "[WARN] could not kill $name (pid $($p.Id)): $($_.Exception.Message)"
                }
            }
        }
    } else {
        Say "[SKIP] process not running: $name"
    }
}
if (-not $DryRun) { Start-Sleep -Milliseconds 500 }  # let file handles release
Say ''

# --- 3. HKCU autostart Run values (crates/platform/src/windows.rs) ---
# RUN_VALUE is the old daemon registration; SHELL_RUN_VALUE is the desktop
# shell's login item (DESK-72 #1012). Both must go, otherwise one of them
# resurrects a process at logon.
$runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
foreach ($runValueName in @('P-Pass', 'P-Pass Desktop')) {
    Remove-RegValue -Path $runKeyPath -Name $runValueName -Label "HKCU Run value $runValueName"
}
$startupApprovedPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
foreach ($runValueName in @('P-Pass', 'P-Pass Desktop')) {
    Remove-RegValue -Path $startupApprovedPath -Name $runValueName -Label "StartupApproved Run value $runValueName"
}
Say ''

# --- 4. Per-user scheduled task "P-Pass" (DESK-65 #957) ---
Remove-PPassTask
Say ''

# --- 5. Platform data dir, BOTH locations (DESK-24 #173) ---
# The current one is %LOCALAPPDATA%\com.hawkeyexb.ppass.desktop; installs made before
# #173 still have %APPDATA%\P-Pass, and crates/platform keeps using that old
# location until the move actually succeeds - so a reset that only wiped one
# of them would leave the app resurrectable from the other.
#
# The current dir also holds EBWebView (Tauri's webview profile). Wiping
# it is intentional - this script exists to produce a clean re-test, and a
# stale webview profile can mask first-run behaviour.
$currentDataDir = Join-Path $env:LOCALAPPDATA 'com.hawkeyexb.ppass.desktop'
$legacyDataDir = Join-Path $env:APPDATA 'P-Pass'

# #1063 installer failure markers (apps/desktop/src-tauri/src/lib.rs
# UPDATE_FAILED_MARKER and distribution.rs USER_STOPPED_MARKER). Remove them
# explicitly before the parent dir, so a dry run shows them and a partial
# data-dir delete cannot leave a stale banner/stop intent behind.
foreach ($marker in @('update-failed', 'desktop-user-stopped')) {
    Remove-Target -Path (Join-Path $currentDataDir $marker) -Label "data-dir marker $marker"
}

Remove-Target -Path $currentDataDir -Label 'LOCALAPPDATA data_dir (config.toml, logs\, keys\, EBWebView\)'
Remove-Target -Path $legacyDataDir -Label 'legacy APPDATA data_dir, pre-#173 (config.toml, logs\, keys\)'

# Staging dirs from an interrupted move (crates/platform/src/data_migration.rs
# names them "<data dir>.migrating-<pid>", as siblings of the data dir).
$staging = @(Get-ChildItem -Path $env:LOCALAPPDATA -Directory -Filter 'com.hawkeyexb.ppass.desktop.migrating-*' -ErrorAction SilentlyContinue)
if ($staging.Count -eq 0) {
    Say '[SKIP] no interrupted-migration staging dir found'
} else {
    foreach ($d in $staging) {
        Remove-Target -Path $d.FullName -Label 'interrupted migration staging dir'
    }
}
Say ''

# --- 6. Photo library + .ppf sidecar ---
# Current main uses <Pictures>\P-Pass 家庭照片库; the #1161 service branch moved
# the default to the fixed English name <Pictures>\P-Pass Library. Clean both
# known defaults, never an arbitrary path.
$picturesFolder = [Environment]::GetFolderPath('MyPictures')
if (-not $picturesFolder) {
    $picturesFolder = Join-Path $env:USERPROFILE 'Pictures'
}
$defaultLibraries = @(
    (Join-Path $picturesFolder 'P-Pass 家庭照片库'),
    (Join-Path $picturesFolder 'P-Pass Library')
)
$librariesToCheck = @()
if ($LibraryDir -ne '') {
    $librariesToCheck += $LibraryDir
} else {
    $librariesToCheck += $defaultLibraries
}
$librariesToCheck = @($librariesToCheck | Select-Object -Unique)
foreach ($lib in $librariesToCheck) {
    if (Test-TargetExists $lib) {
        # Nuke the .ppf sidecar (identity.key, blobs/, staging/, thumbs/, index.db)
        # and the originals/ tree we ingested. We do NOT touch files a user
        # dropped into the library root that are outside originals/ and .ppf/
        # unless the whole -LibraryDir is meant to be wiped for a clean slate;
        # since this is explicitly a *test* library for dogfood re-runs, we
        # remove the whole directory.
        Remove-Target -Path $lib -Label 'Photo library (originals/ + .ppf/ index+blobs+keys)'
    } else {
        Say "[SKIP] Library dir not found: $lib"
    }
}
Say ''

# --- 7. Optional: uninstall the NSIS install + service-mode residuals ---
if ($Uninstall) {
    $uninstallKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass'
    )
    $found = $false
    $ranUninstallers = @{}
    foreach ($k in $uninstallKeys) {
        $entry = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if ($entry -and $entry.UninstallString) {
            $found = $true
            Say "Found uninstall entry at $k"
            Say "UninstallString: $($entry.UninstallString)"
            if ($DryRun) {
                Say "[DRY-RUN] would run uninstaller"
            } else {
                # NSIS uninstall.exe honors /S for silent uninstall.
                # ($args is a PowerShell automatic variable - do not reuse its name.)
                $uninstStr = $entry.UninstallString
                if ($uninstStr -match '^"([^"]+)"\s*(.*)$') {
                    $exePath = $Matches[1]
                    $uninstArgs = ($Matches[2] + ' /S').Trim()
                } else {
                    $parts = $uninstStr -split ' ', 2
                    $exePath = $parts[0]
                    $uninstArgs = if ($parts.Count -gt 1) { ($parts[1] + ' /S').Trim() } else { '/S' }
                }
                if (Test-Path -LiteralPath $exePath) {
                    $dedupeKey = $exePath.ToLowerInvariant()
                    if ($ranUninstallers.ContainsKey($dedupeKey)) {
                        Say "[SKIP] uninstaller already run: $exePath"
                    } else {
                        $ranUninstallers[$dedupeKey] = $true
                        try {
                            $proc = Start-Process -FilePath $exePath -ArgumentList $uninstArgs -PassThru -ErrorAction Stop
                            if ($proc.WaitForExit(120000)) {
                                Say "[UNINSTALLED] via $exePath $uninstArgs (exit $($proc.ExitCode))"
                            } else {
                                Say "[WARN] uninstaller did not exit within 120s: $exePath"
                            }
                        } catch {
                            Say "[WARN] failed to run uninstaller ${exePath}: $($_.Exception.Message)"
                        }
                    }
                } else {
                    Say "[WARN] uninstaller exe not found at $exePath"
                }
            }
        }
    }
    if (-not $found) {
        Say "[SKIP] No P-Pass uninstall registry entry found (already uninstalled, or never NSIS-installed)"
    }
    Say ''

    # Public per-user / per-machine install locations. %LOCALAPPDATA%\P-Pass is
    # the NSIS currentUser install dir; perMachine (#1161) uses Program Files.
    $installDirs = @(
        (Join-Path $env:LOCALAPPDATA 'P-Pass'),
        (Join-Path $env:ProgramFiles 'P-Pass')
    )
    if (${env:ProgramFiles(x86)}) {
        $installDirs += (Join-Path ${env:ProgramFiles(x86)} 'P-Pass')
    }
    $installDirs = @($installDirs | Select-Object -Unique)
    foreach ($dir in $installDirs) {
        Remove-Target -Path $dir -Label 'P-Pass install dir'
    }
    Say ''

    # Start Menu / Desktop shortcuts created by NSIS. The per-machine ones live
    # in %ProgramData% / %PUBLIC% and may need an administrator to delete.
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop) { $desktop = Join-Path $env:USERPROFILE 'Desktop' }
    $shortcutTargets = @(
        (Join-Path $desktop 'P-Pass.lnk'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\P-Pass.lnk'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\P-Pass'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\P-Pass.lnk'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\P-Pass')
    )
    if ($env:PUBLIC) {
        $shortcutTargets += (Join-Path $env:PUBLIC 'Desktop\P-Pass.lnk')
    }
    foreach ($s in @($shortcutTargets | Select-Object -Unique)) {
        Remove-Target -Path $s -Label 'P-Pass shortcut'
    }
    Say ''

    # Stale Add/Remove Programs entries (the uninstaller normally removes them;
    # if it failed or the install dir was already gone, clean them here).
    foreach ($k in $uninstallKeys) {
        Remove-RegKey -Path $k -Label 'P-Pass uninstall registry key'
    }
    Say ''

    # Delete the #1161 services. Stop-PPassService ran at the top; the
    # uninstaller also tries sc.exe delete. If that failed because the caller
    # lacks DELETE on the service, try exactly once more and report.
    foreach ($name in @('P-Pass', 'PPassPocSvc')) {
        Remove-PPassService -Name $name
    }
    if (-not $DryRun -and (Get-Service -Name 'P-Pass' -ErrorAction SilentlyContinue)) {
        Set-WantedStateStopped
    }
    Say ''

    # %ProgramData%\P-Pass is the #1161 service data root (config, identity,
    # pairings, logs, wanted-state, daemon binary); %ProgramData%\PPassPoc is
    # the PoC service root. Both have protected DACLs. Remove them only after
    # the services are stopped/deleted.
    Remove-Target -Path (Join-Path $env:ProgramData 'P-Pass') -Label 'ProgramData service root'
    Remove-Target -Path (Join-Path $env:ProgramData 'PPassPoc') -Label 'ProgramData PoC service root'
    Say ''

    Remove-PPassFirewallRules
    Say ''
}

# --- 8. Post-clean self-check ---
if ($DryRun) {
    Say '=== Summary ==='
    Say "DRY RUN complete. $($actions.Count) item(s) would have been removed. Re-run without -DryRun to actually clean."
    Say 'Self-check skipped in -DryRun (nothing was removed).'
    exit 0
}

Say '=== Post-clean self-check ==='

# Always checked: user state and autostart registrations.
Assert-RegValueAbsent -Label 'HKCU Run value P-Pass' -Path $runKeyPath -Name 'P-Pass'
Assert-RegValueAbsent -Label 'HKCU Run value P-Pass Desktop' -Path $runKeyPath -Name 'P-Pass Desktop'
Assert-RegValueAbsent -Label 'StartupApproved Run value P-Pass' -Path $startupApprovedPath -Name 'P-Pass'
Assert-RegValueAbsent -Label 'StartupApproved Run value P-Pass Desktop' -Path $startupApprovedPath -Name 'P-Pass Desktop'
Assert-TaskAbsent

Assert-Absent -Label 'current LOCALAPPDATA data_dir' -Path $currentDataDir
Assert-Absent -Label 'legacy APPDATA data_dir' -Path $legacyDataDir
foreach ($marker in @('update-failed', 'desktop-user-stopped')) {
    Assert-Absent -Label "data-dir marker $marker" -Path (Join-Path $currentDataDir $marker)
}
$remainingStaging = @(Get-ChildItem -Path $env:LOCALAPPDATA -Directory -Filter 'com.hawkeyexb.ppass.desktop.migrating-*' -ErrorAction SilentlyContinue)
if ($remainingStaging.Count -gt 0) {
    Say "[FAIL] interrupted-migration staging dirs still present: $($remainingStaging.Count)"
    $script:residuals.Add("interrupted-migration staging dirs: $($remainingStaging.Count)")
} else {
    Say '[OK] absent: interrupted-migration staging dirs'
}
foreach ($lib in $librariesToCheck) {
    Assert-Absent -Label 'photo library' -Path $lib
}

if ($Uninstall) {
    Assert-ServiceAbsent -Name 'P-Pass'
    Assert-ServiceAbsent -Name 'PPassPocSvc'
    Assert-Absent -Label 'service registry key P-Pass' -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\P-Pass'
    Assert-Absent -Label 'service registry key PPassPocSvc' -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\PPassPocSvc'
    Assert-Absent -Label 'ProgramData P-Pass service root' -Path (Join-Path $env:ProgramData 'P-Pass')
    Assert-Absent -Label 'ProgramData PPassPoc service root' -Path (Join-Path $env:ProgramData 'PPassPoc')

    foreach ($dir in $installDirs) {
        Assert-Absent -Label 'P-Pass install dir' -Path $dir
    }
    foreach ($s in @($shortcutTargets | Select-Object -Unique)) {
        Assert-Absent -Label 'P-Pass shortcut' -Path $s
    }
    foreach ($k in $uninstallKeys) {
        Assert-Absent -Label 'P-Pass uninstall registry key' -Path $k
    }

    if ($script:firewallCheckAvailable -eq $false) {
        Say '[WARN] Windows Firewall rule check unavailable; not asserted'
    } else {
        $remainingFw = @(Get-PPassFirewallRules)
        if ($remainingFw.Count -gt 0) {
            $names = ($remainingFw | Select-Object -First 3 | ForEach-Object { $_.DisplayName }) -join '; '
            Say "[FAIL] P-Pass firewall rules still present: $($remainingFw.Count) ($names)"
            $script:residuals.Add("firewall rules: $($remainingFw.Count) still present ($names)")
        } else {
            Say '[OK] absent: P-Pass firewall rules'
        }
    }
}

Say ''
Say '=== Summary ==='
Say "Actions attempted: $($actions.Count)"
if ($script:residuals.Count -gt 0) {
    Say "SELF-CHECK FAILED: $($script:residuals.Count) residual item(s) remain."
    foreach ($r in $script:residuals) { Say "  - $r" }
    Say 'A clean re-test requires an administrator to remove the items above; this script does not elevate.'
    exit 1
}

Say 'SELF-CHECK PASSED: all checked items are absent.'
Say 'Reset complete. Next NSIS install + wizard run should behave like a fresh machine.'
if (-not $Uninstall) {
    Say '(The app itself, its services and %ProgramData%\P-Pass were kept; re-run with -Uninstall to remove them.)'
}
