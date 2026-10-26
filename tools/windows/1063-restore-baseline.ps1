#Requires -Version 5.1
# 1063-restore-baseline.ps1 - Put the #1063 test environment back to 40 photos.
#
# Between R2.2 and R2.3 (and after the last case) the library must be exactly
# the 40 REG_* baseline photos again. This script:
#   1. deletes every non-REG_*.jpg from /sdcard/DCIM/PPassRegression + rescans;
#   2. deletes the batch originals whose sha256 was recorded by
#      1063-r22-r23.ps1 (expected-<batch>.sha256);
#   3. restarts the desktop shell/daemon so SYNC-01/IDX-01 startup reconcile
#      drops the now-missing assets, keeping the pairing intact;
#   4. verifies photo_count=40, originals=40 and every R0.5 hash still present.
#
# If the surgical path cannot reach 40, it falls back to the 40-photo library
# snapshot taken with -Snapshot (same pairing, same photos).
#
# It does NOT touch the legacy #1161 Windows service "P-Pass" (still Stopped):
# only p-pass-desktop.exe and ppf-daemon.exe are restarted.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\1063-restore-baseline.ps1 -Snapshot
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\1063-restore-baseline.ps1 -CaseName restore-R2.3
param(
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [string]$CaseName = 'restore',
    [int]$ExpectedCount = 40,
    [int]$TimeoutSeconds = 150,
    [switch]$Snapshot
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot $CaseName
New-Item -ItemType Directory -Force $caseDir | Out-Null
$script:lines = New-Object System.Collections.Generic.List[string]
$adb = (Get-Command adb -ErrorAction Stop).Source
$bash = 'C:\Program Files\Git\bin\bash.exe'
$ipcStatusScript = Join-Path $PSScriptRoot '1063-ipc-status.sh'
$albumPath = '/sdcard/DCIM/PPassRegression'
$snapshotDir = Join-Path $WorkRoot 'library-baseline-40'
$desktopExe = Join-Path $env:LOCALAPPDATA 'P-Pass\p-pass-desktop.exe'

function Log([string]$msg) {
    [Console]::WriteLine($msg)
    $script:lines.Add($msg)
}
function Finish([string]$result, [string]$detail) {
    Log ''
    Log ("RESULT={0} {1}" -f $result, $detail)
    [IO.File]::WriteAllLines((Join-Path $caseDir 'result.txt'), $script:lines, (New-Object Text.UTF8Encoding($false)))
    if ($result -eq 'PASS') { exit 0 } else { exit 1 }
}
function Invoke-Adb {
    param([string[]]$AdbArgs)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $adb @AdbArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    return [pscustomobject]@{ Code = $code; Output = (($out | Out-String).Trim()) }
}
function Get-IpcStatus {
    if (-not (Test-Path -LiteralPath $ipcStatusScript)) { return $null }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $bash $ipcStatusScript 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($code -ne 0) { return $null }
    try { return ((($out | Out-String).Trim()) | ConvertFrom-Json) } catch { return $null }
}
function Get-DataDir {
    $conf = Join-Path $env:LOCALAPPDATA 'com.hawkeyexb.ppass.desktop\config.toml'
    if (-not (Test-Path -LiteralPath $conf)) { throw "no config.toml at $conf" }
    $text = Get-Content -LiteralPath $conf -Raw -Encoding UTF8
    $m = [regex]::Match($text, '(?m)^\s*data_dir\s*=\s*["''](.+?)["'']\s*$')
    if (-not $m.Success) { throw "could not parse data_dir from $conf" }
    return (Resolve-Path -LiteralPath ($m.Groups[1].Value -replace '\\\\', '\')).Path
}
function Read-HashFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object {
        $m = [regex]::Match($_, '^([0-9a-fA-F]{64})')
        if ($m.Success) { $m.Groups[1].Value.ToLowerInvariant() }
    })
}
function Get-Originals {
    param([string]$DataDir)
    $dir = Join-Path $DataDir 'originals'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -File -Recurse)
}
function Get-PhoneFiles {
    $r = Invoke-Adb -AdbArgs @('shell', 'ls', '-1', $albumPath)
    return @($r.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
function Get-AlbumRows {
    $r = Invoke-Adb -AdbArgs @('shell', 'content', 'query', '--uri', 'content://media/external/images/media', '--projection', '_data')
    return @($r.Output -split "`r?`n" | Where-Object { $_ -match '/DCIM/PPassRegression/' })
}
function Wait-PhoneBaseline {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $rows = Get-AlbumRows
        $bad = @($rows | Where-Object { $_ -notmatch '/REG_\d+\.jpg' })
        if ($rows.Count -eq $ExpectedCount -and $bad.Count -eq 0) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}
function Stop-Desktop {
    foreach ($p in @(Get-Process -Name 'p-pass-desktop' -ErrorAction SilentlyContinue)) {
        try { $p.CloseMainWindow() | Out-Null } catch { }
    }
    Start-Sleep -Seconds 3
    foreach ($name in @('p-pass-desktop', 'ppf-daemon')) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Name 'p-pass-desktop' -ErrorAction SilentlyContinue) -and
            -not (Get-Process -Name 'ppf-daemon' -ErrorAction SilentlyContinue)) {
            return $true
        }
        Start-Sleep -Milliseconds 300
    }
    return $false
}
function Start-Desktop {
    if (-not (Test-Path -LiteralPath $desktopExe)) { throw "missing $desktopExe" }
    $startCmd = 'cmd.exe /c start "" "{0}"' -f $desktopExe
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $startCmd }
    if ($r.ReturnValue -ne 0) { return $false }
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Get-Process -Name 'p-pass-desktop' -ErrorAction SilentlyContinue) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Wait-IpcCount {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $s = Get-IpcStatus
        if ($s -and $s.result) {
            $c = [int]$s.result.photo_count
            if ($c -eq $ExpectedCount) { return $true }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}
function Copy-Tree {
    param([string]$From, [string]$To)
    if (Test-Path -LiteralPath $To) { Remove-Item -LiteralPath $To -Recurse -Force }
    $null = New-Item -ItemType Directory -Force $To
    $out = & robocopy $From $To /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:1 2>&1
    return ($LASTEXITCODE -lt 8)
}

Log "=== #1063 baseline restore $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') case=$CaseName snapshot=$Snapshot ==="
$dev = Invoke-Adb -AdbArgs @('devices', '-l')
Log $dev.Output
if (@($dev.Output -split "`r?`n" | Where-Object { $_ -match '^\S+\s+device\b' }).Count -ne 1) {
    Finish 'FAIL' 'expected exactly one authorized Android device'
}
$win = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'window')
if ($win.Output -match 'mDreamingLockscreen=true') {
    Finish 'FAIL' 'phone is on the secure keyguard; restore would touch the UI indirectly'
}
$dataDir = Get-DataDir
Log "DataDir=$dataDir"
$originals = @(Get-Originals -DataDir $dataDir)
$beforeStatus = Get-IpcStatus
$beforeCount = if ($beforeStatus -and $beforeStatus.result) { [int]$beforeStatus.result.photo_count } else { -1 }

if ($Snapshot) {
    if ($beforeCount -ne $ExpectedCount) { Finish 'FAIL' "snapshot needs $ExpectedCount photos, current=$beforeCount" }
    if (-not (Stop-Desktop)) { Finish 'FAIL' 'could not stop p-pass-desktop/ppf-daemon' }
    if (-not (Copy-Tree -From $dataDir -To $snapshotDir)) { Finish 'FAIL' "snapshot copy failed: $snapshotDir" }
    if (-not (Start-Desktop)) { Finish 'FAIL' 'could not restart p-pass-desktop' }
    if (-not (Wait-IpcCount -TimeoutSeconds $TimeoutSeconds)) { Finish 'FAIL' 'daemon did not report 40 after snapshot' }
    $snapFiles = @(Get-ChildItem -LiteralPath $snapshotDir -File -Recurse)
    Log "Snapshot=$snapshotDir files=$($snapFiles.Count)"
    Finish 'PASS' "snapshot saved with $ExpectedCount photos and the existing pairing"
}

$phoneFiles = @(Get-PhoneFiles)
$drop = @($phoneFiles | Where-Object { $_ -notmatch '^REG_\d+\.jpg$' })
$keep = @($phoneFiles | Where-Object { $_ -match '^REG_\d+\.jpg$' })
$batchHashes = New-Object 'System.Collections.Generic.HashSet[string]'
$batchFiles = @(Get-ChildItem -LiteralPath $WorkRoot -Recurse -Filter 'expected-*.sha256' -File -ErrorAction SilentlyContinue)
foreach ($bf in $batchFiles) {
    foreach ($h in (Read-HashFile -Path $bf.FullName)) { [void]$batchHashes.Add($h) }
}
$baselineHashes = @(Read-HashFile -Path (Join-Path $WorkRoot 'R0.5\expected.sha256'))
Log "PhoneBefore=$($phoneFiles.Count) keep=$($keep.Count) drop=$($drop.Count) OriginalsBefore=$($originals.Count) PhotoCountBefore=$beforeCount"
Log "BatchHashFiles=$($batchFiles.Count) BatchHashes=$($batchHashes.Count) BaselineHashes=$($baselineHashes.Count)"

foreach ($f in $drop) {
    $r = Invoke-Adb -AdbArgs @('shell', 'rm', '-f', "$albumPath/$f")
    Log "rm phone $f exit=$($r.Code)"
}
if ($drop.Count -gt 0) {
    Invoke-Adb -AdbArgs @('shell', 'content', 'call', '--uri', 'content://media', '--method', 'scan_volume', '--arg', 'external_primary') | Out-Null
    Start-Sleep -Seconds 2
}
$phoneOk = Wait-PhoneBaseline -TimeoutSeconds 45
$phoneRows = @(Get-AlbumRows)
Log "PhoneAfter=$($phoneRows.Count) allReg=$phoneOk"

$toDelete = @($originals | Where-Object {
    $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $batchHashes.Contains($h)
})
if ($originals.Count -eq $ExpectedCount) { $toDelete = @() }
$needRestart = $false
if ($toDelete.Count -gt 0) {
    if (-not (Stop-Desktop)) { Finish 'FAIL' 'could not stop p-pass-desktop/ppf-daemon before deleting originals' }
    foreach ($f in $toDelete) {
        Remove-Item -LiteralPath $f.FullName -Force
        Log "deleted original $($f.FullName)"
    }
    $needRestart = $true
}
if ($needRestart) {
    if (-not (Start-Desktop)) { Finish 'FAIL' 'could not restart p-pass-desktop' }
}
$ok = Wait-IpcCount -TimeoutSeconds $TimeoutSeconds
$afterStatus = Get-IpcStatus
$afterCount = if ($afterStatus -and $afterStatus.result) { [int]$afterStatus.result.photo_count } else { -1 }
$afterOriginals = @(Get-Originals -DataDir $dataDir)
$afterHashes = @($afterOriginals | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
$missing = @($baselineHashes | Where-Object { $afterHashes -notcontains $_ })
Log "After: photo_count=$afterCount originals=$($afterOriginals.Count) baseline_missing=$($missing.Count) phone_ok=$phoneOk"

# Surgical path failed? Fall back to the frozen 40-photo library snapshot.
if ((-not $ok -or $afterCount -ne $ExpectedCount -or $afterOriginals.Count -ne $ExpectedCount -or $missing.Count -ne 0) -and (Test-Path -LiteralPath $snapshotDir)) {
    Log 'Surgical restore did not reach 40; falling back to the library snapshot'
    if (-not (Stop-Desktop)) { Finish 'FAIL' 'could not stop the desktop before snapshot fallback' }
    if (-not (Copy-Tree -From $snapshotDir -To $dataDir)) { Finish 'FAIL' 'snapshot fallback copy failed' }
    if (-not (Start-Desktop)) { Finish 'FAIL' 'could not restart p-pass-desktop after snapshot fallback' }
    $ok = Wait-IpcCount -TimeoutSeconds $TimeoutSeconds
    $afterStatus = Get-IpcStatus
    $afterCount = if ($afterStatus -and $afterStatus.result) { [int]$afterStatus.result.photo_count } else { -1 }
    $afterOriginals = @(Get-Originals -DataDir $dataDir)
    $afterHashes = @($afterOriginals | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
    $missing = @($baselineHashes | Where-Object { $afterHashes -notcontains $_ })
    Log "AfterSnapshot: photo_count=$afterCount originals=$($afterOriginals.Count) baseline_missing=$($missing.Count)"
}

$pass = ($ok -and $afterCount -eq $ExpectedCount -and $afterOriginals.Count -eq $ExpectedCount -and $missing.Count -eq 0 -and $phoneOk)
$summary = @(
    "timestamp=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "case=$CaseName",
    "phone_before=$($phoneFiles.Count)",
    "phone_dropped=$($drop.Count)",
    "phone_after=$($phoneRows.Count)",
    "originals_before=$($originals.Count)",
    "originals_deleted=$($toDelete.Count)",
    "originals_after=$($afterOriginals.Count)",
    "photo_count_before=$beforeCount",
    "photo_count_after=$afterCount",
    "baseline_missing=$($missing.Count)",
    "snapshot_fallback=$((Test-Path -LiteralPath $snapshotDir))",
    "result=$(if ($pass) { 'PASS' } else { 'FAIL' })"
)
[IO.File]::WriteAllLines((Join-Path $caseDir 'summary.txt'), $summary, (New-Object Text.UTF8Encoding($false)))
$summary | ForEach-Object { Log $_ }

if ($pass) { Finish 'PASS' "restored $ExpectedCount baseline photos (phone + desktop)" }
Finish 'FAIL' "restore incomplete: photo_count=$afterCount originals=$($afterOriginals.Count) phone=$($phoneRows.Count) baseline_missing=$($missing.Count)"
