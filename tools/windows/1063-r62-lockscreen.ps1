#Requires -Version 5.1
# 1063-r62-lockscreen.ps1 - R6.2 locked-screen presence.
# Foreground the app, open "Family & devices", record IPC presence + the desktop
# device row, lock the phone for >2 minutes, read both again, then wake it.
# USB charging can keep the presence online; that is reported as PARTIAL.
param(
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [int]$LockSeconds = 130
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot 'R6.2'
New-Item -ItemType Directory -Force $caseDir | Out-Null
$timeline = Join-Path $caseDir 'timeline.txt'
$resultPath = Join-Path $caseDir 'result.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
$adb = (Get-Command adb -ErrorAction Stop).Source
$bash = 'C:\Program Files\Git\bin\bash.exe'
$devicesScript = Join-Path $PSScriptRoot '1063-ipc-devices.sh'
$uia = Join-Path $PSScriptRoot 'uia-drive.ps1'
$pkg = 'com.hawkeyexb.ppass'

function Log([string]$m) { [Console]::WriteLine($m); $script:lines.Add($m) }
function Event([string]$m) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $m"
    Add-Content -LiteralPath $timeline -Value $line -Encoding UTF8
    Log $line
}
function Finish([string]$result, [string]$detail) {
    $text = @("case=R6.2", "result=$result", "detail=$detail") + $script:lines
    [IO.File]::WriteAllLines($resultPath, $text, (New-Object Text.UTF8Encoding($false)))
    Log "RESULT=$result $detail"
    if ($result -eq 'PASS') { exit 0 } else { exit 1 }
}
function Invoke-Adb {
    param([string[]]$AdbArgs)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $adb @AdbArgs 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    return [pscustomobject]@{ Code = $code; Output = (($out | Out-String).Trim()) }
}
function Get-Devices {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $bash $devicesScript 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { return @() }
    try { $j = (($out | Out-String).Trim()) | ConvertFrom-Json; return @($j.result.devices) } catch { return @() }
}
function Get-PhoneWake {
    $r = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'power')
    $m = [regex]::Match($r.Output, 'mWakefulness=(\S+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'unknown'
}
function Dump-Ui([string]$Name) {
    $out = Join-Path $caseDir $Name
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uia -Action dump -Out $out 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { return '' }
    return (Get-Content -LiteralPath $out -Raw -Encoding UTF8)
}
function Click-Ui([string]$Name) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uia -Action click -Name $Name -Out (Join-Path $caseDir 'uia-click.txt') 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    return $code
}
function Save-Devices([string]$Name, $Devices) {
    $ls = New-Object System.Collections.Generic.List[string]
    $ls.Add("timestamp=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    foreach ($d in @($Devices)) {
        $prefix = ([string]$d.node_id).Substring(0, [Math]::Min(8, ([string]$d.node_id).Length))
        $ls.Add("name=$($d.name) node_prefix=$prefix paired=$($d.paired) presence=$($d.presence) connection=$($d.connection) last_seen=$($d.last_seen)")
    }
    [IO.File]::WriteAllLines((Join-Path $caseDir $Name), $ls, (New-Object Text.UTF8Encoding($false)))
    return ($ls -join '; ')
}
function Row-Lines([string]$Ui) {
    return @($Ui -split "`r?`n" | Where-Object { $_ -match 'Galaxy|SM_S928N|在线|分钟前|离线|Online|offline|minute' } | Select-Object -First 20)
}

Log "=== #1063 R6.2 locked-screen presence $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Event 'case start R6.2'
$pre = @(Get-Devices)
if ($pre.Count -lt 1) { Finish 'UNCOVERED' 'no paired device in devices.list' }

Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '224') | Out-Null
Invoke-Adb -AdbArgs @('shell', 'monkey', '-p', $pkg, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
Start-Sleep -Seconds 3
if (-not (Get-Process -Name 'p-pass-desktop' -ErrorAction SilentlyContinue)) { Finish 'UNCOVERED' 'p-pass-desktop is not running' }
# Wait for the daemon's presence to settle on "online" before locking.
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    $pre = @(Get-Devices)
    if ($pre.Count -gt 0 -and $pre[0].presence -eq 'online') { break }
    Start-Sleep -Seconds 1
}
$ui = Dump-Ui 'desktop-before.txt'
if ($ui -match '知道了') {
    Click-Ui -Name '知道了' | Out-Null
    Start-Sleep -Milliseconds 500
    $ui = Dump-Ui 'desktop-before.txt'
}
if ($ui -match '家人与设备') {
    Click-Ui -Name '家人与设备' | Out-Null
    Start-Sleep -Seconds 1
    $ui = Dump-Ui 'desktop-before.txt'
}
$beforeDev = Save-Devices 'before-devices.txt' $pre
$beforeRow = Row-Lines $ui
$beforeRow | Set-Content -LiteralPath (Join-Path $caseDir 'desktop-row-before.txt') -Encoding UTF8
Event "before devices=$beforeDev"
Event "before wake=$(Get-PhoneWake)"
$beforePresence = $pre[0].presence
$beforeRowText = ($beforeRow -join ' | ')

# Lock the phone and leave it alone for >2 minutes.
$powerOff = Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '26')
Start-Sleep -Seconds 3
$lockedWake = Get-PhoneWake
Event "after power key wake=$lockedWake"
if ($lockedWake -eq 'Awake') {
    Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '26') | Out-Null
    Start-Sleep -Seconds 2
    $lockedWake = Get-PhoneWake
    Event "second power key wake=$lockedWake"
}
Start-Sleep -Seconds $LockSeconds
$locked = @(Get-Devices)
$lockedText = Save-Devices 'locked-devices.txt' $locked
$lockedUi = Dump-Ui 'desktop-locked.txt'
$lockedRow = Row-Lines $lockedUi
$lockedRow | Set-Content -LiteralPath (Join-Path $caseDir 'desktop-row-locked.txt') -Encoding UTF8
Event "locked elapsed=${LockSeconds}s wake=$(Get-PhoneWake) devices=$lockedText"
Event "locked row=$($lockedRow -join ' | ')"

# Wake and unlock for the rest of the regression.
Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '26') | Out-Null
Start-Sleep -Seconds 1
Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '82') | Out-Null
Invoke-Adb -AdbArgs @('shell', 'input', 'swipe', '540', '2000', '540', '600', '300') | Out-Null
Start-Sleep -Seconds 3
$wakeAfter = Get-PhoneWake
Event "wake after=$wakeAfter"
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    $after = @(Get-Devices)
    if ($after.Count -gt 0 -and $after[0].presence -eq 'online') { break }
    Start-Sleep -Seconds 1
}
$afterText = Save-Devices 'after-wake-devices.txt' $after
$afterUi = Dump-Ui 'desktop-after-wake.txt'
$afterRow = Row-Lines $afterUi
$afterRow | Set-Content -LiteralPath (Join-Path $caseDir 'desktop-row-after-wake.txt') -Encoding UTF8
Event "after wake devices=$afterText"
Event "after wake row=$($afterRow -join ' | ')"

$lockedPresence = if ($locked.Count -gt 0) { $locked[0].presence } else { 'missing' }
$afterPresence = if ($after.Count -gt 0) { $after[0].presence } else { 'missing' }
$lockedRelative = (($lockedRow -join ' ') -match '分钟前|分钟|minute|离线|offline|unknown')
$afterOnline = ($afterPresence -eq 'online' -or (($afterRow -join ' ') -match '在线|online'))

if ($lockedPresence -ne 'online' -and $lockedRelative -and $afterOnline -and $beforePresence -eq 'online') {
    Finish 'PASS' "presence $beforePresence -> $lockedPresence -> $afterPresence; locked row shows relative/offline"
} elseif ($lockedPresence -eq 'online') {
    Finish 'PARTIAL' "presence stayed online while locked (USB charging likely interferes); before=$beforePresence after=$afterPresence"
} else {
    Finish 'PARTIAL' "before=$beforePresence locked=$lockedPresence after=$afterPresence lockedRelative=$lockedRelative afterOnline=$afterOnline"
}
