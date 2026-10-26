#Requires -Version 5.1
# 1063-baseline.ps1 - Select only DCIM/PPassRegression on the phone, start the
# first backup, and wait until the desktop originals match the 40 generated
# images by sha256. Evidence: %USERPROFILE%\ppcheck\1063-test10\R0.5\.
#
# The images themselves are produced/pushed by the existing
# tools/windows/manual-regression.sh push command (programmatic PIL drawings,
# never screenshots). This script owns the UI selection + wait/reconcile.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\1063-baseline.ps1
param(
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [string]$Album = 'PPassRegression',
    [int]$ExpectedCount = 40,
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot 'R0.5'
New-Item -ItemType Directory -Force $caseDir | Out-Null
$log = Join-Path $caseDir 'baseline.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
$adb = (Get-Command adb -ErrorAction Stop).Source
$bash = 'C:\Program Files\Git\bin\bash.exe'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$workBash = 'C:/' + ($WorkRoot -replace '^[A-Za-z]:\\?', '' -replace '\\', '/')

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
        $out = & $adb @AdbArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    return [pscustomobject]@{ Code = $code; Output = (($out | Out-String).Trim()) }
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
    Log "tapped phone: $Text ($($c.X),$($c.Y))"
    Start-Sleep -Milliseconds 600
    return $true
}
function Run-Reconcile {
    $cmd = "cd '$($repo -replace '\\','/')' && WORK=$workBash bash tools/windows/manual-regression.sh reconcile"
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $bash -lc $cmd 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    return [pscustomobject]@{ Code = $code; Output = (($out | Out-String).Trim()) }
}

Log "=== #1063 baseline $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
$dev = Invoke-Adb -AdbArgs @('devices', '-l')
Log $dev.Output
if (@($dev.Output -split "`r?`n" | Where-Object { $_ -match '^\S+\s+device\b' }).Count -ne 1) {
    Finish $false "expected one authorized Android device"
}

$raw = Get-PhoneUi -EvidenceName 'phone-before-select.xml'
if ($raw -notmatch '选择要备份的相册') {
    Finish $false "phone is not on the album picker"
}

# The grid is a 2-column LazyGrid; scroll until the test album is composed.
$found = $false
for ($i = 0; $i -lt 10; $i++) {
    $raw = Get-PhoneUi -EvidenceName ("phone-select-{0}.xml" -f $i)
    if (Find-TextNode -Raw $raw -Text $Album) { $found = $true; break }
    Invoke-Adb -AdbArgs @('shell', 'input', 'swipe', '540', '1700', '540', '900', '300') | Out-Null
    Start-Sleep -Milliseconds 600
}
if (-not $found) { Finish $false "album $Album not found in picker" }

if (-not (Tap-Text -Text $Album)) { Finish $false "could not tap album $Album" }
Start-Sleep -Milliseconds 800
$after = Get-PhoneUi -EvidenceName 'phone-after-select.xml'
$m = [regex]::Match($after, "将备份\s*([0-9,]+)\s*张")
if (-not $m.Success) { Finish $false "could not read the selected-count summary" }
$selected = [int]($m.Groups[1].Value -replace ',', '')
Log "SelectedCount=$selected"
if ($selected -ne $ExpectedCount) {
    Finish $false "selected $selected photos, expected $ExpectedCount (only $Album must be checked)"
}

if (-not (Tap-Text -Text '开始备份')) {
    Get-PhoneUi -EvidenceName 'phone-no-start.xml' | Out-Null
    Finish $false "could not click Start backup"
}
Start-Sleep -Seconds 2
Get-PhoneUi -EvidenceName 'phone-backup-started.xml' | Out-Null

# The completion screen has a "don't enable background backup" button; tapping
# it only returns to Home. The first backup was already started by Start.
Tap-Text -Text '不开启后台备份' | Out-Null

Log ''
Log 'Waiting for 40/40 sha256 reconciliation...'
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$last = $null
$ok = $false
while ((Get-Date) -lt $deadline) {
    $r = Run-Reconcile
    if ($r.Output -match 'expected=(\d+)\s+library=(\d+)\s+uniq=(\d+)\s+missing=(\d+)\s+extra=(\d+)') {
        $expected = [int]$Matches[1]; $library = [int]$Matches[2]; $uniq = [int]$Matches[3]; $missing = [int]$Matches[4]; $extra = [int]$Matches[5]
        $last = $r.Output
        Log "reconcile: expected=$expected library=$library uniq=$uniq missing=$missing extra=$extra"
        if ($expected -eq $ExpectedCount -and $library -eq $ExpectedCount -and $uniq -eq $ExpectedCount -and $missing -eq 0 -and $extra -eq 0) {
            $ok = $true
            break
        }
    } else {
        Log "reconcile output: $($r.Output)"
    }
    Start-Sleep -Seconds 3
}

$final = Run-Reconcile
[IO.File]::WriteAllText((Join-Path $caseDir 'reconcile.txt'), ($final.Output + "`n"), (New-Object Text.UTF8Encoding($false)))
$hashSource = Join-Path $WorkRoot 'img\R0.5.sha256'
if (Test-Path -LiteralPath $hashSource) {
    Copy-Item -LiteralPath $hashSource -Destination (Join-Path $caseDir 'expected.sha256') -Force
}
Get-PhoneUi -EvidenceName 'phone-after-backup.xml' | Out-Null
Log "FinalReconcile=$($final.Output)"

if (-not $ok) { Finish $false "sha256 reconciliation did not reach 40/40 within ${TimeoutSeconds}s" }
Finish $true "40/40 photos reconciled by sha256"
