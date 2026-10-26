#Requires -Version 5.1
# 1063-w4-transfer.ps1 - Drive the phone side of the W4 sample.
#
# It waits for 1063-admin-w4.ps1 to log "[W4] start=", then:
#   1. pushes 30 x ~19MB noise JPEGs (1063-gen-large-images.py output) to
#      /sdcard/DCIM/PPassRegression and waits for MediaStore to index them;
#   2. opens P-Pass and taps the backup action ("立即备份"; falls back to the
#      Settings tab, and accepts an already-active "暂停" state);
#   3. records TRANSFER-START / TRANSFER-END in W4\timeline.txt while polling
#      the daemon IPC status, then waits for the sampler's ELEVATED DONE.
#
# Evidence: %USERPROFILE%\ppcheck\1063-test10\W4\
#   timeline.txt, counts.txt, push.txt, phone-*.xml, transfer.log, transfer-result.txt
param(
    [string]$ImageDir = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10\img\w4'),
    [int]$Count = 30,
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [int]$TransferTimeoutSeconds = 900,
    [int]$SampleTimeoutSeconds = 1500
)

$ErrorActionPreference = 'Stop'
$w4Dir = Join-Path $WorkRoot 'W4'
New-Item -ItemType Directory -Force $w4Dir | Out-Null
$timelinePath = Join-Path $w4Dir 'timeline.txt'
$countsPath = Join-Path $w4Dir 'counts.txt'
$logPath = Join-Path $w4Dir 'transfer.log'
$resultPath = Join-Path $w4Dir 'transfer-result.txt'
$runLog = Join-Path $WorkRoot 'admin-once\run2.log'
$adb = (Get-Command adb -ErrorAction Stop).Source
$bash = 'C:\Program Files\Git\bin\bash.exe'
$ipcScript = Join-Path $PSScriptRoot '1063-ipc-status.sh'
$pkg = 'com.hawkeyexb.ppass'
$albumPath = '/sdcard/DCIM/PPassRegression'
$prefix = 'W4B'

$script:lines = New-Object System.Collections.Generic.List[string]
function Log([string]$msg) {
    [Console]::WriteLine($msg)
    $script:lines.Add($msg)
    Add-Content -LiteralPath $logPath -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
}
function Event([string]$msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $msg"
    Add-Content -LiteralPath $timelinePath -Value $line -Encoding UTF8
    Log $line
}
function Finish([string]$result, [string]$detail) {
    $text = @("result=$result", "detail=$detail") + $script:lines
    [IO.File]::WriteAllLines($resultPath, $text, (New-Object Text.UTF8Encoding($false)))
    Log "RESULT=$result $detail"
    if ($result -eq 'PASS') { exit 0 }
    if ($result -eq 'PARTIAL') { exit 2 }
    exit 1
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
        $out = & $bash $ipcScript 2>&1
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
function Get-PhoneUi {
    param([string]$EvidenceName = '')
    $dump = Invoke-Adb -AdbArgs @('shell', 'uiautomator', 'dump', '/sdcard/1063-w4-ui.xml')
    $cat = Invoke-Adb -AdbArgs @('exec-out', 'cat', '/sdcard/1063-w4-ui.xml')
    $raw = [string]$cat.Output
    if ($raw -notmatch '<hierarchy') { throw "uiautomator dump failed: $($dump.Output)" }
    if ($EvidenceName -ne '') {
        [IO.File]::WriteAllText((Join-Path $w4Dir $EvidenceName), $raw, (New-Object Text.UTF8Encoding($false)))
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
    param([string]$Text, [int]$TimeoutSeconds = 15)
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
                    Start-Sleep -Milliseconds 700
                    return $true
                }
            }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Get-MediaCount {
    $r = Invoke-Adb -AdbArgs @('shell', 'content', 'query', '--uri', 'content://media/external/images/media', '--projection', '_data')
    return @($r.Output -split "`r?`n" | Where-Object { $_ -match ("/" + [regex]::Escape($prefix) + "_\d+\.jpg") }).Count
}
function Push-Batch {
    $push = Invoke-Adb -AdbArgs @('push', ($ImageDir + '\.'), "$albumPath/")
    Add-Content -LiteralPath (Join-Path $w4Dir 'push.txt') -Value "PUSH $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))`n$($push.Output)" -Encoding UTF8
    Event "pushed $Count files to $albumPath"
    Invoke-Adb -AdbArgs @('shell', 'content', 'call', '--uri', 'content://media', '--method', 'scan_volume', '--arg', 'external_primary') | Out-Null
    Start-Sleep -Seconds 2
    $deadline = (Get-Date).AddSeconds(120)
    $scanFiles = $false
    while ((Get-Date) -lt $deadline) {
        $n = Get-MediaCount
        if ($n -ge $Count) { break }
        if (-not $scanFiles) {
            foreach ($f in (Get-ChildItem -LiteralPath $ImageDir -Filter '*.jpg' -File)) {
                Invoke-Adb -AdbArgs @('shell', 'content', 'call', '--uri', 'content://media/external/images/media', '--method', 'scan_file', '--arg', "$albumPath/$($f.Name)") | Out-Null
            }
            $scanFiles = $true
        }
        Start-Sleep -Seconds 2
    }
    $n = Get-MediaCount
    Add-Content -LiteralPath (Join-Path $w4Dir 'push.txt') -Value "MEDIASTORE $prefix=$n expected=$Count" -Encoding UTF8
    Event "MediaStore $prefix=$n"
    if ($n -lt $Count) { throw "MediaStore only has $n/$Count for $prefix" }
}

# --- 0. Wait for the sampler to start ---------------------------------------
Log 'waiting for [W4] start= in run2.log'
$deadline = (Get-Date).AddSeconds($SampleTimeoutSeconds)
$sampleStart = $null
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $runLog) {
        $txt = Get-Content -LiteralPath $runLog -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($txt -match '\[W4\] start=([0-9-]+ [0-9:]+)') { $sampleStart = $Matches[1]; break }
    }
    Start-Sleep -Seconds 1
}
if (-not $sampleStart) { Finish 'FAIL' 'sampler never logged [W4] start=' }
Event "SAMPLE-START $sampleStart"

$images = @(Get-ChildItem -LiteralPath $ImageDir -Filter '*.jpg' -File -ErrorAction Stop | Sort-Object Name)
if ($images.Count -lt $Count) { Finish 'FAIL' "only $($images.Count) images in $ImageDir" }
$baselineStatus = Get-IpcStatus
if (-not $baselineStatus) { Finish 'FAIL' 'IPC is down before the transfer' }
$baseline = [int]$baselineStatus.result.photo_count
$total = $baseline + $Count
Event "BASELINE count=$baseline target=$total"

Push-Batch

# --- 1. Open the app and start the backup -----------------------------------
Event 'opening P-Pass'
Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '3') | Out-Null
Start-Sleep -Milliseconds 800
Invoke-Adb -AdbArgs @('shell', 'monkey', '-p', $pkg, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
Start-Sleep -Seconds 2
$raw = Get-PhoneUi -EvidenceName 'phone-photos.xml'
$trigger = 'none'
if (Find-PhoneNode -Raw $raw -Text '立即备份') {
    if (Tap-PhoneText -Text '立即备份' -TimeoutSeconds 5) { $trigger = 'photos-立即备份' }
} elseif (Find-PhoneNode -Raw $raw -Text '暂停') {
    $trigger = 'already-active-照片页暂停'
}
if ($trigger -eq 'none') {
    Event 'no backup action on the photos page; opening Settings'
    if (Tap-PhoneText -Text '设置' -TimeoutSeconds 10) {
        Start-Sleep -Seconds 1
        $raw2 = Get-PhoneUi -EvidenceName 'phone-settings.xml'
        if (Find-PhoneNode -Raw $raw2 -Text '立即备份') {
            if (Tap-PhoneText -Text '立即备份' -TimeoutSeconds 5) { $trigger = 'settings-立即备份' }
        } elseif (Find-PhoneNode -Raw $raw2 -Text '暂停') {
            $trigger = 'already-active-设置页暂停'
        }
    }
}
Event "TRIGGER $trigger"
if ($trigger -eq 'none') { Finish 'FAIL' 'could not find or start the backup action' }

# --- 2. Watch the transfer ---------------------------------------------------
$transferStart = $null
$transferEnd = $null
$stable = 0
$deadline = (Get-Date).AddSeconds($TransferTimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    $s = Get-IpcStatus
    if ($s) {
        $c = [int]$s.result.photo_count
        $active = [bool]$s.result.transfer_active
        Add-Content -LiteralPath $countsPath -Value ("{0} count={1} active={2} target={3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $c, $active, $total) -Encoding UTF8
        if (-not $transferStart -and ($active -or $c -gt $baseline)) {
            $transferStart = Get-Date
            Event "TRANSFER-START count=$c baseline=$baseline total=$total active=$active"
        }
        if ($transferStart) {
            if ($c -ge $total -and -not $active) { $stable++ } else { $stable = 0 }
            if ($stable -ge 2) {
                $transferEnd = Get-Date
                Event "TRANSFER-END count=$c baseline=$baseline total=$total elapsed=$([int](($transferEnd - $transferStart).TotalSeconds))s"
                break
            }
        }
    }
    Start-Sleep -Seconds 1
}
if (-not $transferEnd) {
    $last = Get-PhotoCount
    Event "TRANSFER-TIMEOUT count=$last baseline=$baseline total=$total"
    Finish 'FAIL' "transfer did not converge to $total within $TransferTimeoutSeconds s"
}

# --- 3. Let the 15-minute sample finish; it must extend >=3 min past transfer
$sampleDone = $null
$deadline = (Get-Date).AddSeconds($SampleTimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $runLog) {
        $txt = Get-Content -LiteralPath $runLog -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($txt -match 'ELEVATED DONE') { $sampleDone = Get-Date; break }
    }
    Start-Sleep -Seconds 2
}
if (-not $sampleDone) { Finish 'FAIL' 'sampler did not reach ELEVATED DONE' }

$postSeconds = [int](($sampleDone - $transferEnd).TotalSeconds)
Event "SAMPLE-END at=$($sampleDone.ToString('yyyy-MM-dd HH:mm:ss')) post_transfer=$postSeconds s"
if ($postSeconds -lt 180) {
    Finish 'PARTIAL' "transfer converged but only $postSeconds s of sampling followed it"
}
Finish 'PASS' "30 large images transferred ($baseline -> $total); sampling continued $postSeconds s after transfer"
