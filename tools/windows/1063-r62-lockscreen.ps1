#Requires -Version 5.1
# 1063-r62-lockscreen.ps1 - R6.2 locked-screen presence.
#
# Tiers:
#   1) online baseline: the phone app is foreground, and the desktop shows the
#      paired phone online in both `devices.list` (presence) and the
#      "Family & devices" UIA row.
#   2) screen off: keyevent 26, wait >2 minutes, then read `devices.list` and the
#      desktop row again. Criterion: the row shows a relative "N minutes ago
#      online" / "recently online" state (presence no longer live online).
#   3) locked -> online again: NOT tested, because the phone has an unknown
#      pattern lock. The script wakes the phone, confirms it sits on the lock
#      screen, and deliberately leaves it there without trying to unlock.
#
# The caller must have restored the phone's original keep-awake setting
# (`adb shell svc power stayon false`) before this case; the script records and
# verifies it. Turning the screen off is the operation under test here.
param(
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [int]$LockSeconds = 130,
    # Re-read the locked desktop row after the WebView has repainted. Desktop
    # only: sends no input to the phone, for a run where the first locked dump
    # raced the repaint and the phone is already on the lock screen.
    [switch]$RecheckLocked
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot 'R6.2'
New-Item -ItemType Directory -Force $caseDir | Out-Null
$timeline = Join-Path $caseDir 'timeline.txt'
$resultPath = Join-Path $caseDir 'result.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
$script:lastDevicesRaw = ''
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
    $raw = (($out | Out-String).Trim())
    $script:lastDevicesRaw = $raw
    try { $j = $raw | ConvertFrom-Json; return @($j.result.devices) } catch { return @() }
}
function Save-RawDevices([string]$Name) {
    if ($script:lastDevicesRaw) {
        [IO.File]::WriteAllText((Join-Path $caseDir $Name), $script:lastDevicesRaw, (New-Object Text.UTF8Encoding($false)))
    }
}
function Get-PhoneWake {
    $r = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'power')
    $m = [regex]::Match($r.Output, 'mWakefulness=(\S+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'unknown'
}
function Get-PhoneFocus {
    $r = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'window')
    $m = [regex]::Match($r.Output, 'mCurrentFocus=(.+)')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}
function Get-KeyguardShowing {
    $r = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'window', 'policy')
    $m = [regex]::Match($r.Output, 'mIsShowing=(true|false)')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'unknown'
}
function Get-StayOnSetting {
    $r = Invoke-Adb -AdbArgs @('shell', 'settings', 'get', 'global', 'stay_on_while_plugged_in')
    return $r.Output.Trim()
}
function Get-PhoneUi([string]$Name) {
    $remote = '/sdcard/1063-r62-ui.xml'
    Invoke-Adb -AdbArgs @('shell', 'uiautomator', 'dump', $remote) | Out-Null
    $r = Invoke-Adb -AdbArgs @('shell', 'cat', $remote)
    $text = $r.Output
    [IO.File]::WriteAllText((Join-Path $caseDir $Name), $text, (New-Object Text.UTF8Encoding($false)))
    return $text
}
function Test-Locked([string]$UiText) {
    # The pattern-lock screen carries "draw your unlock pattern" in its node text.
    return ($UiText -match '画出解锁图案|绘制解锁图案|解锁图案|输入密码|输入 PIN')
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
        $ls.Add("name=$($d.name) node_prefix=$prefix paired=$($d.paired) presence=$($d.presence) connection=$($d.connection) row_state=$($d.row_state) last_seen=$($d.last_seen)")
    }
    [IO.File]::WriteAllLines((Join-Path $caseDir $Name), $ls, (New-Object Text.UTF8Encoding($false)))
    return ($ls -join '; ')
}
function Row-Lines([string]$Ui) {
    return @($Ui -split "`r?`n" | Where-Object { $_ -match 'Galaxy|SM_S928N|在线|分钟前|小时前|离线|Online|offline|minute' } | Select-Object -First 20)
}

if ($RecheckLocked) {
    # Desktop-only re-read; the phone is already locked and is not touched.
    Event 'recheck locked row (desktop only, phone untouched)'
    $dev = @(Get-Devices)
    Save-RawDevices 'locked-settled-devices.json'
    $devText = Save-Devices 'locked-settled-devices.txt' $dev
    $uiText = Dump-Ui 'desktop-locked-settled.txt'
    $row = @(Row-Lines $uiText)
    $presence = if ($dev.Count -gt 0) { $dev[0].presence } else { 'missing' }
    $summary = @(
        "timestamp=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "presence=$presence",
        "row=$($row -join ' | ')",
        "phone_keyguard=$(Get-KeyguardShowing)",
        'note=desktop re-read after the WebView repaint; no phone input sent'
    )
    [IO.File]::WriteAllLines((Join-Path $caseDir 'locked-settled.txt'), $summary, (New-Object Text.UTF8Encoding($false)))
    Log "devices=$devText"
    Log ($summary -join '; ')

    # Reconcile the final verdict with the settled row. The raw run stays in
    # result.txt; locked-settled.txt keeps its own timestamp.
    $beforePresence = 'missing'
    $beforeJson = Join-Path $caseDir 'before-devices.json'
    if (Test-Path -LiteralPath $beforeJson) {
        try { $beforePresence = ((Get-Content -LiteralPath $beforeJson -Raw -Encoding UTF8) | ConvertFrom-Json).result.devices[0].presence } catch { }
    }
    $beforeRowFile = Join-Path $caseDir 'desktop-row-before.txt'
    $beforeRowText = if (Test-Path -LiteralPath $beforeRowFile) { (Get-Content -LiteralPath $beforeRowFile -Raw -Encoding UTF8) } else { '' }
    $tier1 = ($beforePresence -eq 'online') -and ($beforeRowText -match '在线')
    $tier2 = (($row -join ' ') -match '(分钟|小时|天)前在线|最近在线') -or (($presence -ne 'online') -and (($row -join ' ') -match '离线|不在线'))
    $keyguard = Get-KeyguardShowing
    $final = @(
        'case=R6.2',
        'result=PARTIAL',
        "tier1.online_background=$tier1 (before presence=$beforePresence, row had 在线=$($beforeRowText -match '在线'))",
        "tier2.online_to_locked=$tier2 (presence=$presence, row='$($row -join ' | ')')",
        "tier3.locked_to_online=NOT_COVERED (phone left on the pattern lock, keyguard=$keyguard; no unlock attempted)",
        'note=the raw run read the desktop row before the WebView repainted; the script now polls. This settled re-read sent no input to the phone.'
    )
    [IO.File]::WriteAllLines((Join-Path $caseDir 'result-final.txt'), $final, (New-Object Text.UTF8Encoding($false)))
    Log "final: $($final -join ' | ')"
    exit 0
}

Log "=== #1063 R6.2 locked-screen presence $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Event 'case start R6.2'

# 0) The caller restored the original keep-awake setting before this case.
$stay = Get-StayOnSetting
Event "stay_on_while_plugged_in=$stay (expected 0; restored before the case)"
if ($stay -ne '0') { Finish 'UNCOVERED' "keep-awake setting is '$stay', expected 0/false; restore svc power stayon false first" }

# 1a) The phone must be unlocked and show the app before we touch anything.
$phoneBefore = Get-PhoneUi 'phone-before.txt'
$keyguardBefore = Get-KeyguardShowing
Event "phone before: wake=$(Get-PhoneWake) keyguard=$keyguardBefore lockedPattern=$(Test-Locked $phoneBefore)"
if ((Test-Locked $phoneBefore) -or $keyguardBefore -eq 'true') {
    Finish 'UNCOVERED' 'phone is already on the lock screen; refusing to touch it (pattern lock unknown)'
}
$focus = Get-PhoneFocus
if ($focus -notmatch [regex]::Escape($pkg)) {
    Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '224') | Out-Null
    Invoke-Adb -AdbArgs @('shell', 'monkey', '-p', $pkg, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
    Start-Sleep -Seconds 3
    $focus = Get-PhoneFocus
}
Event "phone focus=$focus"
if ($focus -notmatch [regex]::Escape($pkg)) { Finish 'UNCOVERED' "P-Pass is not the foreground app: $focus" }

# 1b) Desktop: daemon presence plus the "Family & devices" device row.
if (-not (Get-Process -Name 'p-pass-desktop' -ErrorAction SilentlyContinue)) { Finish 'UNCOVERED' 'p-pass-desktop is not running' }
$pre = @(Get-Devices)
if ($pre.Count -lt 1) { Finish 'UNCOVERED' 'no paired device in devices.list' }
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    if ($pre.Count -gt 0 -and $pre[0].presence -eq 'online') { break }
    Start-Sleep -Seconds 1
    $pre = @(Get-Devices)
}
Save-RawDevices 'before-devices.json'
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
$beforeRow = @(Row-Lines $ui)
$beforeRow | Set-Content -LiteralPath (Join-Path $caseDir 'desktop-row-before.txt') -Encoding UTF8
$beforePresence = if ($pre.Count -gt 0) { $pre[0].presence } else { 'missing' }
$beforeRowText = ($beforeRow -join ' | ')
Event "before devices=$beforeDev"
Event "before row=$beforeRowText"
$beforeOnline = ($beforePresence -eq 'online') -and ($beforeRowText -match '在线')
Event "tier1 online baseline: presence=$beforePresence rowOnline=$($beforeRowText -match '在线') ok=$beforeOnline"
if (-not $beforeOnline) { Finish 'UNCOVERED' "baseline not online: presence=$beforePresence row=$beforeRowText" }

# Confirm once more that the phone is still unlocked right before sleeping it.
$lockCheck = Get-PhoneUi 'phone-before-sleep.txt'
if ((Test-Locked $lockCheck) -or (Get-KeyguardShowing) -eq 'true') {
    Finish 'UNCOVERED' 'phone locked before the screen-off step; no screen-off reading taken'
}

# 2) Screen off, leave it alone for >2 minutes.
$powerOff = Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '26')
Start-Sleep -Seconds 3
$lockedWake = Get-PhoneWake
if ($lockedWake -eq 'Awake') {
    Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '26') | Out-Null
    Start-Sleep -Seconds 2
    $lockedWake = Get-PhoneWake
    Event "second power key wake=$lockedWake"
}
Event "screen off: keyevent26 code=$($powerOff.Code) wake=$lockedWake"
if ($lockedWake -eq 'Awake') { Finish 'PARTIAL' 'keyevent 26 did not put the phone to sleep; locked-screen presence not exercised' }

$sleepStart = Get-Date
Start-Sleep -Seconds $LockSeconds
$elapsed = [int]((Get-Date) - $sleepStart).TotalSeconds

# The desktop WebView repaints a moment after the daemon flips presence to
# "recent". Poll the row (up to 30s) so the UIA read is not a stale "online".
$locked = @(Get-Devices)
$lockedUi = Dump-Ui 'desktop-locked.txt'
$lockedRow = @(Row-Lines $lockedUi)
$settleStart = Get-Date
$settleDeadline = $settleStart.AddSeconds(30)
while ((Get-Date) -lt $settleDeadline) {
    $txt = ($lockedRow -join ' ')
    $presenceNow = if ($locked.Count -gt 0) { $locked[0].presence } else { 'missing' }
    if ($txt -match '(分钟|小时|天)前在线|最近在线') { break }
    if (($presenceNow -ne 'online') -and ($txt -match '离线|不在线')) { break }
    Start-Sleep -Seconds 3
    $locked = @(Get-Devices)
    $lockedUi = Dump-Ui 'desktop-locked.txt'
    $lockedRow = @(Row-Lines $lockedUi)
}
$settleSeconds = [int]((Get-Date) - $settleStart).TotalSeconds
Save-RawDevices 'locked-devices.json'
$lockedText = Save-Devices 'locked-devices.txt' $locked
$lockedRow | Set-Content -LiteralPath (Join-Path $caseDir 'desktop-row-locked.txt') -Encoding UTF8
$lockedPresence = if ($locked.Count -gt 0) { $locked[0].presence } else { 'missing' }
$lockedRowText = ($lockedRow -join ' | ')
Event "locked: elapsed=${elapsed}s wake=$(Get-PhoneWake) devices=$lockedText"
Event "locked row settled after ${settleSeconds}s: $lockedRowText"

# Criterion: a relative "N minutes/hours ago online" / "recently online" row,
# or at least a non-online presence with an offline marker on the row.
$lockedRelative = ($lockedRowText -match '(分钟|小时|天)前在线|最近在线|N分钟前在线')
$lockedOfflineMarker = ($lockedPresence -ne 'online') -and ($lockedRowText -match '离线|不在线')
$tier2 = $lockedRelative -or $lockedOfflineMarker
Event "tier2 locked reading: presence=$lockedPresence relative=$lockedRelative offlineMarker=$lockedOfflineMarker ok=$tier2"

# 3) Wake the phone. It stops on the pattern lock; leave it there, never unlock.
Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '224') | Out-Null
Start-Sleep -Seconds 2
$phoneAfter = Get-PhoneUi 'phone-after-wake.txt'
$keyguardAfter = Get-KeyguardShowing
$afterLocked = Test-Locked $phoneAfter
Event "woke phone: wake=$(Get-PhoneWake) keyguard=$keyguardAfter patternPadVisible=$afterLocked"


# Locked -> online again is untestable without the pattern. Record the last
# desktop reading while the phone is still locked, for the record only.
$afterWake = @(Get-Devices)
Save-RawDevices 'after-wake-devices.json'
$afterWakeText = Save-Devices 'after-wake-devices.txt' $afterWake
$afterUi = Dump-Ui 'desktop-after-wake.txt'
$afterRow = @(Row-Lines $afterUi)
$afterRow | Set-Content -LiteralPath (Join-Path $caseDir 'desktop-row-after-wake.txt') -Encoding UTF8
Event "after wake (still locked) devices=$afterWakeText"
Event "after wake (still locked) row=$($afterRow -join ' | ')"

$reason = "locked->online tier not covered: phone left on the pattern lock (keyguard=$keyguardAfter, patternPadVisible=$afterLocked); no unlock attempted"
if ($tier2) {
    Finish 'PARTIAL' "online->locked PASS: presence $beforePresence -> $lockedPresence, row '$lockedRowText' after ${elapsed}s; $reason"
} else {
    Finish 'PARTIAL' "locked reading not relative/recent online: presence=$lockedPresence row='$lockedRowText' after ${elapsed}s; $reason"
}
