#Requires -Version 5.1
# reset-ppass-env.ps1 - Wipe local P-Pass state for a clean re-test.
#
# Removes everything a normal user install leaves behind on this machine:
#   1. HKCU autostart Run key (Software\Microsoft\Windows\CurrentVersion\Run\P-Pass)
#   2. The platform data dir (config.toml, logs\, keys\ DPAPI blob) in BOTH
#      locations, because DESK-24 (#173) moved it:
#        - %LOCALAPPDATA%\com.p-pass.desktop   <- current
#        - %APPDATA%\P-Pass                    <- legacy (pre-#173 installs)
#      plus any com.p-pass.desktop.migrating-* staging dir left behind by an
#      interrupted move.
#   3. The photo library directory and its .ppf/ sidecar (identity.key, blobs,
#      staging, thumbs, index.db) - ONLY if --LibraryDir is given or the
#      default "<Pictures>\P-Pass 家庭照片库" exists; never guesses beyond that.
#   4. Any resident daemon.exe process still running (killed before deleting
#      its data dir, otherwise files stay locked).
#   5. Optionally uninstalls the NSIS-installed program (Programs and
#      Features entry) with -Uninstall.
#
# Does NOT touch: the P-Pass git repo/source checkout, vcpkg/rustup/pnpm/
# node toolchain, or anything under tools\windows\ - those are dev
# environment, not app state.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\reset-ppass-env.ps1 [-DryRun] [-Uninstall] [-LibraryDir <path>]
#
# -DryRun     : print what would be removed, remove nothing.
# -Uninstall  : also run the NSIS uninstaller for a per-user "P-Pass" install
#               if found in the registry uninstall keys.
# -LibraryDir : explicit photo library path to wipe (in case it's not the
#               default "<Pictures>\P-Pass 家庭照片库", e.g. user picked a
#               custom folder during the wizard). Pass the folder itself,
#               not the .ppf subfolder.

param(
    [switch]$DryRun,
    [switch]$Uninstall,
    [string]$LibraryDir = ""
)

$ErrorActionPreference = 'Stop'
$actions = New-Object System.Collections.Generic.List[string]

function Say([string]$msg) { Write-Output $msg }

function Remove-Target {
    param([string]$Path, [string]$Label)
    if (Test-Path $Path) {
        $actions.Add("$Label : $Path")
        if ($DryRun) {
            Say "[DRY-RUN] would remove: $Label -> $Path"
        } else {
            try {
                Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
                Say "[REMOVED] $Label -> $Path"
            } catch {
                Say "[WARN] failed to remove $Label ($Path): $($_.Exception.Message)"
            }
        }
    } else {
        Say "[SKIP] $Label not found: $Path"
    }
}

Say '=== P-Pass local env reset ==='
if ($DryRun) { Say '(DRY RUN - nothing will actually be deleted)' }
Say ''

# --- 1. Kill any running daemon / desktop shell so files aren't locked ---
$procNames = @('daemon', 'p-pass-desktop', 'testclient')
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

# --- 2. HKCU autostart Run key (crates/platform/src/windows.rs RUN_KEY/RUN_VALUE) ---
$runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValueName = 'P-Pass'
$runVal = Get-ItemProperty -Path $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue
if ($runVal) {
    if ($DryRun) {
        Say "[DRY-RUN] would remove HKCU Run value: $runKeyPath\$runValueName = $($runVal.$runValueName)"
    } else {
        Remove-ItemProperty -Path $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue
        Say "[REMOVED] HKCU Run value: $runKeyPath\$runValueName"
    }
} else {
    Say "[SKIP] HKCU Run value not present: $runKeyPath\$runValueName"
}
Say ''

# --- 3. Platform data dir, BOTH locations (DESK-24 #173) ---
# The current one is %LOCALAPPDATA%\com.p-pass.desktop; installs made before
# #173 still have %APPDATA%\P-Pass, and crates/platform keeps using that old
# location until the move actually succeeds - so a reset that only wiped one
# of them would leave the app resurrectable from the other.
#
# NOTE: the current dir also holds EBWebView (Tauri's webview profile). Wiping
# it is intentional - this script exists to produce a clean re-test, and a
# stale webview profile can mask first-run behaviour.
$currentDataDir = Join-Path $env:LOCALAPPDATA 'com.p-pass.desktop'
Remove-Target -Path $currentDataDir -Label 'LOCALAPPDATA data_dir (config.toml, logs\, keys\, EBWebView\)'

$legacyDataDir = Join-Path $env:APPDATA 'P-Pass'
Remove-Target -Path $legacyDataDir -Label 'legacy APPDATA data_dir, pre-#173 (config.toml, logs\, keys\)'

# Staging dirs from an interrupted move (crates/platform/src/data_migration.rs
# names them "<data dir>.migrating-<pid>", as siblings of the data dir).
$staging = @(Get-ChildItem -Path $env:LOCALAPPDATA -Directory -Filter 'com.p-pass.desktop.migrating-*' -ErrorAction SilentlyContinue)
if ($staging.Count -eq 0) {
    Say '[SKIP] no interrupted-migration staging dir found'
} else {
    foreach ($d in $staging) {
        Remove-Target -Path $d.FullName -Label 'interrupted migration staging dir'
    }
}
Say ''

# --- 4. Photo library + .ppf sidecar ---
# Default from apps/desktop/src-tauri/src/lib.rs dirs_pictures() + wizard_state():
#   <Pictures>\P-Pass 家庭照片库
$picturesFolder = [Environment]::GetFolderPath('MyPictures')
if (-not $picturesFolder) {
    $picturesFolder = Join-Path $env:USERPROFILE 'Pictures'
}
$defaultLibrary = Join-Path $picturesFolder 'P-Pass 家庭照片库'
$librariesToCheck = @()
if ($LibraryDir -ne '') {
    $librariesToCheck += $LibraryDir
} else {
    $librariesToCheck += $defaultLibrary
}
foreach ($lib in $librariesToCheck) {
    if (Test-Path $lib) {
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

# --- 5. Optional: uninstall the NSIS install (Programs and Features) ---
if ($Uninstall) {
    $uninstallKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass'
    )
    $found = $false
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
                if (Test-Path $exePath) {
                    Start-Process -FilePath $exePath -ArgumentList $uninstArgs -Wait
                    Say "[UNINSTALLED] via $exePath $uninstArgs"
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
}

Say '=== Summary ==='
if ($DryRun) {
    Say "DRY RUN complete. $($actions.Count) item(s) would have been removed. Re-run without -DryRun to actually clean."
} else {
    Say 'Reset complete. Next NSIS install + wizard run should behave like a fresh machine.'
    Say '(If you also want the app itself uninstalled, re-run with -Uninstall.)'
}
