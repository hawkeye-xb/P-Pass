#Requires -Version 5.1
# 1063-r63-locale.ps1 - R6.3 per-app English locale on the PHONE.
#
# Sets only com.hawkeyexb.ppass to en-US, then dumps the phone UI with
# uiautomator for the three screens the case asks for:
#   home    - Photos tab (the phone's home/photo wall)
#   backup  - Settings tab, top: backup status / album scope / storage
#   settings- Settings tab, after a scroll: the settings rows
# Android exposes two tabs; the backup status and the settings rows share the
# second tab, so the "backup" and "settings" dumps can be the same pixels when
# the page fits on one screen. The script records whether they differ.
#
# Each dump is checked for:
#   1. leftover Chinese characters
#   2. raw i18n keys (dotted lower_case identifiers, ALL_CAPS_WITH_UNDERSCORE)
#   3. clipped text (bounds outside the real screen, or trailing ellipsis)
#
# Then it clears the per-app locale (--locales "") and verifies the phone UI is
# Chinese again. It never sends a sleep/power key and never tries to unlock:
# if the keyguard shows up at any step it stops and reports UNCOVERED.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\1063-r63-locale.ps1
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
$deviceXml = '/sdcard/1063-r63.xml'
$script:localeSet = $false
$script:screenW = 0
$script:screenH = 0
$cnRe = '[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]'
$lockRe = '\u753b\u51fa\u89e3\u9501\u56fe\u6848|\u7d27\u6025\u547c\u53eb|\u7ed8\u5236\u56fe\u6848'
$keyDottedRe = '\b[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]+)+\b'
$keyCapsRe = '\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

function Log([string]$m) {
    [Console]::WriteLine($m)
    $script:lines.Add($m)
}
function Save-Result([string]$result, [string]$detail) {
    $text = @("case=R6.3", "result=$result", "detail=$detail") + $script:lines
    [IO.File]::WriteAllLines($resultPath, $text, (New-Object Text.UTF8Encoding($false)))
    Log "RESULT=$result $detail"
}
function Invoke-Adb {
    param([string[]]$AdbArgs)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $adb @AdbArgs 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    return [pscustomobject]@{ Code = $code; Output = (($out | Out-String).Trim()) }
}
function Test-LockScreen([string]$Raw) {
    if ($Raw -match $lockRe) { return $true }
    if ($Raw -match '(?i)swipe up to unlock|enter pin|emergency call') { return $true }
    return $false
}
function Get-PhoneUi {
    param([string]$Name = '')
    $local = if ($Name -ne '') { Join-Path $caseDir $Name } else { Join-Path $env:TEMP '1063-r63-ui.xml' }
    $last = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-Path -LiteralPath $local) { Remove-Item -LiteralPath $local -Force }
        Invoke-Adb -AdbArgs @('shell', 'rm', '-f', $deviceXml) | Out-Null
        $dump = Invoke-Adb -AdbArgs @('shell', 'uiautomator', 'dump', $deviceXml)
        if ($dump.Code -ne 0 -or $dump.Output -match 'ERROR|could not get idle') {
            $last = "dump: $($dump.Output)"
            if ($attempt -lt 3) { Start-Sleep -Milliseconds 900 }
            continue
        }
        Invoke-Adb -AdbArgs @('pull', $deviceXml, $local) | Out-Null
        if (-not (Test-Path -LiteralPath $local)) {
            $last = 'adb pull produced no file'
            if ($attempt -lt 3) { Start-Sleep -Milliseconds 900 }
            continue
        }
        $raw = [IO.File]::ReadAllText($local, [Text.Encoding]::UTF8)
        if ($raw -match '<hierarchy') { return $raw }
        $last = 'xml has no <hierarchy>'
        if ($attempt -lt 3) { Start-Sleep -Milliseconds 900 }
    }
    throw "uiautomator dump failed after 3 tries: $last"
}
function Assert-Unlocked([string]$Step) {
    $win = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'window')
    if ($win.Output -match 'mDreamingLockscreen=true' -or $win.Output -match 'mKeyguardShowing=true') {
        throw "LOCKED: keyguard flag is up at $Step"
    }
    $raw = Get-PhoneUi
    if (Test-LockScreen $raw) { throw "LOCKED: lock-screen text is visible at $Step" }
    Log "unlocked: $Step"
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
        if ($b.Success) {
            $l = [int]$b.Groups[1].Value; $top = [int]$b.Groups[2].Value
            $r = [int]$b.Groups[3].Value; $bot = [int]$b.Groups[4].Value
        }
        $out += [pscustomobject]@{ Text = $t; L = $l; T = $top; R = $r; B = $bot }
    }
    return $out
}
function Find-TextBounds {
    param([string]$Text)
    $raw = Get-PhoneUi
    if (Test-LockScreen $raw) { throw 'LOCKED: lock-screen text is visible while navigating' }
    [xml]$doc = $raw
    foreach ($n in $doc.SelectNodes('//node')) {
        if ([string]$n.package -ne $pkg) { continue }
        if ([string]$n.text -eq $Text) {
            $m = [regex]::Match([string]$n.bounds, '\[(\d+),(\d+)\]\[(\d+),(\d+)\]')
            if ($m.Success) {
                return @{
                    X = [int](([int]$m.Groups[1].Value + [int]$m.Groups[3].Value) / 2)
                    Y = [int](([int]$m.Groups[2].Value + [int]$m.Groups[4].Value) / 2)
                }
            }
        }
    }
    return $null
}
function Tap-Text {
    param([string]$Text, [int]$TimeoutSeconds = 12)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $c = Find-TextBounds -Text $Text
        if ($c) {
            Invoke-Adb -AdbArgs @('shell', 'input', 'tap', $c.X, $c.Y) | Out-Null
            Log "tap '$Text' at $($c.X),$($c.Y)"
            Start-Sleep -Milliseconds 800
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Restart-App {
    Invoke-Adb -AdbArgs @('shell', 'am', 'force-stop', $pkg) | Out-Null
    Start-Sleep -Milliseconds 500
    $start = Invoke-Adb -AdbArgs @('shell', 'am', 'start', '-W', '-n', "$pkg/.MainActivity")
    Log "am start exit=$($start.Code)"
    Start-Sleep -Seconds 3
}
function Analyze-Page {
    param(
        [string]$Name,
        [string]$Label,
        [string[]]$Require = @(),
        [string[]]$RequireAny = @(),
        [int]$SettleSeconds = 8
    )
    $deadline = (Get-Date).AddSeconds($SettleSeconds)
    $raw = ''
    $texts = @()
    $all = @()
    $missing = @()
    $anyOk = $true
    while ($true) {
        $raw = Get-PhoneUi -Name ($Name + '.xml')
        if (Test-LockScreen $raw) { throw "LOCKED: lock-screen text is visible on $Label" }
        $texts = @(Get-AppTexts -Raw $raw)
        $all = @($texts | ForEach-Object { $_.Text })
        $missing = @($Require | Where-Object { $all -notcontains $_ })
        $anyOk = $true
        if ($RequireAny.Count -gt 0) {
            $anyOk = (@($RequireAny | Where-Object { $all -contains $_ }).Count -gt 0)
        }
        if (($missing.Count -eq 0 -and $anyOk) -or (Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 600
    }

    $chinese = @($texts | Where-Object { $_.Text -match $cnRe })
    $keys = @($texts | Where-Object { $_.Text -match $keyDottedRe -or $_.Text -match $keyCapsRe })
    $trunc = @($texts | Where-Object {
            $_.R -gt ($script:screenW + 2) -or $_.B -gt ($script:screenH + 2) -or
            $_.L -lt -2 -or $_.T -lt -2 -or
            $_.Text.EndsWith([string][char]0x2026) -or $_.Text.EndsWith('...')
        })

    $textLines = @($texts | ForEach-Object { "$($_.Text)`t[$($_.L),$($_.T),$($_.R),$($_.B)]" })
    [IO.File]::WriteAllLines((Join-Path $caseDir ($Name + '-text.txt')), $textLines, (New-Object Text.UTF8Encoding($false)))

    Log "$Label : appTexts=$($texts.Count) chinese=$($chinese.Count) keys=$($keys.Count) trunc=$($trunc.Count) missingMarkers=$($missing.Count) anyMarker=$anyOk"
    $chinese | Select-Object -First 8 | ForEach-Object { Log "  CN: $($_.Text) [$($_.L),$($_.T),$($_.R),$($_.B)]" }
    $keys | Select-Object -First 8 | ForEach-Object { Log "  KEY: $($_.Text)" }
    $trunc | Select-Object -First 8 | ForEach-Object { Log "  TRUNC: $($_.Text) [$($_.L),$($_.T),$($_.R),$($_.B)]" }
    if ($missing.Count -gt 0) { Log "  MISSING: $($missing -join ', ')" }

    return [pscustomobject]@{
        Label = $Label; Texts = $texts.Count; Chinese = $chinese.Count
        Keys = $keys.Count; Trunc = $trunc.Count
        Missing = $missing; AnyOk = $anyOk
        TextList = $all
        ChineseSamples = @($chinese | ForEach-Object { $_.Text })
        KeySamples = @($keys | ForEach-Object { $_.Text })
        TruncSamples = @($trunc | ForEach-Object { $_.Text })
    }
}

$lockedAt = ''
$errorText = ''
$pages = @()
$cleared = $false
$getAfter = $null
$zhChinese = 0
$zhPhotosTab = $false
$zhSettingsTab = $false
$restoreError = ''

Log "=== #1063 R6.3 per-app phone locale $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
try {
    $state = Invoke-Adb -AdbArgs @('get-state')
    if ($state.Output -ne 'device') { throw "adb device not ready: $($state.Output)" }
    $serial = Invoke-Adb -AdbArgs @('shell', 'getprop', 'ro.serialno')
    Log "device=$($serial.Output)"
    $size = Invoke-Adb -AdbArgs @('shell', 'wm', 'size')
    $sizeMatches = [regex]::Matches($size.Output, '(\d+)x(\d+)')
    if ($sizeMatches.Count -gt 0) {
        $m = $sizeMatches[$sizeMatches.Count - 1]
        $script:screenW = [int]$m.Groups[1].Value
        $script:screenH = [int]$m.Groups[2].Value
    } else {
        $script:screenW = 1080; $script:screenH = 2340
    }
    Log "screen=$($script:screenW)x$($script:screenH)"

    Assert-Unlocked 'preflight'
    $pre = Get-PhoneUi -Name 'phone-preflight.xml'
    if (Test-LockScreen $pre) { throw 'LOCKED: preflight dump shows the lock screen' }
    $power = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'power')
    if ($power.Output -notmatch 'mWakefulness=Awake') { throw 'phone is not Awake; not waking it' }
    if ($power.Output -notmatch 'mStayOn=true') { throw 'mStayOn is false; refusing to run without USB stay-on' }

    $set = Invoke-Adb -AdbArgs @('shell', 'cmd', 'locale', 'set-app-locales', $pkg, '--locales', 'en-US')
    $script:localeSet = $true
    Log "set-app-locales en-US exit=$($set.Code)"
    $get = Invoke-Adb -AdbArgs @('shell', 'cmd', 'locale', 'get-app-locales', $pkg)
    Log "get-app-locales: $($get.Output)"
    if ($get.Output -notmatch '\[en-US\]') { throw "per-app locale is not en-US: $($get.Output)" }

    Restart-App
    Assert-Unlocked 'after en-US relaunch'

    Tap-Text -Text 'Photos' -TimeoutSeconds 6 | Out-Null
    $photosPage = Analyze-Page -Name 'photos-en' -Label 'home/Photos' `
        -Require @('Photos', 'Settings') -SettleSeconds 10
    $pages += $photosPage

    if (-not (Tap-Text -Text 'Settings' -TimeoutSeconds 12)) { throw 'Settings tab was not found in English UI' }
    $backupPage = Analyze-Page -Name 'backup-en' -Label 'backup/Settings-top' `
        -Require @('Settings') -RequireAny @('Albums to back up', 'Storage computer', 'Last success') -SettleSeconds 12
    $pages += $backupPage

    Invoke-Adb -AdbArgs @('shell', 'input', 'swipe', 540, 1600, 540, 800, 400) | Out-Null
    Start-Sleep -Milliseconds 900
    $settingsPage = Analyze-Page -Name 'settings-en' -Label 'settings/Settings-lower' `
        -Require @('Settings') -RequireAny @('Version', 'Check for updates', 'Background backup') -SettleSeconds 10
    $pages += $settingsPage

    $samePixels = (($backupPage.TextList -join "`n") -eq ($settingsPage.TextList -join "`n"))
    Log "backup and settings dumps have identical text: $samePixels (page fits one screen: $samePixels)"
    $versionText = @($backupPage.TextList + $settingsPage.TextList | Where-Object { $_ -match '^\d+\.\d+\.\d+' } | Select-Object -First 1)
    if ($versionText.Count -gt 0) { Log "app-version=$($versionText[0])" }
} catch {
    $msg = $_.Exception.Message
    if ($msg -like 'LOCKED:*') { $lockedAt = $msg } else { $errorText = $msg }
    Log "ERROR: $msg"
} finally {
    if ($script:localeSet) {
        $clear = Invoke-Adb -AdbArgs @('shell', 'cmd', 'locale', 'set-app-locales', $pkg, '--locales', '')
        Log "set-app-locales empty exit=$($clear.Code)"
        $getAfter = Invoke-Adb -AdbArgs @('shell', 'cmd', 'locale', 'get-app-locales', $pkg)
        Log "get-app-locales after restore: $($getAfter.Output)"
        $cleared = ($getAfter.Output -match '\[\]')

        if ($lockedAt -eq '') {
            try {
                Restart-App
                Assert-Unlocked 'after restore'
                $zhRaw = Get-PhoneUi -Name 'home-zh-restored.xml'
                $zhTexts = @(Get-AppTexts -Raw $zhRaw)
                $zhAll = @($zhTexts | ForEach-Object { $_.Text })
                $zhChinese = @($zhTexts | Where-Object { $_.Text -match $cnRe }).Count
                $zhPhotosTab = (@($zhAll | Where-Object { $_ -match '\u7167\u7247' }).Count -gt 0)
                $zhSettingsTab = (@($zhAll | Where-Object { $_ -match '\u8bbe\u7f6e' }).Count -gt 0)
                $zhLines = @($zhTexts | ForEach-Object { "$($_.Text)`t[$($_.L),$($_.T),$($_.R),$($_.B)]" })
                [IO.File]::WriteAllLines((Join-Path $caseDir 'home-zh-restored-text.txt'), $zhLines, (New-Object Text.UTF8Encoding($false)))
                Log "restored: chineseNodes=$zhChinese photosTab=$zhPhotosTab settingsTab=$zhSettingsTab cleared=$cleared"
            } catch {
                $restoreError = $_.Exception.Message
                if ($restoreError -like 'LOCKED:*' -and $lockedAt -eq '') { $lockedAt = $restoreError }
                Log "ERROR during restore verification: $restoreError"
            }
        } else {
            Log 'locked before restore verification; skipped UI relaunch'
        }
    }
}

$totalChinese = 0; $totalKeys = 0; $totalTrunc = 0; $missingMarkers = 0; $anyMarkerFail = 0
foreach ($p in $pages) {
    $totalChinese += $p.Chinese
    $totalKeys += $p.Keys
    $totalTrunc += $p.Trunc
    $missingMarkers += $p.Missing.Count
    if (-not $p.AnyOk) { $anyMarkerFail++ }
}
$summary = ($pages | ForEach-Object { "$($_.Label):texts=$($_.Texts),cn=$($_.Chinese),keys=$($_.Keys),trunc=$($_.Trunc)" }) -join '; '
$pagesComplete = ($pages.Count -eq 3 -and $missingMarkers -eq 0 -and $anyMarkerFail -eq 0)
$pagesClean = ($totalChinese -eq 0 -and $totalKeys -eq 0 -and $totalTrunc -eq 0)
$restoreOk = ($cleared -and $zhChinese -ge 3 -and $zhPhotosTab -and $zhSettingsTab)
Log "summary: $summary"
Log "totals: pages=$($pages.Count)/3 chinese=$totalChinese keys=$totalKeys trunc=$totalTrunc missingMarkers=$missingMarkers"
Log "restore: cleared=$cleared chineseNodes=$zhChinese photosTab=$zhPhotosTab settingsTab=$zhSettingsTab"

$result = 'UNCOVERED'
$detail = ''
if ($lockedAt -ne '') {
    if ($pages.Count -eq 0) {
        $result = 'UNCOVERED'
        $detail = "$lockedAt; no per-app locale change was made"
    } else {
        $result = 'PARTIAL'
        $detail = "$lockedAt; English pages captured=$($pages.Count), cn=$totalChinese keys=$totalKeys trunc=$totalTrunc; localeCleared=$cleared; chineseUiVerified=$restoreOk"
    }
} elseif (-not $script:localeSet) {
    $result = 'UNCOVERED'
    $detail = "en-US was not applied: $errorText"
} elseif (-not $pagesClean) {
    $result = 'PARTIAL'
    $detail = "chinese=$totalChinese keys=$totalKeys trunc=$totalTrunc; $summary"
} elseif (-not $pagesComplete) {
    $result = 'PARTIAL'
    $detail = "English pages clean but page coverage incomplete: pages=$($pages.Count)/3 missingMarkers=$missingMarkers anyMarkerFail=$anyMarkerFail; $summary"
} elseif (-not $restoreOk) {
    $result = 'PARTIAL'
    $detail = "English pages clean; restore incomplete: cleared=$cleared chineseNodes=$zhChinese photosTab=$zhPhotosTab settingsTab=$zhSettingsTab $restoreError"
} elseif ($errorText -ne '') {
    $result = 'UNCOVERED'
    $detail = "run stopped: $errorText"
} else {
    $result = 'PASS'
    $detail = "3 dumps clean; en-US applied; locale cleared; Chinese UI restored"
}
Save-Result $result $detail
if ($result -eq 'PASS') { exit 0 } else { exit 1 }
