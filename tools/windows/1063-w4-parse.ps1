#Requires -Version 5.1
# 1063-w4-parse.ps1 - Parse the W4 powercfg-requests sample.
# Each frame is "=== timestamp ===" followed by DISPLAY/SYSTEM/... sections.
# Reports every frame where SYSTEM names ppf-daemon.exe, intervals, and whether
# the sample overlaps the R2.3 transfer window. Also checks whether DAE-11
# (#804, plugged-in AwakeGuard) is present in the source, because that changes
# the criterion from "only during transfer" to "always while on AC".
param(
    [string]$W4File = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10\W4\powercfg-requests.txt'),
    [string]$R23Timeline = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10\R2.3\timeline.txt'),
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'
$outPath = Join-Path (Split-Path -Parent $W4File) 'w4-analysis.txt'
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

# R2.3 transfer window (crash case): from IN-FLIGHT to case end.
$tl = Get-Content -LiteralPath $R23Timeline -ErrorAction SilentlyContinue
$r23Start = $null; $r23End = $null
foreach ($line in $tl) {
    if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.\d+ IN-FLIGHT') { $r23Start = $Matches[1] }
    if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.\d+ case end') { $r23End = $Matches[1] }
}
Emit "r23_transfer_start=$r23Start"
Emit "r23_transfer_end=$r23End"
$overlap = $false
if ($first -and $last -and $r23Start -and $r23End) {
    $overlap = ($first -le $r23End -and $last -ge $r23Start)
}
Emit "sample_overlaps_r23_transfer=$overlap"

Emit ''
if ($has804) {
    Emit 'criterion=DAE-11/#804: ppf-daemon should be present continuously while the desktop is on AC'
    if ($presentCount -eq $frameCount -and $frameCount -gt 0) {
        Emit 'result=PASS (all sampled frames show ppf-daemon.exe while on AC)'
    } elseif ($presentCount -gt 0) {
        Emit 'result=PARTIAL (ppf-daemon.exe missing in some sampled frames)'
    } else {
        Emit 'result=FAIL (no ppf-daemon.exe in SYSTEM)'
    }
    if (-not $overlap) {
        Emit 'note=sample does not overlap the R2.3 transfer window; transfer-specific interval criterion is UNCOVERED'
    }
} else {
    Emit 'criterion=pre-#804: ppf-daemon should appear only during the transfer window'
    if (-not $overlap) {
        Emit 'result=UNCOVERED (W4 sample does not overlap the R2.3 transfer window)'
    } elseif (@($rows | Where-Object { $_.Present }).Count -gt 0) {
        Emit 'result=PARTIAL (transfer interval present; post-transfer absence needs a later sample)'
    } else {
        Emit 'result=FAIL (no ppf-daemon during transfer)'
    }
}

[IO.File]::WriteAllLines($outPath, $lines, (New-Object Text.UTF8Encoding($false)))
Emit ''
Emit "written=$outPath"
