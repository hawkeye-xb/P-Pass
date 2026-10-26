#Requires -Version 5.1
# 1063-r34-doze.ps1 - R3.4 Doze: 5 small images are queued, the phone is forced
# into deep idle for 5 minutes, then unforced. Checks:
#   - count does not move and deviceidle stays IDLE during Doze
#   - UI copy stays calm (no error/retry spam)
#   - uid-filtered logcat line count during the Doze window
#   - after unforce/reset it reconnects and backs up the 5 images (max 15 min)
#
# Evidence: %USERPROFILE%\ppcheck\1063-test10\R3.4\
param(
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [int]$DozeSeconds = 300,
    [int]$RecoveryTimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot 'R3.4'
New-Item -ItemType Directory -Force $caseDir | Out-Null
$timeline = Join-Path $caseDir 'timeline.txt'
$counts = Join-Path $caseDir 'counts.txt'
$resultPath = Join-Path $caseDir 'result.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
$adb = (Get-Command adb -ErrorAction Stop).Source
$bash = 'C:\Program Files\Git\bin\bash.exe'
$ipcStatusScript = Join-Path $PSScriptRoot '1063-ipc-status.sh'
$verifyScript = Join-Path $PSScriptRoot '1063-verify-batch.ps1'
$pkg = 'com.hawkeyexb.ppass'
$albumPath = '/sdcard/DCIM/PPassRegression'

function Log([string]$m) { [Console]::WriteLine($m); $script:lines.Add($m) }
function Event([string]$m) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $m"
    Add-Content -LiteralPath $timeline -Value $line -Encoding UTF8
    Log $line
}
function Finish([string]$result, [string]$detail) {
    $text = @("case=R3.4", "result=$result", "detail=$detail") + $script:lines
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
function Get-Ipc {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $bash $ipcStatusScript 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { return $null }
    try { return ((($out | Out-String).Trim()) | ConvertFrom-Json) } catch { return $null }
}
function Get-Count {
    $s = Get-Ipc
    if ($s) { return [int]$s.result.photo_count }
    return -1
}
function Get-Uid {
    $r = Invoke-Adb -AdbArgs @('shell', 'pm', 'list', 'packages', '-U', $pkg)
    $m = [regex]::Match($r.Output, 'uid:(\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}
function Get-DozeState {
    $r = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'deviceidle')
    $state = ''
    $m = [regex]::Match($r.Output, 'mState=(\S+)')
    if ($m.Success) { $state = $m.Groups[1].Value }
    $screen = '?'
    $m2 = [regex]::Match($r.Output, 'mScreenOn=(true|false)')
    if ($m2.Success) { $screen = $m2.Groups[1].Value }
    return [pscustomobject]@{ State = $state; ScreenOn = $screen; Raw = $r.Output }
}
function Get-PhoneUi {
    param([string]$Name = '')
    $dump = Invoke-Adb -AdbArgs @('shell', 'uiautomator', 'dump', '/sdcard/1063-doze.xml')
    $cat = Invoke-Adb -AdbArgs @('exec-out', 'cat', '/sdcard/1063-doze.xml')
    $raw = [string]$cat.Output
    if ($raw -notmatch '<hierarchy') { return '' }
    if ($Name -ne '') { [IO.File]::WriteAllText((Join-Path $caseDir $Name), $raw, (New-Object Text.UTF8Encoding($false))) }
    return $raw
}
function Get-MediaCount {
    param([string]$Prefix)
    $r = Invoke-Adb -AdbArgs @('shell', 'content', 'query', '--uri', 'content://media/external/images/media', '--projection', '_data')
    return @($r.Output -split "`r?`n" | Where-Object { $_ -match ("/" + [regex]::Escape($Prefix) + "_\d+\.jpg") }).Count
}

Log "=== #1063 R3.4 Doze $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Event 'case start R3.4'
$pre = Get-Ipc
if (-not $pre -or [int]$pre.result.paired_devices -lt 1) { Finish 'UNCOVERED' 'no paired device' }
$before = [int]$pre.result.photo_count
if ($before -ne 40) { Finish 'UNCOVERED' "baseline is $before, expected 40" }
$svc = Get-Service 'P-Pass' -ErrorAction SilentlyContinue
if (-not $svc -or $svc.Status -ne 'Stopped') { Finish 'UNCOVERED' "P-Pass service is not Stopped" }
Log "Baseline=40 Paired=1 P-Pass=Stopped"

# Stop the app while queuing, so the five small files cannot be consumed before
# Doze starts.
Invoke-Adb -AdbArgs @('shell', 'am', 'force-stop', $pkg) | Out-Null
$batchDir = Join-Path $WorkRoot 'img\DOZE'
New-Item -ItemType Directory -Force $batchDir | Out-Null
Get-ChildItem -LiteralPath $batchDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
$py = @'
import os, sys
import numpy as np
from PIL import Image
out, n = sys.argv[1], int(sys.argv[2])
os.makedirs(out, exist_ok=True)
for i in range(1, n+1):
    rng = np.random.default_rng(1063 + i)
    arr = rng.integers(0, 256, size=(1800, 2400, 3), dtype=np.uint8)
    im = Image.fromarray(arr)
    path = os.path.join(out, f"DOZE_{i:04d}.jpg")
    for q in (85, 82, 80, 78, 75):
        im.save(path, "JPEG", quality=q, subsampling=0)
        if os.path.getsize(path) >= 2 * 1024 * 1024:
            break
    print(f"DOZE_{i:04d}.jpg {os.path.getsize(path)}")
'@
$old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $py | python - $batchDir 5 2>&1 | ForEach-Object { Log $_ }; $genCode = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
if ($genCode -ne 0) { Finish 'UNCOVERED' 'small image generation failed' }
$hashes = @(Get-ChildItem -LiteralPath $batchDir -Filter 'DOZE_*.jpg' | Sort-Object Name | ForEach-Object {
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
})
$hashes | Set-Content -LiteralPath (Join-Path $caseDir 'expected-DOZE.sha256') -Encoding UTF8
Event "generated $($hashes.Count) images"

$push = Invoke-Adb -AdbArgs @('push', ($batchDir + '\.'), "$albumPath/")
Add-Content -LiteralPath (Join-Path $caseDir 'push.txt') -Value $push.Output -Encoding UTF8
Invoke-Adb -AdbArgs @('shell', 'content', 'call', '--uri', 'content://media', '--method', 'scan_volume', '--arg', 'external_primary') | Out-Null
foreach ($f in (Get-ChildItem -LiteralPath $batchDir -Filter 'DOZE_*.jpg')) {
    Invoke-Adb -AdbArgs @('shell', 'content', 'call', '--uri', 'content://media/external/images/media', '--method', 'scan_file', '--arg', "$albumPath/$($f.Name)") | Out-Null
}
Start-Sleep -Seconds 2
$mediaN = Get-MediaCount -Prefix 'DOZE'
Event "MediaStore DOZE=$mediaN expected=5"
if ($mediaN -lt 5) { Finish 'UNCOVERED' "MediaStore only has $mediaN/5" }

# Launch the app, then immediately force the phone into deep idle.
Invoke-Adb -AdbArgs @('shell', 'monkey', '-p', $pkg, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
Start-Sleep -Seconds 1
$c0 = Get-Count
Event "before Doze count=$c0"
$unplug = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'battery', 'unplug')
$force = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'deviceidle', 'force-idle')
Event "battery unplug=$($unplug.Code) force-idle=$($force.Code): $($force.Output)"
Start-Sleep -Seconds 2
$st = Get-DozeState
Event "Doze start state=$($st.State) screen=$($st.ScreenOn)"
$dozeStart = Get-Date
$dozeUi = Get-PhoneUi -Name 'phone-doze-start.xml'
if ($dozeUi -match '错误|失败|重试|error|failed|retry') { Event 'UI_COPY=error_words_present' } else { Event 'UI_COPY=no_error_words' }

$uid = Get-Uid
Event "uid=$uid"
$logStart = $dozeStart.ToString('MM-dd HH:mm:ss')
$dozeTimeline = New-Object System.Collections.Generic.List[string]
$dozeTimeline.Add("start=$($dozeStart.ToString('yyyy-MM-dd HH:mm:ss')) count=$c0")
for ($i = 0; $i -lt [int]($DozeSeconds / 60); $i++) {
    Start-Sleep -Seconds 60
    $c = Get-Count
    $s = Get-DozeState
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') minute=$($i+1) count=$c state=$($s.State) screen=$($s.ScreenOn)"
    $dozeTimeline.Add($line)
    Event $line
    Add-Content -LiteralPath $counts -Value $line -Encoding UTF8
}
$cEnd = Get-Count
$stEnd = Get-DozeState
$dozeEnd = Get-Date
$dozeUi2 = Get-PhoneUi -Name 'phone-doze-end.xml'
$dozeTimeline.Add("end=$($dozeEnd.ToString('yyyy-MM-dd HH:mm:ss')) count=$cEnd state=$($stEnd.State)")
$dozeTimeline | Set-Content -LiteralPath (Join-Path $caseDir 'doze-timeline.txt') -Encoding UTF8

# UID-filtered logcat only for the Doze window.
if ($uid) {
    $out = Invoke-Adb -AdbArgs @('logcat', '-d', '-v', 'threadtime', "--uid=$uid")
    $logLines = @($out.Output -split "`r?`n" | Where-Object {
        $_ -match '^\d{2}-\d{2} \d{2}:\d{2}:\d{2}' -and $_.Substring(0,18) -ge $logStart -and $_.Substring(0,18) -le $dozeEnd.ToString('MM-dd HH:mm:ss')
    })
    $logLines | Set-Content -LiteralPath (Join-Path $caseDir 'logcat-doze.txt') -Encoding UTF8
    $dozeLogCount = $logLines.Count
} else { $dozeLogCount = -1 }
Event "Doze logcat lines=$dozeLogCount"

# Leave Doze and restore the battery/charging state.
$unforce = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'deviceidle', 'unforce')
$reset = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'battery', 'reset')
Event "unforce=$($unforce.Code) reset=$($reset.Code)"
Start-Sleep -Seconds 3
$stAfter = Get-DozeState
Event "after unforce state=$($stAfter.State) screen=$($stAfter.ScreenOn)"
# Make sure the screen is on for the recovery observation.
if ($stAfter.ScreenOn -eq 'false') {
    Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '26') | Out-Null
    Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '82') | Out-Null
}

$deadline = (Get-Date).AddSeconds($RecoveryTimeoutSeconds)
$recovered = $false
$last = -1
while ((Get-Date) -lt $deadline) {
    $c = Get-Count
    $s = Get-DozeState
    if ($c -ne $last) {
        Event "recovery count=$c state=$($s.State)"
        $last = $c
    }
    if ($c -eq 45) { $recovered = $true; break }
    Start-Sleep -Seconds 2
}
$finalCount = Get-Count
$conv = Invoke-Adb -AdbArgs @('shell', 'pidof', $pkg)
Event "recovery done count=$finalCount app_pid=$($conv.Output)"
$verifyOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Case R3.4 -BatchPrefix DOZE -ExpectedTotal 45 -BaselineCount 40 2>&1
$verifyCode = $LASTEXITCODE
$verifyOut | ForEach-Object { Log $_ }
$minuteStates = @($dozeTimeline | Where-Object { $_ -match 'minute=' } | ForEach-Object {
    $m = [regex]::Match($_, 'state=(\S+)')
    if ($m.Success) { $m.Groups[1].Value }
})
$allIdle = ($minuteStates.Count -ge 1 -and @($minuteStates | Where-Object { $_ -notin @('IDLE', 'IDLE_MAINTENANCE') }).Count -eq 0)
$dozeStayedIdle = ($st.State -eq 'IDLE' -and $stEnd.State -eq 'IDLE' -and $allIdle)
$countStayed = ($cEnd -eq $c0)
$calm = ($dozeLogCount -ge 0 -and $dozeLogCount -lt 400)
$uiCalm = -not ($dozeUi -match '错误|失败|重试|error|failed|retry')

if ($recovered -and $verifyCode -eq 0 -and $dozeStayedIdle -and $countStayed -and $calm -and $uiCalm) {
    Finish 'PASS' "5/5 filled; Doze stayed IDLE; count $c0->$cEnd; logcat=$dozeLogCount lines"
} else {
    Finish 'PARTIAL' "recovered=$recovered verify=$verifyCode dozeIdle=$dozeStayedIdle countStayed=$countStayed calm=$calm uiCalm=$uiCalm logcat=$dozeLogCount"
}
