#Requires -Version 5.1
# 1063-r22-r23.ps1 - R2.2 Wi-Fi interruption / R2.3 app-crash continuation.
#
# Both cases require proof that the break landed *during* a transfer. We push a
# fresh batch of 30 large (15-20MB) random-noise JPEGs, trigger a backup, and
# only then disable Wi-Fi (R2.2) or crash the Android app (R2.3). Recovery is
# automatic: no phone UI touches until a case is declared failed.
#
# Evidence: %USERPROFILE%\ppcheck\1063-test10\<R2.2|R2.3>\
#   timeline.txt, counts.txt, push.txt, inflight.txt, before/after wifi,
#   crash.txt, jobscheduler.txt, logcat*.txt, reconcile.txt, result.txt
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\1063-r22-r23.ps1 -Case R2.2
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\1063-r22-r23.ps1 -Case R2.3
param(
    [Parameter(Mandatory = $true)][ValidateSet('R2.2', 'R2.3')][string]$Case,
    [int]$Count = 30,
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [int]$InFlightTimeoutSeconds = 75,
    [int]$RecoveryTimeoutSeconds = 900,
    [int]$ManualTimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot $Case
New-Item -ItemType Directory -Force $caseDir | Out-Null
$timelinePath = Join-Path $caseDir 'timeline.txt'
$countsPath = Join-Path $caseDir 'counts.txt'
$logPath = Join-Path $caseDir 'result.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
$script:caseStart = Get-Date
$adb = (Get-Command adb -ErrorAction Stop).Source
$bash = 'C:\Program Files\Git\bin\bash.exe'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ipcStatusScript = Join-Path $PSScriptRoot '1063-ipc-status.sh'
$genScript = Join-Path $PSScriptRoot '1063-gen-large-images.py'
$pkg = 'com.hawkeyexb.ppass'
$albumPath = '/sdcard/DCIM/PPassRegression'

function Log([string]$msg) {
    # Console output must not go to the success stream: callers such as
    # Wait-Converged/Verify-Batch return booleans, and PowerShell would collect
    # every logged line into that return value, making a false result truthy.
    [Console]::WriteLine($msg)
    $script:lines.Add($msg)
}
function Event([string]$msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $msg"
    Add-Content -LiteralPath $timelinePath -Value $line -Encoding UTF8
    Log $line
}
function Finish([string]$result, [string]$detail) {
    $script:caseEnd = Get-Date
    Event "case end result=$result detail=$detail"
    $text = @()
    $text += "case=$Case"
    $text += "result=$result"
    $text += "detail=$detail"
    $text += "start=$($script:caseStart.ToString('yyyy-MM-dd HH:mm:ss'))"
    $text += "end=$($script:caseEnd.ToString('yyyy-MM-dd HH:mm:ss'))"
    $text += $script:lines
    [IO.File]::WriteAllLines($logPath, $text, (New-Object Text.UTF8Encoding($false)))
    Log ''
    Log "RESULT=$result $detail"
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
function Get-PhotoCount {
    $s = Get-IpcStatus
    if (-not $s) { return -1 }
    return [int]$s.result.photo_count
}
function Get-IpcFlag {
    param([string]$Name)
    $s = Get-IpcStatus
    if (-not $s) { return $null }
    return $s.result.$Name
}
function Record-Count([string]$Tag) {
    $s = Get-IpcStatus
    if (-not $s) {
        Add-Content -LiteralPath $countsPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $Tag ipc=DOWN" -Encoding UTF8
        return -1
    }
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $Tag count=$($s.result.photo_count) active=$($s.result.transfer_active) state=$($s.result.state)"
    Add-Content -LiteralPath $countsPath -Value $line -Encoding UTF8
    return [int]$s.result.photo_count
}
function Get-PhoneUi {
    param([string]$EvidenceName = '')
    $dump = Invoke-Adb -AdbArgs @('shell', 'uiautomator', 'dump', '/sdcard/1063-ui.xml')
    $cat = Invoke-Adb -AdbArgs @('exec-out', 'cat', '/sdcard/1063-ui.xml')
    $raw = [string]$cat.Output
    if ($raw -notmatch '<hierarchy') { throw "uiautomator dump failed: $($dump.Output)" }
    if ($EvidenceName -ne '') {
        [IO.File]::WriteAllText((Join-Path $caseDir $EvidenceName), $raw, (New-Object Text.UTF8Encoding($false)))
    }
    return $raw
}
function Find-PhoneNode {
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
function Get-NodeCenter {
    param($Node)
    $m = [regex]::Match([string]$Node.bounds, '\[(\d+),(\d+)\]\[(\d+),(\d+)\]')
    if (-not $m.Success) { return $null }
    return @{ X = [int](([int]$m.Groups[1].Value + [int]$m.Groups[3].Value) / 2); Y = [int](([int]$m.Groups[2].Value + [int]$m.Groups[4].Value) / 2) }
}
function Tap-PhoneText {
    param([string]$Text, [int]$Scrolls = 0, [int]$TimeoutSeconds = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $raw = Get-PhoneUi
            $n = Find-PhoneNode -Raw $raw -Text $Text
            if ($n) {
                $c = Get-NodeCenter $n
                if ($c) {
                    Invoke-Adb -AdbArgs @('shell', 'input', 'tap', $c.X, $c.Y) | Out-Null
                    Event "phone tap '$Text' at $($c.X),$($c.Y)"
                    Start-Sleep -Milliseconds 600
                    return $true
                }
            }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    for ($i = 1; $i -le $Scrolls; $i++) {
        Invoke-Adb -AdbArgs @('shell', 'input', 'swipe', '540', '1750', '540', '850', '300') | Out-Null
        Start-Sleep -Milliseconds 600
        try {
            $raw = Get-PhoneUi
            $n = Find-PhoneNode -Raw $raw -Text $Text
            if ($n) {
                $c = Get-NodeCenter $n
                if ($c) {
                    Invoke-Adb -AdbArgs @('shell', 'input', 'tap', $c.X, $c.Y) | Out-Null
                    Event "phone tap '$Text' after scroll at $($c.X),$($c.Y)"
                    Start-Sleep -Milliseconds 600
                    return $true
                }
            }
        } catch { }
    }
    return $false
}
function Get-DataDir {
    $conf = Join-Path $env:LOCALAPPDATA 'com.hawkeyexb.ppass.desktop\config.toml'
    if (-not (Test-Path -LiteralPath $conf)) { throw "no config.toml at $conf" }
    $text = Get-Content -LiteralPath $conf -Raw -Encoding UTF8
    $m = [regex]::Match($text, '(?m)^\s*data_dir\s*=\s*["''](.+?)["'']\s*$')
    if (-not $m.Success) { throw "could not parse data_dir from $conf" }
    $dir = $m.Groups[1].Value -replace '\\\\', '\'
    return (Resolve-Path -LiteralPath $dir).Path
}
function Get-OriginalsHashes {
    param([string]$DataDir)
    $dir = Join-Path $DataDir 'originals'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction Stop | ForEach-Object {
        (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    })
}
function Get-MediaCount {
    param([string]$Prefix)
    $r = Invoke-Adb -AdbArgs @('shell', 'content', 'query', '--uri', 'content://media/external/images/media', '--projection', '_data')
    return @($r.Output -split "`r?`n" | Where-Object { $_ -match ("/" + [regex]::Escape($Prefix) + "_\d+\.jpg") }).Count
}
function Push-Batch {
    param([string]$Dir, [string]$Prefix)
    $push = Invoke-Adb -AdbArgs @('push', ($Dir + '\.'), "$albumPath/")
    Add-Content -LiteralPath (Join-Path $caseDir 'push.txt') -Value "PUSH $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))`n$($push.Output)" -Encoding UTF8
    Event "pushed $Count files to $albumPath"
    Invoke-Adb -AdbArgs @('shell', 'content', 'call', '--uri', 'content://media', '--method', 'scan_volume', '--arg', 'external_primary') | Out-Null
    Start-Sleep -Seconds 2
    $deadline = (Get-Date).AddSeconds(90)
    $scanFiles = $false
    while ((Get-Date) -lt $deadline) {
        $n = Get-MediaCount -Prefix $Prefix
        if ($n -ge $Count) { break }
        if (-not $scanFiles) {
            foreach ($f in (Get-ChildItem -LiteralPath $Dir -Filter '*.jpg' -File)) {
                Invoke-Adb -AdbArgs @('shell', 'content', 'call', '--uri', 'content://media/external/images/media', '--method', 'scan_file', '--arg', "$albumPath/$($f.Name)") | Out-Null
            }
            $scanFiles = $true
        }
        Start-Sleep -Seconds 2
    }
    $n = Get-MediaCount -Prefix $Prefix
    Add-Content -LiteralPath (Join-Path $caseDir 'push.txt') -Value "MEDIASTORE $Prefix=$n expected=$Count" -Encoding UTF8
    Event "MediaStore $Prefix=$n"
    if ($n -lt $Count) { throw "MediaStore only has $n/$Count for $Prefix" }
}
function Trigger-Backup {
    Event 'trigger: HOME + relaunch to fire APP_FOREGROUND'
    Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '3') | Out-Null
    Start-Sleep -Milliseconds 800
    Invoke-Adb -AdbArgs @('shell', 'monkey', '-p', $pkg, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
    Start-Sleep -Seconds 2
    # If content/foreground trigger already started, do not touch the UI.
    $start = Get-PhotoCount
    Start-Sleep -Seconds 3
    $now = Get-PhotoCount
    if ($now -gt $start) {
        Event "trigger=foreground started (count $start->$now)"
        return 'foreground'
    }
    Event 'trigger=foreground did not move count; using Settings > backup scope > Start backup'
    if (-not (Tap-PhoneText -Text '设置' -TimeoutSeconds 10)) { return 'none' }
    Start-Sleep -Seconds 1
    if (-not (Tap-PhoneText -Text '备份哪些相册' -Scrolls 3 -TimeoutSeconds 15)) { return 'none' }
    Start-Sleep -Seconds 1
    Get-PhoneUi -EvidenceName 'phone-bucket-trigger.xml' | Out-Null
    if (-not (Tap-PhoneText -Text '开始备份' -TimeoutSeconds 15)) { return 'none' }
    return 'settings-bucket'
}
function Wait-InFlight {
    param([int]$Baseline, [int]$Total, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $s = Get-IpcStatus
        if ($s) {
            $c = [int]$s.result.photo_count
            $active = $s.result.transfer_active
            Add-Content -LiteralPath $countsPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') in-flight count=$c active=$active" -Encoding UTF8
            if ($c -gt $Baseline -and $c -lt $Total) {
                Event "IN-FLIGHT count=$c baseline=$Baseline total=$Total active=$active"
                return $true
            }
            if ($c -ge $Total) {
                Event "TOO-FAST count=$c total=$Total"
                return $false
            }
        }
        Start-Sleep -Milliseconds 500
    }
    Event "IN-FLIGHT NOT SEEN baseline=$Baseline total=$Total"
    return $false
}
function Snapshot-Jobscheduler {
    param([string]$Tag, [int]$Count, [bool]$Active)
    $out = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'jobscheduler')
    $lines = $out.Output -split "`r?`n"
    $block = @()
    $jobIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'JOB .*#BackupWorker#') { $jobIdx = $i; break }
    }
    if ($jobIdx -ge 0) {
        $end = [Math]::Min($lines.Count - 1, $jobIdx + 45)
        for ($j = $jobIdx; $j -le $end; $j++) {
            if ($j -gt $jobIdx -and $lines[$j] -match '^\s*JOB ') { break }
            $block += $lines[$j]
        }
    }
    $status = @($lines | Where-Object { $_ -match 'JobStatus\{.*#BackupWorker#' } | Select-Object -First 1)
    if ($status.Count -gt 0) { $block += $status }
    if ($block.Count -eq 0) { $block += 'NO_BACKUPWORKER_SECTION' }
    $header = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] tag=$Tag count=$Count active=$Active"
    Add-Content -LiteralPath (Join-Path $caseDir 'jobscheduler-timeline.txt') -Value $header -Encoding UTF8
    Add-Content -LiteralPath (Join-Path $caseDir 'jobscheduler-timeline.txt') -Value $block -Encoding UTF8
    Add-Content -LiteralPath (Join-Path $caseDir 'jobscheduler-timeline.txt') -Value '' -Encoding UTF8
}
function Wait-Converged {
    param(
        [int]$ExpectedTotal,
        [int]$TimeoutSeconds,
        [int]$SnapshotEverySeconds = 0,
        [string]$SnapshotTag = 'auto'
    )
    $waitStart = Get-Date
    $deadline = $waitStart.AddSeconds($TimeoutSeconds)
    $nextSnapshot = $waitStart
    $stable = 0
    while ((Get-Date) -lt $deadline) {
        $s = Get-IpcStatus
        if ($s) {
            $c = [int]$s.result.photo_count
            $active = $s.result.transfer_active
            Add-Content -LiteralPath $countsPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') converge count=$c active=$active expected=$ExpectedTotal" -Encoding UTF8
            if ($SnapshotEverySeconds -gt 0 -and (Get-Date) -ge $nextSnapshot) {
                $elapsed = [int]((Get-Date) - $waitStart).TotalSeconds
                Snapshot-Jobscheduler -Tag "$SnapshotTag +${elapsed}s" -Count $c -Active $active
                $nextSnapshot = (Get-Date).AddSeconds($SnapshotEverySeconds)
            }
            if ($c -eq $ExpectedTotal -and -not $active) { $stable++ } else { $stable = 0 }
            if ($stable -ge 2) {
                Event "CONVERGED count=$c elapsed=$([int]((Get-Date) - $waitStart).TotalSeconds)s"
                return $true
            }
        }
        Start-Sleep -Seconds 1
    }
    Event "NOT CONVERGED expected=$ExpectedTotal after=$([int]((Get-Date) - $waitStart).TotalSeconds)s"
    return $false
}
function Get-BatchHashes([string]$Dir) {
    return @(Get-ChildItem -LiteralPath $Dir -Filter '*.jpg' -File | Sort-Object Name | ForEach-Object {
        (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    })
}
function Verify-Batch {
    param([string]$DataDir, [string[]]$ExpectedHashes, [int]$ExpectedTotal)
    $actual = @(Get-OriginalsHashes -DataDir $DataDir)
    $counts = @{}
    foreach ($h in $actual) { if ($counts.ContainsKey($h)) { $counts[$h]++ } else { $counts[$h] = 1 } }
    $missing = @($ExpectedHashes | Where-Object { -not $counts.ContainsKey($_) })
    $present = @($ExpectedHashes | Where-Object { $counts.ContainsKey($_) })
    $dups = @($ExpectedHashes | Where-Object { $counts.ContainsKey($_) -and $counts[$_] -gt 1 })
    $text = @(
        "new_expected=$($ExpectedHashes.Count)",
        "new_present=$($present.Count)",
        "new_missing=$($missing.Count)",
        "new_duplicate=$($dups.Count)",
        "total_originals=$($actual.Count)",
        "expected_total=$ExpectedTotal",
        "total_matches=$($actual.Count -eq $ExpectedTotal)"
    )
    $text | Set-Content -LiteralPath (Join-Path $caseDir 'reconcile.txt') -Encoding UTF8
    $text | ForEach-Object { Log $_ }
    return ($missing.Count -eq 0 -and $dups.Count -eq 0 -and $actual.Count -eq $ExpectedTotal)
}
function Capture-Wifi([string]$Tag) {
    $s = Invoke-Adb -AdbArgs @('shell', 'cmd', 'wifi', 'status')
    $on = Invoke-Adb -AdbArgs @('shell', 'settings', 'get', 'global', 'wifi_on')
    $path = Join-Path $caseDir ("wifi-$Tag.txt")
    ("wifi_on=" + $on.Output + "`n" + $s.Output) | Set-Content -LiteralPath $path -Encoding UTF8
    Event "wifi $Tag on=$($on.Output)"
}
function Get-Uid {
    $r = Invoke-Adb -AdbArgs @('shell', 'pm', 'list', 'packages', '-U', $pkg)
    $m = [regex]::Match($r.Output, 'uid:(\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}
function Capture-Logcat {
    $uid = Get-Uid
    if (-not $uid) { Event 'logcat skipped: uid not found'; return }
    $out = Invoke-Adb -AdbArgs @('logcat', '-d', '-v', 'threadtime', "--uid=$uid")
    [IO.File]::WriteAllText((Join-Path $caseDir 'logcat.txt'), $out.Output, (New-Object Text.UTF8Encoding($false)))
    $start = $script:caseStart.ToString('MM-dd HH:mm:ss')
    $end = (Get-Date).ToString('MM-dd HH:mm:ss')
    $window = @()
    $key = @()
    foreach ($line in ($out.Output -split "`r?`n")) {
        if ($line -match '^\d{2}-\d{2} \d{2}:\d{2}:\d{2}') {
            $stamp = $line.Substring(0, 18)
            if ($stamp -ge $start -and $stamp -le $end) {
                $window += $line
                if ($line -match 'PPassFlow|PPassBackup|PPassUpdate|JobScheduler|FATAL|am_crash|Wifi|wifi') { $key += $line }
            }
        }
    }
    $window | Set-Content -LiteralPath (Join-Path $caseDir 'logcat-window.txt') -Encoding UTF8
    $key | Set-Content -LiteralPath (Join-Path $caseDir 'logcat-key.txt') -Encoding UTF8
    Event "logcat uid=$uid window=$($window.Count) key=$($key.Count)"
}
function Capture-Jobscheduler {
    $out = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'jobscheduler')
    $lines = $out.Output -split "`r?`n"
    $keep = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match [regex]::Escape($pkg)) {
            $from = [Math]::Max(0, $i - 4); $to = [Math]::Min($lines.Count - 1, $i + 12)
            $keep += $lines[$from..$to]
        }
    }
    $keep | Set-Content -LiteralPath (Join-Path $caseDir 'jobscheduler.txt') -Encoding UTF8
    Event "jobscheduler package_lines=$($keep.Count)"
}

Log "=== #1063 $Case started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Event "case start $Case"
$pre = Get-IpcStatus
if (-not $pre -or -not $pre.result.paired_devices -or $pre.result.paired_devices -lt 1) {
    Finish 'UNCOVERED' 'no paired device at case start'
}
Log "PairedDevices=$($pre.result.paired_devices) photo_count=$($pre.result.photo_count)"
$dataDir = Get-DataDir
Log "DataDir=$dataDir"
Capture-Wifi 'before'

# A secure keyguard prevents bringing the App to the foreground; without that
# the transfer cannot be started, so do not queue 30 large images pointlessly.
$win = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'window')
$preUi = ''
try { $preUi = Get-PhoneUi -EvidenceName 'phone-preflight.xml' } catch { }
if ($win.Output -match 'mDreamingLockscreen=true' -or $preUi -match '画出解锁图案|紧急呼叫|PIN|password') {
    Finish 'UNCOVERED' 'phone is on the secure keyguard; unlock it and rerun (no pattern bypass attempted)'
}

$attempt = 0
$inflight = $false
$before = 0
$total = 0
$batchDir = ''
$batchPrefix = ''
$expectedHashes = @()
while ($attempt -lt 3 -and -not $inflight) {
    $attempt++
    $before = Get-PhotoCount
    if ($before -lt 0) { Finish 'UNCOVERED' 'ipc status unavailable before batch' }
    $batchPrefix = ("{0}{1}" -f ($Case -replace '\.', ''), [char](64 + $attempt))
    $batchDir = Join-Path (Join-Path $WorkRoot 'img') $batchPrefix
    New-Item -ItemType Directory -Force $batchDir | Out-Null
    if (Test-Path -LiteralPath $batchDir) { Remove-Item -LiteralPath (Join-Path $batchDir '*') -Force -ErrorAction SilentlyContinue }
    Event "attempt=$attempt batch=$batchPrefix before=$before"
    Log "[BATCH] generating $Count images in $batchDir"
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & python $genScript $batchDir $batchPrefix $Count 1 (1063 + $attempt * 100) 2>&1 | ForEach-Object { Log $_ }
        $genCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($genCode -ne 0) { Finish 'UNCOVERED' "large image generation failed" }
    $expectedHashes = @(Get-BatchHashes -Dir $batchDir)
    $expectedHashes | Set-Content -LiteralPath (Join-Path $caseDir ("expected-$batchPrefix.sha256")) -Encoding UTF8
    Event "generated $($expectedHashes.Count) hashes"
    Push-Batch -Dir $batchDir -Prefix $batchPrefix
    $total = $before + $Count

    # MediaStore can auto-trigger while we are still here.
    $afterPush = Get-PhotoCount
    if ($afterPush -gt $before -and $afterPush -lt $total) {
        Event "IN-FLIGHT before explicit trigger count=$afterPush"
        $inflight = $true
        break
    }
    $trigger = Trigger-Backup
    Event "trigger=$trigger"
    $inflight = Wait-InFlight -Baseline $before -Total $total -TimeoutSeconds $InFlightTimeoutSeconds
    if (-not $inflight) {
        Event "attempt $attempt did not land in flight; waiting for any in-progress work to settle"
        Wait-Converged -ExpectedTotal $total -TimeoutSeconds 120 | Out-Null
    }
}
if (-not $inflight) { Finish 'UNCOVERED' 'could not confirm an in-flight transfer after 3 attempts' }

$preBreak = Get-PhotoCount
Event "PRE-BREAK count=$preBreak total=$total"

if ($Case -eq 'R2.2') {
    $sBreak = Get-IpcStatus
    Snapshot-Jobscheduler -Tag 'R2.2 pre-break' -Count ([int]$sBreak.result.photo_count) -Active ([bool]$sBreak.result.transfer_active)
    Capture-Wifi 'before-disable'
    Event 'R2.2 disabling Wi-Fi for 30s'
    $off = Invoke-Adb -AdbArgs @('shell', 'svc', 'wifi', 'disable')
    Event "svc wifi disable exit=$($off.Code) $($off.Output)"
    Start-Sleep -Seconds 2
    Capture-Wifi 'disabled'
    $devWhileOff = Invoke-Adb -AdbArgs @('devices', '-l')
    $devText = $devWhileOff.Output -replace "`r?`n", ' | '
    Event "adb while Wi-Fi off: $devText"
    Start-Sleep -Seconds 30
    $during = Get-PhotoCount
    $sOff = Get-IpcStatus
    Snapshot-Jobscheduler -Tag 'R2.2 offline-30s' -Count $during -Active ([bool]$sOff.result.transfer_active)
    Event "R2.2 after 30s offline count=$during"
    $on = Invoke-Adb -AdbArgs @('shell', 'svc', 'wifi', 'enable')
    Event "svc wifi enable exit=$($on.Code) $($on.Output)"
    $deadline = (Get-Date).AddSeconds(45)
    $connected = $false
    while ((Get-Date) -lt $deadline) {
        $st = Invoke-Adb -AdbArgs @('shell', 'cmd', 'wifi', 'status')
        if ($st.Output -match 'Wifi is connected') { $connected = $true; break }
        Start-Sleep -Seconds 1
    }
    Capture-Wifi 'after-enable'
    Event "wifi reconnected=$connected"
    $sOn = Get-IpcStatus
    Snapshot-Jobscheduler -Tag 'R2.2 re-enable t=0' -Count ([int]$sOn.result.photo_count) -Active ([bool]$sOn.result.transfer_active)
    $autoStart = Get-Date
    $converged = Wait-Converged -ExpectedTotal $total -TimeoutSeconds $RecoveryTimeoutSeconds -SnapshotEverySeconds 60 -SnapshotTag 'R2.2 auto'
    $autoSeconds = [int]((Get-Date) - $autoStart).TotalSeconds
    $manual = $false
    $manualSeconds = -1
    if (-not $converged) {
        Event "R2.2 auto wait expired after ${autoSeconds}s; opening the app as the SOP fallback"
        Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '3') | Out-Null
        Start-Sleep -Milliseconds 800
        Invoke-Adb -AdbArgs @('shell', 'monkey', '-p', $pkg, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
        $manualStart = Get-Date
        $manual = Wait-Converged -ExpectedTotal $total -TimeoutSeconds $ManualTimeoutSeconds -SnapshotEverySeconds 60 -SnapshotTag 'R2.2 manual'
        $manualSeconds = [int]((Get-Date) - $manualStart).TotalSeconds
    }
    $hashesOk = Verify-Batch -DataDir $dataDir -ExpectedHashes $expectedHashes -ExpectedTotal $total
    Capture-Logcat
    if ($converged -and $hashesOk -and $connected) {
        Finish 'PASS' "R2.2 auto-resumed in ${autoSeconds}s; count=$total; sha256 ok"
    } elseif ($manual -and $hashesOk) {
        Finish 'PARTIAL' "R2.2 required manual app open after ${autoSeconds}s; zero duplicates"
    } else {
        Finish 'PARTIAL' "R2.2 auto=${converged} manual=${manual} hashes=${hashesOk} wifi=${connected}"
    }
} else {
    Event 'R2.3 crashing the Android app; UI must stay untouched until auto-resume is decided'
    $crash = Invoke-Adb -AdbArgs @('shell', 'am', 'crash', $pkg)
    Event "am crash exit=$($crash.Code) $($crash.Output)"
    Start-Sleep -Seconds 2
    $proc = Invoke-Adb -AdbArgs @('shell', 'pidof', $pkg)
    Event "pid after crash='$($proc.Output)'"
    Capture-Jobscheduler
    $sCrash = Get-IpcStatus
    Snapshot-Jobscheduler -Tag 'R2.3 pre-crash' -Count ([int]$sCrash.result.photo_count) -Active ([bool]$sCrash.result.transfer_active)
    Capture-Wifi 'after-crash'
    $auto = Wait-Converged -ExpectedTotal $total -TimeoutSeconds $RecoveryTimeoutSeconds -SnapshotEverySeconds 60 -SnapshotTag 'R2.3 auto'
    Capture-Logcat
    if ($auto) {
        $hashesOk = Verify-Batch -DataDir $dataDir -ExpectedHashes $expectedHashes -ExpectedTotal $total
        if ($hashesOk) { Finish 'PASS' "R2.3 background resumed without opening the app; count=$total; sha256 ok" }
        Finish 'PARTIAL' "R2.3 background resumed but sha256 check failed"
    }
    Event 'R2.3 no automatic convergence; recording jobscheduler and opening the app as the documented fallback'
    if (-not (Test-Path -LiteralPath (Join-Path $caseDir 'jobscheduler.txt'))) { Capture-Jobscheduler }
    $ui = Get-PhoneUi -EvidenceName 'phone-before-manual-open.xml'
    if ($ui -match 'keeps stopping|已停止运行|关闭应用|Close app') {
        Tap-PhoneText -Text '关闭应用' -TimeoutSeconds 5 | Out-Null
        Tap-PhoneText -Text 'Close app' -TimeoutSeconds 3 | Out-Null
    }
    Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '3') | Out-Null
    Start-Sleep -Milliseconds 800
    Invoke-Adb -AdbArgs @('shell', 'monkey', '-p', $pkg, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
    Event 'R2.3 opened app manually; waiting for fill'
    $manual = Wait-Converged -ExpectedTotal $total -TimeoutSeconds $ManualTimeoutSeconds -SnapshotEverySeconds 60 -SnapshotTag 'R2.3 manual'
    $hashesOk = Verify-Batch -DataDir $dataDir -ExpectedHashes $expectedHashes -ExpectedTotal $total
    Capture-Logcat
    if ($manual -and $hashesOk) {
        Finish 'PARTIAL' "R2.3 did not auto-resume (#827 candidate); manual app open filled with zero duplicates"
    }
    Finish 'PARTIAL' "R2.3 did not converge after auto+manual; sha256=$hashesOk"
}
