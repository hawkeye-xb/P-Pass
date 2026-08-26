#Requires -Version 5.1
# env-check.ps1 - Windows desktop build environment baseline probe
#
# Purpose: compare this machine against the GitHub Actions `windows-latest`
# runner requirements used by .github/workflows/release.yml (windows-x64 job)
# and .github/workflows/ci-desktop.yml. ASCII-only output on purpose -
# PowerShell 5.1's default console codepage mangles non-ASCII (see W0 plan doc).
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\env-check.ps1
# Exit code: 0 always (this is a report, not a gate enforcer). Read the
# [BLOCK] / [WARN] / [OK] lines and the summary at the end.

$ErrorActionPreference = 'SilentlyContinue'
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail, [string]$Fix = '')
    $results.Add([PSCustomObject]@{ Name = $Name; Status = $Status; Detail = $Detail; Fix = $Fix })
}

Write-Output '=== P-Pass Windows env-check ==='
Write-Output "Timestamp (UTC): $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
Write-Output ''

# --- OS ---
$os = Get-CimInstance Win32_OperatingSystem
$osCaption = $os.Caption
$osVersion = $os.Version
Add-Result 'OS' 'INFO' "$osCaption ($osVersion)"

# --- PowerShell ---
$psv = $PSVersionTable.PSVersion.ToString()
Add-Result 'PowerShell' 'INFO' "$psv"
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Add-Result 'PowerShell.Min' 'BLOCK' 'PS major version < 5' 'Install PowerShell 5.1+ or PowerShell 7'
} else {
    Add-Result 'PowerShell.Min' 'OK' 'PS >= 5.1'
}

# --- Execution Policy ---
$ep = Get-ExecutionPolicy
Add-Result 'ExecutionPolicy' 'INFO' "$ep"
if ($ep -eq 'Restricted') {
    Add-Result 'ExecutionPolicy.Check' 'BLOCK' 'Restricted blocks local scripts' 'Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
} else {
    Add-Result 'ExecutionPolicy.Check' 'OK' "$ep allows script execution"
}

# --- Git ---
$gitVer = (git --version) 2>$null
if ($gitVer) {
    Add-Result 'Git' 'OK' "$gitVer"
} else {
    Add-Result 'Git' 'BLOCK' 'git not found on PATH' 'winget install --id Git.Git -e'
}

# --- Rust toolchain (pinned version lives in rust-toolchain.toml) ---
$pinnedRust = ''
$toolchainFile = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'rust-toolchain.toml'
if (Test-Path $toolchainFile) {
    # Skip comment lines (the file documents past mistakes with `channel = "stable"`
    # inside # comments right above the real, active line - do not match those).
    $line = Select-String -Path $toolchainFile -Pattern '^\s*channel\s*=\s*"([^"]+)"' | Select-Object -First 1
    if ($line) { $pinnedRust = $line.Matches[0].Groups[1].Value }
}
Add-Result 'Rust.Pinned' 'INFO' "rust-toolchain.toml pins: $pinnedRust"

$rustcVer = (rustc --version) 2>$null
$cargoVer = (cargo --version) 2>$null
if ($rustcVer) {
    Add-Result 'Rust.rustc' 'OK' "$rustcVer"
} else {
    Add-Result 'Rust.rustc' 'BLOCK' 'rustc not found on PATH' 'winget install --id Rustlang.Rustup -e ; then: rustup toolchain install 1.98.0'
}
if ($cargoVer) {
    Add-Result 'Rust.cargo' 'OK' "$cargoVer"
} else {
    Add-Result 'Rust.cargo' 'BLOCK' 'cargo not found on PATH' 'same as rustc fix'
}

$msvcTarget = (rustup target list --installed 2>$null) | Select-String 'x86_64-pc-windows-msvc'
if ($rustcVer) {
    if ($msvcTarget) {
        Add-Result 'Rust.msvc-target' 'OK' 'x86_64-pc-windows-msvc installed'
    } else {
        Add-Result 'Rust.msvc-target' 'WARN' 'x86_64-pc-windows-msvc target not confirmed installed' 'rustup target add x86_64-pc-windows-msvc'
    }
}

# --- MSVC Build Tools (cl.exe / link.exe reachability) ---
$clFound = (Get-Command cl.exe -ErrorAction SilentlyContinue)
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInfo = $null
if (Test-Path $vswhere) {
    $vsInfo = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
}
if ($vsInfo) {
    Add-Result 'MSVC.BuildTools' 'OK' "VC++ tools found at: $vsInfo"
} elseif ($clFound) {
    Add-Result 'MSVC.BuildTools' 'OK' "cl.exe on PATH: $($clFound.Source)"
} else {
    Add-Result 'MSVC.BuildTools' 'BLOCK' 'No MSVC C++ build tools detected (needed by cargo for MSVC target)' 'winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--add Microsoft.VisualStudio.Workload.VCTools"'
}

# --- Node.js ---
$nodeVer = (node --version) 2>$null
$requiredNodeMajor = 22  # matches ci-desktop.yml actions/setup-node node-version: 22
if ($nodeVer) {
    $nodeMajor = [int]($nodeVer.TrimStart('v').Split('.')[0])
    if ($nodeMajor -ge $requiredNodeMajor) {
        Add-Result 'Node' 'OK' "$nodeVer (CI pins major $requiredNodeMajor)"
    } else {
        Add-Result 'Node' 'WARN' "$nodeVer is older than CI's major $requiredNodeMajor" "winget install --id OpenJS.NodeJS.LTS -e (or nvm install $requiredNodeMajor)"
    }
} else {
    Add-Result 'Node' 'BLOCK' 'node not found on PATH' 'winget install --id OpenJS.NodeJS.LTS -e'
}

# --- pnpm (CI installs pnpm@11 via npm install -g) ---
$pnpmVer = (pnpm --version) 2>$null
if ($LASTEXITCODE -ne 0) { $pnpmVer = $null }
if ($pnpmVer) {
    Add-Result 'pnpm' 'OK' "pnpm $pnpmVer"
} else {
    Add-Result 'pnpm' 'BLOCK' 'pnpm not usable (corepack shim broken or pnpm not installed)' 'npm install -g pnpm@11'
}

# --- Tauri CLI (via npx, matches release.yml which uses pnpm's local devDependency) ---
$tauriVer = (npx --yes '@tauri-apps/cli@2.11.4' --version) 2>$null
if ($tauriVer) {
    Add-Result 'Tauri.CLI' 'OK' "$tauriVer"
} else {
    Add-Result 'Tauri.CLI' 'WARN' 'tauri CLI 2.11.4 not resolvable via npx (will be pulled by pnpm install anyway)' 'pnpm install in apps/desktop should provide it'
}

# --- vcpkg + libheif (release.yml expects C:\vcpkg preinstalled on windows-latest) ---
$vcpkgPath = 'C:\vcpkg\vcpkg.exe'
if (Test-Path $vcpkgPath) {
    Add-Result 'vcpkg' 'OK' "found at $vcpkgPath"
    $libheifInstalled = & $vcpkgPath list 2>$null | Select-String 'libheif'
    if ($libheifInstalled) {
        Add-Result 'vcpkg.libheif' 'OK' "$libheifInstalled"
    } else {
        Add-Result 'vcpkg.libheif' 'WARN' 'libheif:x64-windows-static-md not installed yet' 'C:\vcpkg\vcpkg.exe install "libheif:x64-windows-static-md" --clean-after-build'
    }
} else {
    Add-Result 'vcpkg' 'BLOCK' 'C:\vcpkg not found (GitHub windows-latest runner preinstalls it here; this dev box does not)' 'git clone https://github.com/microsoft/vcpkg C:\vcpkg ; C:\vcpkg\bootstrap-vcpkg.bat'
}

# --- WebView2 runtime (Tauri on Windows requires it) ---
$wv2Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$wv2 = Get-ItemProperty -Path $wv2Key -ErrorAction SilentlyContinue
if ($wv2 -and $wv2.pv) {
    Add-Result 'WebView2' 'OK' "runtime version $($wv2.pv)"
} else {
    Add-Result 'WebView2' 'BLOCK' 'WebView2 runtime not detected' 'winget install --id Microsoft.EdgeWebView2Runtime -e'
}

# --- Long paths ---
$lpKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
$lp = (Get-ItemProperty -Path $lpKey -ErrorAction SilentlyContinue).LongPathsEnabled
if ($lp -eq 1) {
    Add-Result 'LongPaths' 'OK' 'LongPathsEnabled = 1'
} else {
    Add-Result 'LongPaths' 'WARN' "LongPathsEnabled = $lp (node_modules / cargo target paths can exceed 260 chars)" 'Run as admin: Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -Value 1 ; then reboot'
}

# --- TEMP writable ---
$tempOk = $false
try {
    $probe = Join-Path $env:TEMP "ppass-probe-$(Get-Random).tmp"
    'probe' | Out-File -FilePath $probe -Encoding ascii
    if (Test-Path $probe) { $tempOk = $true; Remove-Item $probe -Force }
} catch { $tempOk = $false }
if ($tempOk) {
    Add-Result 'TEMP.Writable' 'OK' "$env:TEMP is writable"
} else {
    Add-Result 'TEMP.Writable' 'BLOCK' "$env:TEMP is not writable" 'Check permissions on %TEMP%'
}

# --- Disk space (C:) ---
$drive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
if ($drive) {
    $freeGb = [math]::Round($drive.Free / 1GB, 1)
    if ($freeGb -lt 10) {
        Add-Result 'Disk.C' 'BLOCK' "only $freeGb GB free (build needs >= 10 GB for target/ + node_modules + vcpkg)" 'Free up disk space'
    } elseif ($freeGb -lt 20) {
        Add-Result 'Disk.C' 'WARN' "$freeGb GB free (comfortable minimum is 20 GB)"
    } else {
        Add-Result 'Disk.C' 'OK' "$freeGb GB free"
    }
}

# --- gh CLI (optional, useful for triggering workflow_dispatch and downloading artifacts) ---
$ghVer = (gh --version) 2>$null
if ($ghVer) {
    Add-Result 'gh.CLI' 'OK' ($ghVer -split "`n" | Select-Object -First 1)
} else {
    Add-Result 'gh.CLI' 'WARN' 'gh CLI not found (optional: only needed to trigger workflow_dispatch / download artifacts from this machine)' 'winget install --id GitHub.cli -e'
}

Write-Output '--- Results ---'
foreach ($r in $results) {
    $line = "[{0}] {1}: {2}" -f $r.Status, $r.Name, $r.Detail
    Write-Output $line
    if ($r.Fix) { Write-Output ("       fix: {0}" -f $r.Fix) }
}

Write-Output ''
$blockCount = ($results | Where-Object { $_.Status -eq 'BLOCK' }).Count
$warnCount = ($results | Where-Object { $_.Status -eq 'WARN' }).Count
Write-Output "=== Summary: $blockCount BLOCK, $warnCount WARN ==="
if ($blockCount -gt 0) {
    Write-Output 'Result: NOT READY to build. Resolve BLOCK items above first.'
} elseif ($warnCount -gt 0) {
    Write-Output 'Result: BUILD LIKELY POSSIBLE but WARN items may cause friction or CI-vs-local drift.'
} else {
    Write-Output 'Result: READY. Environment matches expectations.'
}
