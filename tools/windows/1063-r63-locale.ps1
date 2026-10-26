#Requires -Version 5.1
# 1063-r63-locale.ps1 - R6.3 per-app English locale.
# Sets ONLY com.hawkeyexb.ppass to en-US, captures Overview/Photos/Settings with
# UIA bounds, checks for Chinese leftovers, raw i18n keys, and truncated text,
# then clears the per-app locale and verifies the App is Chinese again.
param(
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10')
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot 'R6.3'
New-Item -ItemType Directory -Force $caseDir | Out-Null
$resultPath = Join-Path $caseDir 'result.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
$adb = (Get-Command adb -ErrorAction Stop).Source
$uia = Join-Path $PSScriptRoot 'uia-drive.ps1'
$pkg = 'com.hawkeyexb.ppass'
Add-Type -AssemblyName System.Windows.Forms

function Log([string]$m) { [Console]::WriteLine($m); $script:lines.Add($m) }
function Finish([string]$result, [string]$detail) {
    $text = @("case=R6.3", "result=$result", "detail=$detail") + $script:lines
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
function Dump-Full([string]$Name) {
    $out = Join-Path $caseDir $Name
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uia -Action dumpfull -Out $out 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { return $null }
    return $out
}
function Click-Ui([string]$Name) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uia -Action click -Name $Name -Out (Join-Path $caseDir 'click.txt') 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    return $code
}
function Analyze-Page([string]$Path, [string]$Label, [int]$ScreenW, [int]$ScreenH) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        Log "$Label : MISSING dump"
        return [pscustomobject]@{ Label=$Label; Chinese=0; Keys=0; Trunc=0; ChineseSamples=@(); KeySamples=@(); TruncSamples=@() }
    }
    $chinese = @(); $keys = @(); $trunc = @()
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $parts = $line -split "`t"
        if ($parts.Count -lt 3) { continue }
        $name = $parts[1]
        if (-not $name) { continue }
        if ($name -match '[\u4e00-\u9fff]') { $chinese += "$($parts[0]) | $name" }
        if ($name -match '(?i)\b(ui|error|wizard|diag|update|pair|backup|devices|photos|nav|settings)\.[a-z0-9_]+\b' -or
            $name -match '\b[A-Z][A-Z0-9]*(_[A-Z0-9]+){1,}\b') { $keys += $name }
        $m = [regex]::Match($parts[2], '^\s*(-?\d+),(-?\d+),(-?\d+),(-?\d+)\s*$')
        if ($m.Success) {
            $l = [int]$m.Groups[1].Value; $t = [int]$m.Groups[2].Value
            $r = [int]$m.Groups[3].Value; $b = [int]$m.Groups[4].Value
            if ($r -gt $ScreenW + 2 -or $b -gt $ScreenH + 2 -or $l -lt -2 -or $t -lt -2) {
                $trunc += "$name [$l,$t,$r,$b]"
            }
        }
        if ($name.EndsWith('…') -or $name.EndsWith('...')) { $trunc += "$name (ellipsis)" }
    }
    Log "$Label : lines=$((Get-Content -LiteralPath $Path).Count) chinese=$($chinese.Count) keys=$($keys.Count) trunc=$($trunc.Count)"
    if ($chinese.Count) { $chinese | Select-Object -First 5 | ForEach-Object { Log "  CN: $_" } }
    if ($keys.Count) { $keys | Select-Object -First 5 | ForEach-Object { Log "  KEY: $_" } }
    if ($trunc.Count) { $trunc | Select-Object -First 5 | ForEach-Object { Log "  TRUNC: $_" } }
    return [pscustomobject]@{ Label=$Label; Chinese=$chinese.Count; Keys=$keys.Count; Trunc=$trunc.Count; ChineseSamples=$chinese; KeySamples=$keys; TruncSamples=$trunc }
}

Log "=== #1063 R6.3 per-app locale $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
if (-not (Get-Process -Name 'p-pass-desktop' -ErrorAction SilentlyContinue)) {
    Invoke-Adb -AdbArgs @('shell', 'monkey', '-p', $pkg, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
    Start-Sleep -Seconds 3
}
$set = Invoke-Adb -AdbArgs @('shell', 'cmd', 'locale', 'set-app-locales', $pkg, '--locales', 'en-US')
Log "set-app-locales en-US exit=$($set.Code) $($set.Output)"
$get = Invoke-Adb -AdbArgs @('shell', 'cmd', 'locale', 'get-app-locales', $pkg)
Log "get-app-locales: $($get.Output)"
Invoke-Adb -AdbArgs @('shell', 'am', 'force-stop', $pkg) | Out-Null
Invoke-Adb -AdbArgs @('shell', 'monkey', '-p', $pkg, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
Start-Sleep -Seconds 4

$screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
$pages = @()
$home = Dump-Full 'home-en.tsv'
$pages += Analyze-Page -Path $home -Label 'Overview(首页/备份状态)' -ScreenW $screen.Width -ScreenH $screen.Height

# The Overview is the home/backup-status page; Photos is the backup/photo page.
if ((Click-Ui -Name 'Photos') -eq 0) { Start-Sleep -Seconds 1 }
$photos = Dump-Full 'photos-en.tsv'
$pages += Analyze-Page -Path $photos -Label 'Photos(备份/照片页)' -ScreenW $screen.Width -ScreenH $screen.Height

if ((Click-Ui -Name 'Settings') -eq 0) { Start-Sleep -Seconds 1 }
$settings = Dump-Full 'settings-en.tsv'
$pages += Analyze-Page -Path $settings -Label 'Settings(设置页)' -ScreenW $screen.Width -ScreenH $screen.Height

# Restore the per-app locale to the system default (empty list).
$clear = Invoke-Adb -AdbArgs @('shell', 'cmd', 'locale', 'set-app-locales', $pkg, '--locales', '')
Log "set-app-locales empty exit=$($clear.Code) $($clear.Output)"
$getAfter = Invoke-Adb -AdbArgs @('shell', 'cmd', 'locale', 'get-app-locales', $pkg)
Log "get-app-locales after restore: $($getAfter.Output)"
Invoke-Adb -AdbArgs @('shell', 'am', 'force-stop', $pkg) | Out-Null
Invoke-Adb -AdbArgs @('shell', 'monkey', '-p', $pkg, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
Start-Sleep -Seconds 4
$zh = Dump-Full 'home-zh-restored.tsv'
$zhText = if ($zh) { Get-Content -LiteralPath $zh -Raw -Encoding UTF8 } else { '' }
$zhChinese = ([regex]::Matches($zhText, '[\u4e00-\u9fff]')).Count
Log "restored Chinese chars=$zhChinese"

$totalChinese = ($pages | Measure-Object -Property Chinese -Sum).Sum
$totalKeys = ($pages | Measure-Object -Property Keys -Sum).Sum
$totalTrunc = ($pages | Measure-Object -Property Trunc -Sum).Sum
$pageSummary = ($pages | ForEach-Object { "$($_.Label):cn=$($_.Chinese),keys=$($_.Keys),trunc=$($_.Trunc)" }) -join '; '
Log "summary: $pageSummary"
if ($zhChinese -eq 0) { Log 'WARN: restored UI has no Chinese characters' }

if ($totalChinese -eq 0 -and $totalKeys -eq 0 -and $totalTrunc -eq 0 -and $zhChinese -gt 0) {
    Finish 'PASS' "English pages clean; Chinese restored"
} elseif ($totalChinese -gt 0 -or $zhChinese -eq 0) {
    Finish 'PARTIAL' "English pages have Chinese leftovers or restore failed; $pageSummary; restoredChars=$zhChinese"
} else {
    Finish 'PARTIAL' "suspected key/truncation; $pageSummary; restoredChars=$zhChinese"
}
