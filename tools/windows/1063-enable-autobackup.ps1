#Requires -Version 5.1
# 1063-enable-autobackup.ps1 - Turn ON the phone's Settings > 后台备份 switch.
#
# Why this exists (#1063 R2.2/R2.3): FlowCore.kt treats
#   !userPresent && !conditions.autoBackupEnabled -> WaitReason.DISABLED
# as "needs the user" and registers no wake, so a disabled switch cannot be
# rescued by a background trigger. That is the designed behaviour, not a bug.
# A fresh install + pairing starts OFF: MainActivity clears the old intent
# (AutoBackupPrefs.setRequested(false)) and the onboarding completion page asks
# once, with "开启后台备份" / "不开启后台备份".
#
# The operation is idempotent: if the switch is already on it only verifies.
# Evidence:
#   <WorkRoot>\<CaseName>\ui-settings-before.xml
#   <WorkRoot>\<CaseName>\ui-settings-after.xml
#   <WorkRoot>\<CaseName>\jobscheduler.txt
#   <WorkRoot>\<CaseName>\result.txt
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\1063-enable-autobackup.ps1
param(
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [string]$CaseName = 'R0.6',
    [string]$Serial = ''
)

$ErrorActionPreference = 'Stop'
$pkg = 'com.hawkeyexb.ppass'
$caseDir = Join-Path $WorkRoot $CaseName
New-Item -ItemType Directory -Force $caseDir | Out-Null
$script:lines = New-Object System.Collections.Generic.List[string]
$adb = (Get-Command adb -ErrorAction Stop).Source

function Log([string]$msg) {
    Write-Output $msg
    $script:lines.Add($msg)
}
function Finish([string]$result, [string]$detail) {
    Log ''
    Log ("RESULT={0} {1}" -f $result, $detail)
    [IO.File]::WriteAllLines((Join-Path $caseDir 'result.txt'), $script:lines, (New-Object Text.UTF8Encoding($false)))
    switch ($result) {
        'PASS' { exit 0 }
        'UNCOVERED' { exit 2 }
        default { exit 1 }
    }
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
function Get-PhoneUi {
    param([string]$EvidenceName = '')
    $remote = '/sdcard/1063-ui.xml'
    $dump = Invoke-Adb -AdbArgs @('shell', 'uiautomator', 'dump', $remote)
    $local = if ($EvidenceName -ne '') { Join-Path $caseDir $EvidenceName } else { Join-Path $caseDir 'ui-last.xml' }
    Invoke-Adb -AdbArgs @('pull', $remote, $local) | Out-Null
    if (-not (Test-Path -LiteralPath $local)) { throw "uiautomator dump failed: $($dump.Output)" }
    $raw = [IO.File]::ReadAllText($local, [Text.Encoding]::UTF8)
    if ($raw -notmatch '<hierarchy') { throw "uiautomator dump is not XML: $($dump.Output)" }
    return $raw
}
function Find-TextNode {
    param([string]$Raw, [string]$Text)
    [xml]$doc = $Raw
    foreach ($n in $doc.SelectNodes('//node')) {
        if ([string]$n.text -eq $Text) { return $n }
    }
    foreach ($n in $doc.SelectNodes('//node')) {
        if ([string]$n.text -like "*$Text*") { return $n }
    }
    return $null
}
function Get-Center {
    param($Node)
    $m = [regex]::Match([string]$Node.bounds, '\[(\d+),(\d+)\]\[(\d+),(\d+)\]')
    if (-not $m.Success) { return $null }
    return @{
        X = [int](([int]$m.Groups[1].Value + [int]$m.Groups[3].Value) / 2)
        Y = [int](([int]$m.Groups[2].Value + [int]$m.Groups[4].Value) / 2)
    }
}
function Tap-Text {
    param([string]$Text)
    $raw = Get-PhoneUi
    $n = Find-TextNode -Raw $raw -Text $Text
    if (-not $n) { return $false }
    $c = Get-Center $n
    if (-not $c) { return $false }
    Invoke-Adb -AdbArgs @('shell', 'input', 'tap', $c.X, $c.Y) | Out-Null
    Log "tapped '$Text' at $($c.X),$($c.Y)"
    Start-Sleep -Milliseconds 800
    return $true
}
# The Settings rows are a label TextView plus a separate checkable View on the
# right. Match by vertical centre so a layout shift does not break the script.
function Find-RowSwitch {
    param([string]$Raw, [string]$RowText)
    [xml]$doc = $Raw
    $row = $null
    foreach ($n in $doc.SelectNodes('//node')) {
        if ([string]$n.text -eq $RowText) { $row = $n; break }
    }
    if (-not $row) { return $null }
    $rc = Get-Center $row
    if (-not $rc) { return $null }
    $m = [regex]::Match([string]$row.bounds, '\[(\d+),(\d+)\]\[(\d+),(\d+)\]')
    $rowRight = if ($m.Success) { [int]$m.Groups[3].Value } else { 0 }
    foreach ($n in $doc.SelectNodes('//node[@checkable="true"]')) {
        $c = Get-Center $n
        if ($c -and [math]::Abs($c.Y - $rc.Y) -le 45 -and $c.X -gt $rowRight) { return $n }
    }
    return $null
}

Log "=== #1063 background-backup switch $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
$dev = Invoke-Adb -AdbArgs @('devices', '-l')
Log $dev.Output
if (@($dev.Output -split "`r?`n" | Where-Object { $_ -match '^\S+\s+device\b' }).Count -ne 1) {
    Finish 'UNCOVERED' 'expected exactly one authorized Android device'
}

# Never work through the pattern lock: stop before touching anything.
$win = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'window')
$pre = Get-PhoneUi -EvidenceName 'ui-preflight.xml'
if ($win.Output -match 'mDreamingLockscreen=true' -or $pre -match '画出解锁图案|紧急呼叫') {
    Finish 'UNCOVERED' 'phone is on the secure keyguard; unlock it and rerun (no pattern bypass attempted)'
}

$pkgDump = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'package', $pkg)
$versionLine = @($pkgDump.Output -split "`r?`n" | Where-Object { $_ -match 'versionName=' } | Select-Object -First 1)
Log ("PhoneVersion=" + ($versionLine -join ' '))

Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '3') | Out-Null
Start-Sleep -Milliseconds 800
Invoke-Adb -AdbArgs @('shell', 'monkey', '-p', $pkg, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
Start-Sleep -Seconds 2
Tap-Text -Text '设置' | Out-Null

$deadline = (Get-Date).AddSeconds(20)
$beforeRaw = $null
$sw = $null
while ((Get-Date) -lt $deadline) {
    $beforeRaw = Get-PhoneUi -EvidenceName 'ui-settings-before.xml'
    $sw = Find-RowSwitch -Raw $beforeRaw -RowText '后台备份'
    if ($sw) { break }
    Start-Sleep -Seconds 1
}
if (-not $sw) {
    Get-PhoneUi -EvidenceName 'ui-no-background-row.xml' | Out-Null
    Finish 'FAIL' 'could not find 后台备份 on the Settings page'
}
$stateBefore = [string]$sw.checked
Log "SwitchBefore=$stateBefore bounds=$($sw.bounds)"
$action = 'already_on'

if ($stateBefore -ne 'true') {
    $c = Get-Center $sw
    if (-not $c) { Finish 'FAIL' 'could not compute the switch centre' }
    Invoke-Adb -AdbArgs @('shell', 'input', 'tap', $c.X, $c.Y) | Out-Null
    Log "tapped 后台备份 switch at $($c.X),$($c.Y)"
    $action = 'tapped'
    Start-Sleep -Seconds 1
    # Only reached when the install script did not whitelist battery
    # optimisation: the system dialog must be accepted for the switch to arm.
    $focus = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'window')
    if ($focus.Output -notmatch 'mCurrentFocus=.*com\.hawkeyexb\.ppass') {
        Tap-Text -Text '允许' | Out-Null
        Start-Sleep -Milliseconds 500
    }
}

$deadline = (Get-Date).AddSeconds(15)
$afterRaw = $null
$sw = $null
while ((Get-Date) -lt $deadline) {
    $afterRaw = Get-PhoneUi -EvidenceName 'ui-settings-after.xml'
    $sw = Find-RowSwitch -Raw $afterRaw -RowText '后台备份'
    if ($sw -and [string]$sw.checked -eq 'true') { break }
    Start-Sleep -Milliseconds 500
}
if (-not $sw -or [string]$sw.checked -ne 'true') {
    Finish 'FAIL' "background backup switch stayed OFF (before=$stateBefore)"
}
Log "SwitchAfter=$([string]$sw.checked) bounds=$($sw.bounds)"

$js = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'jobscheduler')
$keep = @($js.Output -split "`r?`n" | Where-Object { $_ -match 'BackupWorker|com\.hawkeyexb\.ppass' })
[IO.File]::WriteAllLines((Join-Path $caseDir 'jobscheduler.txt'), $keep, (New-Object Text.UTF8Encoding($false)))

# Leave the app in the background; the cases themselves decide when to open it.
Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '3') | Out-Null
Start-Sleep -Milliseconds 800
$homeRaw = Get-PhoneUi -EvidenceName 'ui-home-after.xml'
if ($homeRaw -match '画出解锁图案|紧急呼叫') {
    Finish 'UNCOVERED' 'phone locked itself after the switch operation'
}

Finish 'PASS' "background backup switch before=$stateBefore after=on action=$action"
