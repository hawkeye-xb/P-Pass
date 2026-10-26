#Requires -Version 5.1
# 1063-r63-locale.ps1 - R6.3 per-app English locale on the PHONE.
# Sets only com.hawkeyexb.ppass to en-US, dumps the phone's Overview, Photos
# and Settings pages with uiautomator, checks Chinese leftovers / raw i18n keys
# / clipped text, then clears the per-app locale and verifies Chinese again.
# Never sends a sleep/power key; the caller must have USB stay-on.
param(
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10')
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot 'R6.3'
New-Item -ItemType Directory -Force $caseDir | Out-Null
$resultPath = Join-Path $caseDir 'result.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
$adb = (Get-Command adb -ErrorAction Stop).Source
$pkg = 'com.hawkeyexb.ppass'
$screenW = 1080
$screenH = 2400

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
function Get-PhoneUi {
    param([string]$Name = '')
    $dump = Invoke-Adb -AdbArgs @('shell', 'uiautomator', 'dump', '/sdcard/1063-r63.xml')
    $cat = Invoke-Adb -AdbArgs @('exec-out', 'cat', '/sdcard/1063-r63.xml')
    $raw = [string]$cat.Output
    if ($raw -notmatch '<hierarchy') { throw "uiautomator dump failed: $($dump.Output)" }
    if ($Name -ne '') { [IO.File]::WriteAllText((Join-Path $caseDir $Name), $raw, (New-Object Text.UTF8Encoding($false))) }
    return $raw
}
function Get-AppTexts {
    param([string]$Raw)
    [xml]$doc = $Raw
    $out = @()
    foreach ($n in $doc.SelectNodes('//node')) {
        if ([string]$n.package -ne $pkg) { continue }
        $t = [string]$n.text
        if (-not $t) { continue }
        $b = [regex]::Match([string]$n.bounds, '\[(\d+),(\d+)\]\[(\d+),(\d+)\]')
        $l = 0; $top = 0; $r = 0; $bot = 0
        if ($b.Success) { $l = [int]$b.Groups[1].Value; $top = [int]$b.Groups[2].Value; $r = [int]$b.Groups[3].Value; $bot = [int]$b.Groups[4].Value }
        $out += [pscustomobject]@{ Text = $t; L = $l; T = $top; R = $r; B = $bot }
    }
    return $out
}
function Find-TextBounds {
    param([string]$Text)
    $raw = Get-PhoneUi
    [xml]$doc = $raw
    foreach ($n in $doc.SelectNodes('//node')) {
        if ([string]$n.package -ne $pkg) { continue }
        if ([string]$n.text -eq $Text) {
            $m = [regex]::Match([string]$n.bounds, '\[(\d+),(\d+)\]\[(\d+),(\d+)\]')
            if ($m.Success) {
                return @{ X = [int](([int]$m.Groups[1].Value + [int]$m.Groups[3].Value) / 2); Y = [int](([int]$m.Groups[2].Value + [int]$m.Groups[4].Value) / 2) }
            }
        }
    }
    return $null
}
function Tap-Text {
    param([string]$Text, [int]$TimeoutSeconds = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $c = Find-TextBounds -Text $Text
            if ($c) {
                Invoke-Adb -AdbArgs @('shell', 'input', 'tap', $c.X, $c.Y) | Out-Null
                Log "tap '$Text' at $($c.X),$($c.Y)"
                Start-Sleep -Milliseconds 700
                return $true
            }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Analyze-Page {
    param([string]$Name, [string]$Label)
    $raw = Get-PhoneUi -Name ($Name + '.xml')
    $texts = @(Get-AppTexts -Raw $raw)
    $chinese = @($texts | Where-Object { $_.Text -match '[\u4e00-\u9fff]' })
    $keys = @($texts | Where-Object { $_.Text -match '(?i)\b(ui|error|wizard|diag|update|pair|backup|devices|photos|nav|settings)\.[a-z0-9_]+\b' -or $_.Text -match '\b[A-Z][A-Z0-9]*(_[A-Z0-9]+){1,}\b' })
    $trunc = @($texts | Where-Object { $_.R -gt $screenW + 2 -or $_.B -gt $screenH + 2 -or $_.L -lt -2 -or $_.T -lt -2 -or $_.Text.EndsWith('…') -or $_.Text.EndsWith('...') })
    $texts | ForEach-Object { "$($_.Text)`t[$($_.L),$($_.T),$($_.R),$($_.B)]" } | Set-Content -LiteralPath (Join-Path $caseDir ($Name + '-text.txt')) -Encoding UTF8
    Log "$Label : appTexts=$($texts.Count) chinese=$($chinese.Count) keys=$($keys.Count) trunc=$($trunc.Count)"
    $chinese | Select-Object -First 8 | ForEach-Object { Log "  CN: $($_.Text) [$($_.L),$($_.T),$($_.R),$($_.B)]" }
    $keys | Select-Object -First 8 | ForEach-Object { Log "  KEY: $($_.Text)" }
    $trunc | Select-Object -First 8 | ForEach-Object { Log "  TRUNC: $($_.Text) [$($_.L),$($_.T),$($_.R),$($_.B)]" }
    return [pscustomobject]@{ Label = $Label; Texts = $texts.Count; Chinese = $chinese.Count; Keys = $keys.Count; Trunc = $trunc.Count; ChineseSamples = @($chinese | ForEach-Object { $_.Text }); KeySamples = @($keys | ForEach-Object { $_.Text }); TruncSamples = @($trunc | ForEach-Object { $_.Text }) }
}

Log "=== #1063 R6.3 per-app phone locale $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
$win = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'window')
$pre = ''
try { $pre = Get-PhoneUi -Name 'phone-preflight.xml' } catch { }
if ($win.Output -match 'mDreamingLockscreen=true' -or $pre -match '画出解锁图案|紧急呼叫') {
    Finish 'UNCOVERED' 'phone is locked; unlock it and rerun (no bypass attempted)'
}
$power = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'power')
if ($power.Output -notmatch 'mStayOn=true') { Log 'WARN: mStayOn is not true' }

$set = Invoke-Adb -AdbArgs @('shell', 'cmd', 'locale', 'set-app-locales', $pkg, '--locales', 'en-US')
Log "set-app-locales en-US exit=$($set.Code)"
Invoke-Adb -AdbArgs @('shell', 'am', 'force-stop', $pkg) | Out-Null
Invoke-Adb -AdbArgs @('shell', 'monkey', '-p', $pkg, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
Start-Sleep -Seconds 4
$get = Invoke-Adb -AdbArgs @('shell', 'cmd', 'locale', 'get-app-locales', $pkg)
Log "get-app-locales: $($get.Output)"

# Android has only two tabs: Photos and Settings. The second tab is the
# backup-status page and the settings page in one; there is no third distinct
# screen to dump.
$pages = @()
if (-not (Tap-Text -Text 'Photos' -TimeoutSeconds 5)) { Log 'WARN: Photos tab not found' }
$pages += Analyze-Page -Name 'photos-en' -Label '首页/Photos(照片页)'
if (-not (Tap-Text -Text 'Settings' -TimeoutSeconds 15)) { Log 'WARN: Settings tab not found' }
$pages += Analyze-Page -Name 'settings-en' -Label '备份+设置页(Settings)'

$clear = Invoke-Adb -AdbArgs @('shell', 'cmd', 'locale', 'set-app-locales', $pkg, '--locales', '')
Log "set-app-locales empty exit=$($clear.Code)"
$getAfter = Invoke-Adb -AdbArgs @('shell', 'cmd', 'locale', 'get-app-locales', $pkg)
Log "get-app-locales after restore: $($getAfter.Output)"
Invoke-Adb -AdbArgs @('shell', 'am', 'force-stop', $pkg) | Out-Null
Invoke-Adb -AdbArgs @('shell', 'monkey', '-p', $pkg, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
Start-Sleep -Seconds 4
$zhRaw = Get-PhoneUi -Name 'home-zh-restored.xml'
$zhTexts = @(Get-AppTexts -Raw $zhRaw)
$zhChinese = @($zhTexts | Where-Object { $_.Text -match '[\u4e00-\u9fff]' }).Count
Log "restored Chinese text nodes=$zhChinese"

$totalChinese = ($pages | Measure-Object -Property Chinese -Sum).Sum
$totalKeys = ($pages | Measure-Object -Property Keys -Sum).Sum
$totalTrunc = ($pages | Measure-Object -Property Trunc -Sum).Sum
$summary = ($pages | ForEach-Object { "$($_.Label):texts=$($_.Texts),cn=$($_.Chinese),keys=$($_.Keys),trunc=$($_.Trunc)" }) -join '; '
Log "summary: $summary"

if ($totalChinese -eq 0 -and $totalKeys -eq 0 -and $totalTrunc -eq 0 -and $zhChinese -gt 0 -and $getAfter.Output -match '\[\]') {
    Finish 'PASS' "English phone pages clean; Chinese restored"
} elseif ($totalChinese -gt 0) {
    Finish 'PARTIAL' "Chinese leftovers in English pages; $summary"
} else {
    Finish 'PARTIAL' "key/truncation or restore issue; $summary; restoredChinese=$zhChinese"
}
