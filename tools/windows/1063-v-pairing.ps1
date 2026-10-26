#Requires -Version 5.1
# 1063-v-pairing.ps1 - V1/V2/V3 protocol-v2 text cases on the unlocked phone.
#   V1: phone enters a pairing string, desktop clicks Reject.
#   V2: phone enters a pairing string, nobody confirms for 10 minutes.
#   V3: phone enters a pairing string, desktop uses its own Stop/Start service
#       buttons, which invalidates the request.
# Requires an unlocked phone (secure keyguard is refused) and the desktop App.
param(
    [Parameter(Mandatory = $true)][ValidateSet('V1', 'V2', 'V3')][string]$Case,
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [int]$ExpireSeconds = 600
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot $Case
New-Item -ItemType Directory -Force $caseDir | Out-Null
$timeline = Join-Path $caseDir 'timeline.txt'
$resultPath = Join-Path $caseDir 'result.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
$adb = (Get-Command adb -ErrorAction Stop).Source
$bash = 'C:\Program Files\Git\bin\bash.exe'
$pkg = 'com.hawkeyexb.ppass'
$pairStart = Join-Path $PSScriptRoot '1063-pair-start.sh'
$uia = Join-Path $PSScriptRoot 'uia-drive.ps1'
$daemonLog = Join-Path $env:LOCALAPPDATA 'com.hawkeyexb.ppass.desktop\logs\daemon.log'

function Log([string]$m) { [Console]::WriteLine($m); $script:lines.Add($m) }
function Event([string]$m) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $m"
    Add-Content -LiteralPath $timeline -Value $line -Encoding UTF8
    Log $line
}
function Finish([string]$result, [string]$detail) {
    $text = @("case=$Case", "result=$result", "detail=$detail") + $script:lines
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
    $dump = Invoke-Adb -AdbArgs @('shell', 'uiautomator', 'dump', '/sdcard/1063-v.xml')
    $cat = Invoke-Adb -AdbArgs @('exec-out', 'cat', '/sdcard/1063-v.xml')
    $raw = [string]$cat.Output
    if ($raw -notmatch '<hierarchy') { return '' }
    if ($Name -ne '') { [IO.File]::WriteAllText((Join-Path $caseDir $Name), $raw, (New-Object Text.UTF8Encoding($false))) }
    return $raw
}
function Get-PhoneText {
    param([string]$Raw)
    return @([regex]::Matches($Raw, 'text="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne '' })
}
function Find-PhoneNode {
    param([string]$Raw, [string]$Text, [string]$Class = '')
    [xml]$doc = $Raw
    foreach ($n in $doc.SelectNodes('//node')) {
        if ($Class -ne '' -and [string]$n.class -ne $Class) { continue }
        if ([string]$n.text -eq $Text -or [string]$n.'content-desc' -eq $Text) { return $n }
    }
    foreach ($n in $doc.SelectNodes('//node')) {
        if ($Class -ne '' -and [string]$n.class -ne $Class) { continue }
        if ([string]$n.text -like "*$Text*" -or [string]$n.'content-desc' -like "*$Text*") { return $n }
    }
    return $null
}
function Get-Center {
    param($Node)
    $m = [regex]::Match([string]$Node.bounds, '\[(\d+),(\d+)\]\[(\d+),(\d+)\]')
    if (-not $m.Success) { return $null }
    return @{ X = [int](([int]$m.Groups[1].Value + [int]$m.Groups[3].Value) / 2); Y = [int](([int]$m.Groups[2].Value + [int]$m.Groups[4].Value) / 2) }
}
function Tap-Text {
    param([string]$Text, [string]$Class = '', [int]$TimeoutSeconds = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $raw = Get-PhoneUi
            $n = Find-PhoneNode -Raw $raw -Text $Text -Class $Class
            if ($n) {
                $c = Get-Center $n
                if ($c) {
                    Invoke-Adb -AdbArgs @('shell', 'input', 'tap', $c.X, $c.Y) | Out-Null
                    Event "tap '$Text' at $($c.X),$($c.Y)"
                    Start-Sleep -Milliseconds 500
                    return $true
                }
            }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Wait-PhoneText {
    param([string]$Text, [int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try { if ((Get-PhoneUi) -like "*$Text*") { return $true } } catch { }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Tap-Edit {
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        try {
            $raw = Get-PhoneUi
            $n = Find-PhoneNode -Raw $raw -Text '' -Class 'android.widget.EditText'
            if ($n) {
                $c = Get-Center $n
                if ($c) { Invoke-Adb -AdbArgs @('shell', 'input', 'tap', $c.X, $c.Y) | Out-Null; Start-Sleep -Milliseconds 300; return $true }
            }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Get-PhoneCode {
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        try {
            $raw = Get-PhoneUi
            $m = [regex]::Match($raw, '(?<!\d)(\d{3})\s+(\d{3})(?!\d)')
            if ($m.Success) { return ($m.Groups[1].Value + $m.Groups[2].Value) }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    return $null
}
function Dump-Desktop([string]$Name) {
    $out = Join-Path $caseDir $Name
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uia -Action dump -Out $out 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { return '' }
    return (Get-Content -LiteralPath $out -Raw -Encoding UTF8)
}
function Click-Desktop([string]$Name, [int]$TimeoutSeconds = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uia -Action click -Name $Name -Out (Join-Path $caseDir 'uia-click.txt') 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
        if ($code -eq 0) { Event "desktop click '$Name'"; Start-Sleep -Milliseconds 600; return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Get-Devices {
    $out = & $bash (Join-Path $PSScriptRoot '1063-ipc-devices.sh') 2>&1
    try { $j = (($out | Out-String).Trim()) | ConvertFrom-Json; return @($j.result.devices) } catch { return @() }
}

Log "=== #1063 $Case $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Event 'case start'
# Unlock/stay-on guard: never send SLEEP; require the user-unlocked screen.
$win = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'window')
$ui = ''
try { $ui = Get-PhoneUi -Name 'phone-preflight.xml' } catch { }
if ($win.Output -match 'mDreamingLockscreen=true' -or $ui -match '画出解锁图案|紧急呼叫') {
    Finish 'UNCOVERED' 'phone is locked; unlock it and rerun (no bypass attempted)'
}
$stay = Invoke-Adb -AdbArgs @('shell', 'dumpsys', 'power')
if ($stay.Output -notmatch 'mStayOn=true') { Event 'WARN: mStayOn is not true' }

# Bring the phone App to the foreground; no screen-off key is ever sent.
Invoke-Adb -AdbArgs @('shell', 'monkey', '-p', $pkg, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
Start-Sleep -Seconds 2
$ui = Get-PhoneUi -Name 'phone-start.xml'
if ($ui -match 'text="输入配对串"') {
    # already on manual input
} elseif (Wait-PhoneText -Text '无法扫码？手动输入配对串' -TimeoutSeconds 8) {
    Tap-Text -Text '无法扫码？手动输入配对串' | Out-Null
} elseif (Wait-PhoneText -Text '重新扫码' -TimeoutSeconds 3) {
    Tap-Text -Text '重新扫码' | Out-Null
    Start-Sleep -Milliseconds 800
    Tap-Text -Text '无法扫码？手动输入配对串' -TimeoutSeconds 10 | Out-Null
} else {
    Get-PhoneUi -Name 'phone-no-manual.xml' | Out-Null
    Finish 'UNCOVERED' 'phone is not on Welcome/manual pairing'
}
# Welcome also contains the link text "手动输入配对串"; require the actual
# placeholder/title of the input screen.
if (-not (Wait-PhoneText -Text 'ppf://pair?node' -TimeoutSeconds 15)) {
    Finish 'UNCOVERED' 'manual pairing input did not open'
}

# Fresh pairing string from daemon IPC, kept in memory only.
$old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $pairOut = & $bash $pairStart 2>&1; $pairCode = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
if ($pairCode -ne 0) { Finish 'UNCOVERED' "pair-start helper failed" }
$qr = ((($pairOut | Out-String).Trim()) | ConvertFrom-Json).result.qr
if (-not $qr.StartsWith('ppf://pair?')) { Finish 'UNCOVERED' 'no ppf://pair string' }
Event "pairing string ready length=$($qr.Length)"
if (-not (Tap-Edit)) { Finish 'UNCOVERED' 'pairing input field not found' }
$escaped = $qr.Replace("'", "'\''")
$typed = Invoke-Adb -AdbArgs @('shell', "input text '$escaped'")
Event "input text exit=$($typed.Code)"
Invoke-Adb -AdbArgs @('shell', 'input', 'keyevent', '4') | Out-Null
Start-Sleep -Milliseconds 500
Get-PhoneUi -Name 'phone-filled.xml' | Out-Null
if (-not (Tap-Text -Text '连接' -TimeoutSeconds 15)) { Finish 'UNCOVERED' 'Connect button not found' }
$code = Get-PhoneCode
if (-not $code) { Finish 'UNCOVERED' 'phone did not show 6-digit code' }
Event 'phone code shown; waiting for desktop pending dialog'

$deadline = (Get-Date).AddSeconds(45)
$pending = $false
while ((Get-Date) -lt $deadline) {
    $txt = Dump-Desktop 'desktop-pending.txt'
    if ($txt -match '拒绝' -or $txt -match '允许加入') { $pending = $true; break }
    Start-Sleep -Milliseconds 500
}
if (-not $pending) { Finish 'UNCOVERED' 'desktop pending dialog did not appear' }
Event 'desktop pending dialog visible'

if ($Case -eq 'V1') {
    if (-not (Click-Desktop '拒绝' 15)) { Finish 'UNCOVERED' 'desktop Reject button not found' }
    if (-not (Wait-PhoneText -Text '电脑上拒绝了这次加入' -TimeoutSeconds 20)) {
        Get-PhoneUi -Name 'phone-after-reject.xml' | Out-Null
        Finish 'FAIL' 'expected 电脑上拒绝了这次加入。not found'
    }
    $phone = Get-PhoneUi -Name 'phone-after-reject.xml'
    $texts = Get-PhoneText $phone
    $texts | Set-Content -LiteralPath (Join-Path $caseDir 'phone-text.txt') -Encoding UTF8
    $phoneText = ($texts -join ' | ')
    Event "phone after reject: $phoneText"
    $logLines = @(Get-Content -LiteralPath $daemonLog -Encoding UTF8 -ErrorAction SilentlyContinue | Select-String -Pattern 'pair|refus|denied|reject' | Select-Object -Last 20)
    $logLines | Set-Content -LiteralPath (Join-Path $caseDir 'daemon-log-window.txt') -Encoding UTF8
    $logText = ($logLines -join "`n")
    if ($phoneText -match '电脑上拒绝了这次加入' -and $logText -match 'pair|refus|denied|reject') {
        Finish 'PASS' 'phone shows exact denied text; daemon log has a pairing/refusal line'
    } else {
        Finish 'FAIL' "phone=$phoneText logmatched=$($logText -match 'pair|refus|denied|reject')"
    }
} elseif ($Case -eq 'V2') {
    Event "V2 waiting up to ${ExpireSeconds}s with no desktop action"
    $expired = $false
    $end = (Get-Date).AddSeconds($ExpireSeconds)
    while ((Get-Date) -lt $end) {
        $p = Get-PhoneUi
        if ($p -match '过期|expired|重新生成配对码') { $expired = $true; break }
        Start-Sleep -Seconds 5
    }
    $phone = Get-PhoneUi -Name 'phone-after-expire.xml'
    $texts = Get-PhoneText $phone
    $texts | Set-Content -LiteralPath (Join-Path $caseDir 'phone-text.txt') -Encoding UTF8
    $phoneText = ($texts -join ' | ')
    Event "phone after expire: $phoneText"
    $logLines = @(Get-Content -LiteralPath $daemonLog -Encoding UTF8 -ErrorAction SilentlyContinue | Select-String -Pattern 'pair|expire|lapsed|timeout' | Select-Object -Last 20)
    $logLines | Set-Content -LiteralPath (Join-Path $caseDir 'daemon-log-window.txt') -Encoding UTF8
    $logText = ($logLines -join "`n")
    if ($expired -and $phoneText -match '过期|重新生成配对码' -and $logText -match 'pair|expire|lapsed|timeout') {
        Finish 'PASS' 'phone shows expired text; daemon log has a pairing/expiry line'
    } else {
        Finish 'FAIL' "expired=$expired phone=$phoneText logmatched=$($logText -match 'pair|expire|lapsed|timeout')"
    }
} else {
    # V3: close the pending modal without deciding, then use Settings' own
    # Stop/Start service buttons. This is the product action, not a kill.
    Click-Desktop '关闭' 5 | Out-Null
    Start-Sleep -Milliseconds 500
    if (-not (Click-Desktop '设置' 10)) { Finish 'UNCOVERED' 'desktop Settings tab not found' }
    if (-not (Click-Desktop '停止后台服务' 20)) { Finish 'UNCOVERED' 'desktop Stop service button not found' }
    Start-Sleep -Seconds 1
    # The Stop click opens a native confirmation dialog; confirm it with
    # BM_CLICK (the task-dialog buttons have no InvokePattern).
    $native = Join-Path $PSScriptRoot 'uia-click-native.ps1'
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $nc = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $native -WindowName '停止后台服务' -ButtonName '确定' 2>&1; $ncode = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    Event "stop confirmation native exit=$ncode $nc"
    Start-Sleep -Seconds 2
    # Start lives on Overview's "service not running" card.
    if (-not (Click-Desktop '总览' 10)) { Finish 'UNCOVERED' 'desktop Overview tab not found' }
    if (-not (Click-Desktop '启动后台服务' 30)) {
        Finish 'UNCOVERED' 'desktop Start service button not found'
    }
    if (-not (Wait-PhoneText -Text '电脑端服务重启了' -TimeoutSeconds 45)) {
        Get-PhoneUi -Name 'phone-after-restart.xml' | Out-Null
        Finish 'FAIL' 'expected 电脑端服务重启了 text not found'
    }
    $phone = Get-PhoneUi -Name 'phone-after-restart.xml'
    $texts = Get-PhoneText $phone
    $texts | Set-Content -LiteralPath (Join-Path $caseDir 'phone-text.txt') -Encoding UTF8
    $phoneText = ($texts -join ' | ')
    Event "phone after restart: $phoneText"
    $logLines = @(Get-Content -LiteralPath $daemonLog -Encoding UTF8 -ErrorAction SilentlyContinue | Select-String -Pattern 'started|restart|pair|pairing|失效|invalid' | Select-Object -Last 25)
    $logLines | Set-Content -LiteralPath (Join-Path $caseDir 'daemon-log-window.txt') -Encoding UTF8
    $logText = ($logLines -join "`n")
    if ($phoneText -match '电脑端服务重启了' -and $logText -match 'started|restart|pair|invalid') {
        Finish 'PASS' 'phone shows service-restarted text; daemon log has a start/pairing line'
    } else {
        Finish 'FAIL' "phone=$phoneText logmatched=$($logText -match 'started|restart|pair|invalid')"
    }
}
