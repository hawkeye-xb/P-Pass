#Requires -Version 5.1
# 1063-r14-version.ps1 - R1.4 version consistency for the Windows/Android pair.
# Reads:
#   1. phone  dumpsys package com.hawkeyexb.ppass -> versionName
#   2. desktop HKCU Uninstall\P-Pass DisplayVersion (fallback: exe ProductVersion)
#   3. daemon ipc status -> result.version
# PASS only when all three equal -ExpectedVersion.
#
# Evidence: %USERPROFILE%\ppcheck\1063-test10\R1.4\versions.txt
param(
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [string]$ExpectedVersion = '0.10.0-test.10'
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot 'R1.4'
New-Item -ItemType Directory -Force $caseDir | Out-Null
$log = Join-Path $caseDir 'versions.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
$bash = 'C:\Program Files\Git\bin\bash.exe'
$ipcScript = Join-Path $PSScriptRoot '1063-ipc-status.sh'

function Log([string]$msg) {
    Write-Output $msg
    $script:lines.Add($msg)
}
function Finish([bool]$pass, [string]$detail) {
    Log ''
    Log ("RESULT={0} {1}" -f ($(if ($pass) { 'PASS' } else { 'FAIL' })), $detail)
    [IO.File]::WriteAllLines($log, $script:lines, (New-Object Text.UTF8Encoding($false)))
    if ($pass) { exit 0 } else { exit 1 }
}
function Invoke-Adb {
    param([string[]]$AdbArgs)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & adb @AdbArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    return [pscustomobject]@{ Code = $code; Output = (($out | Out-String).Trim()) }
}

Log "=== #1063 R1.4 version check $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Log "Expected=$ExpectedVersion"
Log ''

$dev = Invoke-Adb -AdbArgs @('devices', '-l')
if (@($dev.Output -split "`r?`n" | Where-Object { $_ -match '^\S+\s+device\b' }).Count -ne 1) {
    Finish $false "expected one authorized Android device: $($dev.Output)"
}
$serial = (($dev.Output -split "`r?`n" | Where-Object { $_ -match '^\S+\s+device\b' } | Select-Object -First 1) -split '\s+')[0]
Log "PhoneSerial=$serial"

$dump = Invoke-Adb -AdbArgs @('-s', $serial, 'shell', 'dumpsys', 'package', 'com.hawkeyexb.ppass')
$phoneVersion = $null
foreach ($line in ($dump.Output -split "`r?`n")) {
    if ($line -match 'versionName=(\S+)') { $phoneVersion = $Matches[1]; break }
}
if (-not $phoneVersion) { Finish $false "phone versionName not found" }

$desktopVersion = $null
$versionSource = ''
try {
    $desktopVersion = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass' -ErrorAction Stop).DisplayVersion
    $versionSource = 'HKCU Uninstall DisplayVersion'
} catch { }
if (-not $desktopVersion) {
    $exe = Join-Path $env:LOCALAPPDATA 'P-Pass\p-pass-desktop.exe'
    if (Test-Path -LiteralPath $exe) {
        $desktopVersion = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
        $versionSource = 'p-pass-desktop.exe ProductVersion'
    }
}
if (-not $desktopVersion) { Finish $false "desktop version not found" }

$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $ipcOut = & $bash $ipcScript 2>&1; $ipcCode = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
if ($ipcCode -ne 0) { Finish $false "ipc status helper exit ${ipcCode}: $((($ipcOut | Out-String).Trim()))" }
$ipcJson = (($ipcOut | Out-String).Trim()) | ConvertFrom-Json
$ipcVersion = $ipcJson.result.version
if (-not $ipcVersion) { Finish $false "ipc status has no result.version" }

Log ("{0,-28} {1}" -f 'phone versionName:', $phoneVersion)
Log ("{0,-28} {1}" -f "${versionSource}:", $desktopVersion)
Log ("{0,-28} {1}" -f 'ipc status version:', $ipcVersion)
Log ''
Log ("Three-way equal: {0}" -f ($phoneVersion -eq $desktopVersion -and $phoneVersion -eq $ipcVersion))
Log ("All equal expected: {0}" -f ($phoneVersion -eq $ExpectedVersion -and $desktopVersion -eq $ExpectedVersion -and $ipcVersion -eq $ExpectedVersion))

if ($phoneVersion -eq $ExpectedVersion -and $desktopVersion -eq $ExpectedVersion -and $ipcVersion -eq $ExpectedVersion) {
    Finish $true "$ExpectedVersion on phone, desktop and daemon"
} else {
    Finish $false "version mismatch"
}
