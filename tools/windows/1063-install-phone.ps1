#Requires -Version 5.1
# 1063-install-phone.ps1 - Uninstall the old P-Pass Android app, install the
# test.10 APK, grant the test permissions and whitelist battery optimization.
# Evidence goes to %USERPROFILE%\ppcheck\1063-test10\R0.1\.
#
# Only P-Pass is touched: no reboot, no system language change, no other app.
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\1063-install-phone.ps1 `
#     -Apk C:\Users\ethan\ppcheck\1063-test10\assets\P-Pass_0.10.0-test.10_android.apk
param(
    [Parameter(Mandatory = $true)][string]$Apk,
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [string]$ExpectedVersion = '0.10.0-test.10',
    [string]$Serial = ''
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot 'R0.1'
New-Item -ItemType Directory -Force $caseDir | Out-Null
$log = Join-Path $caseDir 'install-phone.txt'
$script:lines = New-Object System.Collections.Generic.List[string]

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
    $out = & adb @AdbArgs 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = (($out | Out-String).Trim()) }
}

Log "=== #1063 phone install $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Log "Apk=$Apk"
if (-not (Test-Path -LiteralPath $Apk)) { Finish $false "apk not found: $Apk" }
Log "ApkSha256=$((Get-FileHash -LiteralPath $Apk -Algorithm SHA256).Hash.ToLowerInvariant())"

$devices = Invoke-Adb -AdbArgs @('devices', '-l')
Log '--- adb devices -l ---'
Log $devices.Output
$deviceLines = @($devices.Output -split "`r?`n" | Where-Object { $_ -match '^\S+\s+device\b' })
if ($deviceLines.Count -ne 1) {
    Finish $false "expected exactly one authorized device, got $($deviceLines.Count)"
}
if ($Serial -eq '') { $Serial = ($deviceLines[0] -split '\s+')[0] }
Log "Serial=$Serial"

$pkg = 'com.hawkeyexb.ppass'
Log ''
Log "--- adb uninstall $pkg ---"
$un = Invoke-Adb -AdbArgs @('-s', $Serial, 'uninstall', $pkg)
Log $un.Output
# Failure is fine when the app was already absent.

Log ''
Log "--- adb install $Apk ---"
$inst = Invoke-Adb -AdbArgs @('-s', $Serial, 'install', $Apk)
Log $inst.Output
if ($inst.Code -ne 0 -or $inst.Output -notmatch 'Success') {
    Finish $false "adb install failed (exit $($inst.Code))"
}

Log ''
Log '--- pm grant (test-machine permissions) ---'
$perms = @(
    'android.permission.READ_MEDIA_IMAGES',
    'android.permission.READ_MEDIA_VIDEO',
    'android.permission.ACCESS_MEDIA_LOCATION',
    'android.permission.POST_NOTIFICATIONS'
)
foreach ($perm in $perms) {
    $g = Invoke-Adb -AdbArgs @('-s', $Serial, 'shell', 'pm', 'grant', $pkg, $perm)
    Log "grant $perm -> exit $($g.Code) $($g.Output)"
}

Log ''
Log '--- battery whitelist ---'
$b = Invoke-Adb -AdbArgs @('-s', $Serial, 'shell', 'dumpsys', 'deviceidle', 'whitelist', "+$pkg")
Log $b.Output

Log ''
Log '--- installed package ---'
$dump = Invoke-Adb -AdbArgs @('-s', $Serial, 'shell', 'dumpsys', 'package', $pkg)
$versionLines = @($dump.Output -split "`r?`n" | Where-Object { $_ -match 'versionName|versionCode|firstInstallTime|lastUpdateTime' } | Select-Object -First 6)
foreach ($line in $versionLines) { Log $line.Trim() }
$version = $null
foreach ($line in $versionLines) {
    if ($line -match 'versionName=(\S+)') { $version = $Matches[1] }
}
if (-not $version) { Finish $false "could not read versionName" }
Log "PhoneVersionName=$version"
if ($version -ne $ExpectedVersion) { Finish $false "versionName $version != $ExpectedVersion" }

Finish $true "installed $pkg $version on $Serial"
