#Requires -Version 5.1
# 1063-restore-desktop-only.ps1 - Restore the 40-photo baseline when the phone
# is locked and must not be touched.
#
# 1063-restore-baseline.ps1 deliberately refuses to run while the keyguard is
# up because its first stage deletes files on the phone. When the phone locks
# after `svc power stayon false`, this script does only the desktop half: stop
# the shell/daemon, mirror the frozen 40-photo library snapshot into data_dir,
# restart the shell, and verify photo_count/originals/baseline hashes/pairing.
#
# It never talks to adb. The phone album is left as-is and the keyguard guard in
# the full restore script remains in force.
param(
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [string]$SnapshotDir = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10\library-baseline-40'),
    [string]$CaseName = 'restore-after-W4-desktop-only',
    [int]$ExpectedCount = 40,
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot $CaseName
New-Item -ItemType Directory -Force $caseDir | Out-Null
$lines = New-Object System.Collections.Generic.List[string]
$desktopExe = Join-Path $env:LOCALAPPDATA 'P-Pass\p-pass-desktop.exe'
$bash = 'C:\Program Files\Git\bin\bash.exe'
$ipcScript = Join-Path $PSScriptRoot '1063-ipc-status.sh'

function Log([string]$s) { [Console]::WriteLine($s); $lines.Add($s) }
function Finish([string]$result, [string]$detail) {
    Log ''
    Log ("RESULT={0} {1}" -f $result, $detail)
    [IO.File]::WriteAllLines((Join-Path $caseDir 'result.txt'), $lines, (New-Object Text.UTF8Encoding($false)))
    if ($result -eq 'PASS') { exit 0 }
    exit 1
}
function Get-IpcStatus {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $bash $ipcScript 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { return $null }
    try { return ((($out | Out-String).Trim()) | ConvertFrom-Json) } catch { return $null }
}
function Get-DataDir {
    $conf = Join-Path $env:LOCALAPPDATA 'com.hawkeyexb.ppass.desktop\config.toml'
    $text = Get-Content -LiteralPath $conf -Raw -Encoding UTF8
    $m = [regex]::Match($text, '(?m)^\s*data_dir\s*=\s*["''](.+?)["'']\s*$')
    if (-not $m.Success) { throw "could not parse data_dir from $conf" }
    return ($m.Groups[1].Value -replace '\\\\', '\')
}
function Stop-Desktop {
    foreach ($p in @(Get-Process -Name 'p-pass-desktop' -ErrorAction SilentlyContinue)) {
        try { $p.CloseMainWindow() | Out-Null } catch { }
    }
    Start-Sleep -Seconds 2
    foreach ($n in @('p-pass-desktop', 'ppf-daemon')) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
}
function Start-Desktop {
    $cmd = 'cmd.exe /c start "" "{0}"' -f $desktopExe
    Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd } | Out-Null
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Get-Process -Name 'p-pass-desktop' -ErrorAction SilentlyContinue) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

Log "=== #1063 desktop-only restore $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') case=$CaseName ==="
if (-not (Test-Path -LiteralPath $SnapshotDir)) { Finish 'FAIL' "snapshot missing: $SnapshotDir" }
$snapOriginals = @(Get-ChildItem -LiteralPath (Join-Path $SnapshotDir 'originals') -Recurse -File -ErrorAction SilentlyContinue)
Log "Snapshot=$SnapshotDir originals=$($snapOriginals.Count)"
if ($snapOriginals.Count -ne $ExpectedCount) { Finish 'FAIL' "snapshot has $($snapOriginals.Count) originals, expected $ExpectedCount" }

$dataDir = Get-DataDir
Log "DataDir=$dataDir"
$before = Get-IpcStatus
$beforeCount = if ($before) { [int]$before.result.photo_count } else { -1 }
Log "PhotoCountBefore=$beforeCount"

& schtasks.exe /change /tn 'P-Pass' /disable 2>&1 | Out-Null
Stop-Desktop
Log 'desktop/daemon stopped'

$out = & robocopy $SnapshotDir $dataDir /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:1 2>&1
$rc = $LASTEXITCODE
Log "robocopy exit=$rc"
if ($rc -ge 8) { Finish 'FAIL' "robocopy failed ($rc)" }

if (-not (Start-Desktop)) { Finish 'FAIL' 'could not restart p-pass-desktop' }
& schtasks.exe /change /tn 'P-Pass' /enable 2>&1 | Out-Null
& schtasks.exe /run /tn 'P-Pass' 2>&1 | Out-Null

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$after = $null
while ((Get-Date) -lt $deadline) {
    $after = Get-IpcStatus
    if ($after -and [int]$after.result.photo_count -eq $ExpectedCount) { break }
    Start-Sleep -Seconds 1
}
if (-not $after) { Finish 'FAIL' 'IPC is down after restore' }
$afterCount = [int]$after.result.photo_count
$afterOriginals = @(Get-ChildItem -LiteralPath (Join-Path $dataDir 'originals') -Recurse -File -ErrorAction SilentlyContinue)
$baselineHashes = @()
$baseFile = Join-Path $WorkRoot 'R0.5\expected.sha256'
if (Test-Path -LiteralPath $baseFile) {
    $baselineHashes = @(Get-Content -LiteralPath $baseFile -Encoding UTF8 | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ -match '^[0-9a-f]{64}$' })
}
$afterHashes = @($afterOriginals | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
$missing = @($baselineHashes | Where-Object { $afterHashes -notcontains $_ })

Log "PhotoCountAfter=$afterCount"
Log "OriginalsAfter=$($afterOriginals.Count)"
Log "BaselineHashes=$($baselineHashes.Count) missing=$($missing.Count)"
Log ("ipc state={0} paired_devices={1} version={2}" -f $after.result.state, $after.result.paired_devices, $after.result.version)

$pass = ($afterCount -eq $ExpectedCount -and $afterOriginals.Count -eq $ExpectedCount -and
    $missing.Count -eq 0 -and [int]$after.result.paired_devices -ge 1)
if ($pass) { Finish 'PASS' "desktop library restored to $ExpectedCount photos; pairing intact" }
Finish 'FAIL' 'desktop restore did not reach the 40-photo baseline'
