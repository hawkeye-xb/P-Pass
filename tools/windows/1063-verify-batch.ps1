#Requires -Version 5.1
# 1063-verify-batch.ps1 - Post-case sha256 audit for a batch of large images.
# Checks: every new hash is present exactly once, the baseline hashes are still
# present, and the library total equals baseline + new. Writes
# <case>\post-reconcile.txt and exits 0 only on PASS.
param(
    [Parameter(Mandatory = $true)][string]$Case,
    [Parameter(Mandatory = $true)][string]$BatchPrefix,
    [Parameter(Mandatory = $true)][int]$ExpectedTotal,
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [int]$BaselineCount = 40
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot $Case
$out = Join-Path $caseDir 'post-reconcile.txt'

function Read-Hashes([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "missing hash file: $Path" }
    return @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ -match '^[0-9a-fA-F]{64}$' } | ForEach-Object { $_.ToLowerInvariant() })
}
function Get-DataDir {
    $conf = Join-Path $env:LOCALAPPDATA 'com.hawkeyexb.ppass.desktop\config.toml'
    $text = Get-Content -LiteralPath $conf -Raw -Encoding UTF8
    $m = [regex]::Match($text, '(?m)^\s*data_dir\s*=\s*["''](.+?)["'']\s*$')
    if (-not $m.Success) { throw "could not parse data_dir from $conf" }
    return (Resolve-Path -LiteralPath ($m.Groups[1].Value -replace '\\\\', '\')).Path
}

$dataDir = Get-DataDir
$originals = Join-Path $dataDir 'originals'
$actual = @(Get-ChildItem -LiteralPath $originals -File -Recurse -ErrorAction Stop | ForEach-Object {
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
})
$counts = @{}
foreach ($h in $actual) { if ($counts.ContainsKey($h)) { $counts[$h]++ } else { $counts[$h] = 1 } }

$new = Read-Hashes (Join-Path $caseDir ("expected-$BatchPrefix.sha256"))
$newMissing = @($new | Where-Object { -not $counts.ContainsKey($_) })
$newDup = @($new | Where-Object { $counts.ContainsKey($_) -and $counts[$_] -gt 1 })
$newPresent = @($new | Where-Object { $counts.ContainsKey($_) })

$baselineMissing = @()
$baselineFile = Join-Path $WorkRoot 'R0.5\expected.sha256'
if (Test-Path -LiteralPath $baselineFile) {
    # R0.5's expected.sha256 is sha256sum format: "<hash> *./NAME".
    $baseline = @(Get-Content -LiteralPath $baselineFile -Encoding UTF8 | Where-Object { $_ -match '^[0-9a-fA-F]{64}' } | ForEach-Object { ($_ -split '\s+')[0].ToLowerInvariant() })
    $baselineMissing = @($baseline | Where-Object { -not $counts.ContainsKey($_) })
}

$pass = ($newMissing.Count -eq 0 -and $newDup.Count -eq 0 -and $actual.Count -eq $ExpectedTotal -and $baselineMissing.Count -eq 0)
$lines = @(
    "timestamp=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "case=$Case",
    "batch=$BatchPrefix",
    "new_expected=$($new.Count)",
    "new_present=$($newPresent.Count)",
    "new_missing=$($newMissing.Count)",
    "new_duplicate=$($newDup.Count)",
    "baseline_expected=$BaselineCount",
    "baseline_missing=$($baselineMissing.Count)",
    "total_originals=$($actual.Count)",
    "expected_total=$ExpectedTotal",
    "total_matches=$($actual.Count -eq $ExpectedTotal)",
    "result=$(if ($pass) { 'PASS' } else { 'FAIL' })"
)
[IO.File]::WriteAllLines($out, $lines, (New-Object Text.UTF8Encoding($false)))
$lines | ForEach-Object { Write-Output $_ }
if ($pass) { exit 0 } else { exit 1 }
