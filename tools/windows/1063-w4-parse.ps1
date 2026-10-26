#Requires -Version 5.1
# 1063-w4-parse.ps1 - Parse the W4 powercfg-requests sample.
# Each frame is "=== timestamp ===" followed by DISPLAY/SYSTEM/... sections.
# Reports every frame whose SYSTEM section names ppf-daemon.exe, and separately
# counts the frames inside the transfer window (TRANSFER-START / TRANSFER-END in
# W4\timeline.txt; the older R2.3 IN-FLIGHT / case end tags still work).
#
# #804 (DAE-11, plugged-in AwakeGuard) is landed, so the criterion is "while on
# AC the SYSTEM section always names ppf-daemon.exe". The transfer window is
# reported as a sub-interval, not as the only expected interval.
param(
    [string]$W4File = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10\W4\powercfg-requests-2.txt'),
    [string]$TransferTimeline = '',
    [string]$R23Timeline = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10\W4\timeline.txt'),
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'
if ($TransferTimeline -eq '') { $TransferTimeline = $R23Timeline }
$outPath = Join-Path (Split-Path -Parent $W4File) 'w4-analysis-2.txt'
$lines = New-Object System.Collections.Generic.List[string]
function Emit([string]$s) { $lines.Add($s); Write-Output $s }

$content = Get-Content -LiteralPath $W4File -Raw -Encoding UTF8
$frames = [regex]::Matches($content, '(?ms)^=== (.+?) ===\r?\n(.*?)(?=^=== |\z)')
$rows = @()
foreach ($f in $frames) {
    $ts = $f.Groups[1].Value.Trim()
    $body = $f.Groups[2].Value
    $m = [regex]::Match($body, '(?ms)^SYSTEM:\s*\r?\n(.*?)(?=^[A-Z]+:\s*$|\z)')
    $sys = if ($m.Success) { $m.Groups[1].Value } else { '' }
    $present = $sys -match 'ppf-daemon\.exe'
    $rows += [pscustomobject]@{ Timestamp = $ts; Present = $present; System = ($sys -replace '\s+', ' ').Trim() }
}

$frameCount = $rows.Count
$presentCount = @($rows | Where-Object { $_.Present }).Count
$absent = @($rows | Where-Object { -not $_.Present })
$first = if ($frameCount -gt 0) { $rows[0].Timestamp } else { '' }
$last = if ($frameCount -gt 0) { $rows[-1].Timestamp } else { '' }

Emit "=== W4 analysis ==="
Emit "file=$W4File"
Emit "frames=$frameCount first=$first last=$last"
Emit "ppf_daemon_present=$presentCount absent=$($absent.Count)"
Emit ''
Emit 'timestamp | SYSTEM has ppf-daemon.exe'
foreach ($r in $rows) { Emit ("{0} | {1}" -f $r.Timestamp, $r.Present) }
Emit ''
Emit 'absent_frames:'
if ($absent.Count -eq 0) { Emit '  (none)' } else { foreach ($a in $absent) { Emit "  $($a.Timestamp)" } }
Emit ''

# #804 source check: daemon subscribes to AC changes and holds the guard.
$mainSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'crates\daemon\src\main.rs') -Raw -Encoding UTF8
$awakeSrc = Get-Content -LiteralPath (Join-Path $RepoRoot 'crates\daemon\src\awake.rs') -Raw -Encoding UTF8
$has804 = ($mainSrc -match 'watch_external_power' -and $mainSrc -match 'on_power' -and $awakeSrc -match '#804')
$battery = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction SilentlyContinue | Select-Object -First 1
$onAc = if ($battery) { [bool]$battery.PowerOnline } else { $null }
Emit "source_804_landed=$has804"
Emit "desktop_on_ac=$onAc"

# Transfer window. Accept both the current W4 tags and the older R2.3 tags.
$tl = Get-Content -LiteralPath $TransferTimeline -ErrorAction SilentlyContinue
$transferStart = $null; $transferEnd = $null
foreach ($line in $tl) {
    if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.\d+ (IN-FLIGHT|TRANSFER-START)') { $transferStart = $Matches[1] }
    if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.\d+ (case end|TRANSFER-END)') { $transferEnd = $Matches[1] }
}
Emit "transfer_start=$transferStart"
Emit "transfer_end=$transferEnd"
$overlap = $false
if ($first -and $last -and $transferStart -and $transferEnd) {
    $overlap = ($first -le $transferEnd -and $last -ge $transferStart)
}
Emit "sample_overlaps_transfer=$overlap"

$transferRows = @()
$postRows = @()
if ($transferStart -and $transferEnd) {
    $transferRows = @($rows | Where-Object { $_.Timestamp -ge $transferStart -and $_.Timestamp -le $transferEnd })
    $postRows = @($rows | Where-Object { $_.Timestamp -gt $transferEnd })
}
$transferFrames = $transferRows.Count
$transferPresent = @($transferRows | Where-Object { $_.Present }).Count
$postFrames = $postRows.Count
$postPresent = @($postRows | Where-Object { $_.Present }).Count
Emit "transfer_frames=$transferFrames present=$transferPresent absent=$($transferFrames - $transferPresent)"
Emit "post_transfer_frames=$postFrames present=$postPresent absent=$($postFrames - $postPresent)"
Emit ''

if ($has804) {
    Emit 'criterion=DAE-11/#804: ppf-daemon should be present continuously while the desktop is on AC'
    if ($frameCount -gt 0 -and $presentCount -eq $frameCount) {
        Emit 'result=PASS (all sampled frames show ppf-daemon.exe while on AC)'
    } elseif ($presentCount -gt 0) {
        Emit 'result=PARTIAL (ppf-daemon.exe missing in some sampled frames)'
    } else {
        Emit 'result=FAIL (no ppf-daemon.exe in SYSTEM)'
    }
    if ($transferFrames -gt 0) {
        if ($transferPresent -eq $transferFrames) {
            Emit "transfer_interval=ALL_PRESENT ($transferPresent/$transferFrames frames)"
        } else {
            Emit "transfer_interval=MISSING ppf-daemon in $($transferFrames - $transferPresent)/$transferFrames frames"
        }
        Emit "post_transfer=($postPresent/$postFrames frames present)"
    } else {
        Emit 'transfer_interval=NO_FRAMES (timeline window does not overlap the sample)'
    }
} else {
    Emit 'criterion=pre-#804: ppf-daemon should appear only during the transfer window'
    if (-not $overlap) {
        Emit 'result=UNCOVERED (W4 sample does not overlap the transfer window)'
    } elseif ($transferPresent -gt 0) {
        Emit 'result=PARTIAL (transfer interval present; post-transfer absence needs a later sample)'
    } else {
        Emit 'result=FAIL (no ppf-daemon during transfer)'
    }
}

[IO.File]::WriteAllLines($outPath, $lines, (New-Object Text.UTF8Encoding($false)))
Emit ''
Emit "written=$outPath"
