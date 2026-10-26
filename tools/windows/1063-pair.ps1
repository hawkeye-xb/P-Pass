#Requires -Version 5.1
# 1063-pair.ps1 - Pair the Windows desktop test.10 with the Android test.10
# using the manual pairing string (#1118 flow).
#
# Desktop side: UIA (uia-drive.ps1) reads the pending request and types the
# 6-digit code shown by the phone, then clicks Allow.
# Phone side: adb + uiautomator dump, no screen recording, no app data edits
# beyond the pairing itself.
#
# The pairing string is short-lived secret. It stays in memory; evidence only
# records its shape and the redacted UI dumps (<PAIRING_STRING>).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\1063-pair.ps1
param(
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10')
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot 'R0.4'
New-Item -ItemType Directory -Force $caseDir | Out-Null
$log = Join-Path $caseDir 'pairing.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
$script:pairingString = ''
$adb = (Get-Command adb -ErrorAction Stop).Source
$uia = Join-Path $PSScriptRoot 'uia-drive.ps1'
$pairStart = Join-Path $PSScriptRoot '1063-pair-start.sh'
$devicesScript = Join-Path $PSScriptRoot '1063-ipc-devices.sh'
$bash = 'C:\Program Files\Git\bin\bash.exe'

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

function Get-PairedDevices {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $bash $devicesScript 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($code -ne 0) { return @() }
    try {
        $j = (($out | Out-String).Trim()) | ConvertFrom-Json
        return @($j.result.devices)
    } catch {
        return @()
    }
}

function Save-PairedDevices {
    param($Devices)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("timestamp=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    foreach ($d in @($Devices)) {
        $prefix = ''
        if ($d.node_id) { $prefix = ([string]$d.node_id).Substring(0, [Math]::Min(8, ([string]$d.node_id).Length)) }
        $lines.Add("name=$($d.name) node_prefix=$prefix paired=$($d.paired) presence=$($d.presence) connection=$($d.connection)")
    }
    [IO.File]::WriteAllLines((Join-Path $caseDir 'paired-devices.txt'), $lines, (New-Object Text.UTF8Encoding($false)))
}

function Get-PhoneUi {
    param([string]$EvidenceName = '')
    $dump = Invoke-Adb -AdbArgs @('shell', 'uiautomator', 'dump', '/sdcard/1063-ui.xml')
    $cat = Invoke-Adb -AdbArgs @('exec-out', 'cat', '/sdcard/1063-ui.xml')
    $raw = [string]$cat.Output
    if ($raw -notmatch '<hierarchy') {
        throw "uiautomator dump failed: $($dump.Output)"
    }
    if ($EvidenceName -ne '') {
        $safe = $raw
        if ($script:pairingString -ne '') { $safe = $safe.Replace($script:pairingString, '<PAIRING_STRING>') }
        [IO.File]::WriteAllText((Join-Path $caseDir $EvidenceName), $safe, (New-Object Text.UTF8Encoding($false)))
    }
    return $raw
}

function Get-PhoneNode {
    param([string]$Raw, [string]$Text = '', [string]$Class = '')
    [xml]$doc = $Raw
    foreach ($n in $doc.SelectNodes('//node')) {
        if ($Class -ne '' -and [string]$n.class -ne $Class) { continue }
        $t = [string]$n.text
        $d = [string]$n.'content-desc'
        if ($Text -eq '') { return $n }
        if ($t -eq $Text -or $d -eq $Text) { return $n }
    }
    foreach ($n in $doc.SelectNodes('//node')) {
        if ($Class -ne '' -and [string]$n.class -ne $Class) { continue }
        $t = [string]$n.text
        $d = [string]$n.'content-desc'
        if ($t -like "*$Text*" -or $d -like "*$Text*") { return $n }
    }
    return $null
}

function Get-NodeCenter {
    param($Node)
    $m = [regex]::Match([string]$Node.bounds, '\[(\d+),(\d+)\]\[(\d+),(\d+)\]')
    if (-not $m.Success) { return $null }
    return @{
        X = [int]( ([int]$m.Groups[1].Value + [int]$m.Groups[3].Value) / 2 )
        Y = [int]( ([int]$m.Groups[2].Value + [int]$m.Groups[4].Value) / 2 )
    }
}

function Tap-PhoneText {
    param([string]$Text, [string]$Class = '', [int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $raw = Get-PhoneUi
            $node = Get-PhoneNode -Raw $raw -Text $Text -Class $Class
            if ($node) {
                $c = Get-NodeCenter $node
                if ($c) {
                    & $adb shell input tap $c.X $c.Y | Out-Null
                    Log "tapped phone: $Text ($($c.X),$($c.Y))"
                    Start-Sleep -Milliseconds 500
                    return $true
                }
            }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Tap-PhoneEdit {
    param([int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $raw = Get-PhoneUi
            $node = Get-PhoneNode -Raw $raw -Class 'android.widget.EditText'
            if ($node) {
                $c = Get-NodeCenter $node
                if ($c) {
                    & $adb shell input tap $c.X $c.Y | Out-Null
                    Log "tapped phone input ($($c.X),$($c.Y))"
                    Start-Sleep -Milliseconds 300
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
        try {
            $raw = Get-PhoneUi
            if (Get-PhoneNode -Raw $raw -Text $Text) { return $true }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Get-PhonePairCode {
    param([int]$TimeoutSeconds = 45)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
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

function Invoke-Uia {
    param([string]$Action, [string]$Name = '', [string]$Value = '', [string]$OutName = 'uia.txt')
    $outPath = Join-Path $caseDir $OutName
    $uiaArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $uia, '-Action', $Action, '-Out', $outPath)
    if ($Name -ne '') { $uiaArgs += @('-Name', $Name) }
    if ($Value -ne '') { $uiaArgs += @('-Value', $Value) }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & powershell.exe @uiaArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    return [pscustomobject]@{ Code = $code; Output = (($out | Out-String).Trim()); Path = $outPath }
}

function Get-DesktopUi {
    param([string]$EvidenceName = 'uia.txt')
    $r = Invoke-Uia -Action dump -OutName $EvidenceName
    if ($r.Code -ne 0) { throw "uia dump failed: $($r.Output)" }
    return (Get-Content -LiteralPath $r.Path -Raw -Encoding UTF8)
}

function Wait-DesktopText {
    param([string]$Text, [int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $txt = Get-DesktopUi
            if ($txt -like "*$Text*") { return $true }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Click-Desktop {
    param([string]$Name, [int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Uia -Action click -Name $Name -OutName ('click-' + ($Name -replace '[^\w]', '_') + '.txt')
        if ($r.Code -eq 0) {
            Log "clicked desktop: $Name"
            Start-Sleep -Milliseconds 500
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

Log "=== #1063 pairing $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
$dev = Invoke-Adb -AdbArgs @('devices', '-l')
Log $dev.Output
$deviceLines = @($dev.Output -split "`r?`n" | Where-Object { $_ -match '^\S+\s+device\b' })
if ($deviceLines.Count -ne 1) { Finish $false "expected one authorized Android device" }
$serial = ($deviceLines[0] -split '\s+')[0]
Log "PhoneSerial=$serial"

$desktop = Get-Process -Name 'p-pass-desktop' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $desktop) { Finish $false "p-pass-desktop is not running" }

# Bring the app to the foreground. If the daemon already has a paired device
# and the phone is past the welcome screen, this is a re-run: verify and PASS
# instead of silently unpairing the shared test phone.
$launch = Invoke-Adb -AdbArgs @('-s', $serial, 'shell', 'monkey', '-p', 'com.hawkeyexb.ppass', '-c', 'android.intent.category.LAUNCHER', '1')
Log 'Launched phone app'
Start-Sleep -Seconds 2
$phoneUi = Get-PhoneUi -EvidenceName 'phone-welcome.xml'
$pairedAtStart = @(Get-PairedDevices)
$pairedDevAtStart = $pairedAtStart | Where-Object { $_.paired -eq $true } | Select-Object -First 1
if ($pairedDevAtStart -and $phoneUi -notmatch '无法扫码|扫码连接家里的电脑') {
    Save-PairedDevices -Devices $pairedAtStart
    Log "AlreadyPaired=$($pairedDevAtStart.name) presence=$($pairedDevAtStart.presence)"
    Finish $true "already paired with $($pairedDevAtStart.name)"
}

if ($phoneUi -match '重新扫码') {
    Tap-PhoneText -Text '重新扫码' | Out-Null
    Start-Sleep -Milliseconds 800
    $phoneUi = Get-PhoneUi
}
$alreadyOnInput = ($phoneUi -match 'text="输入配对串"' -or $phoneUi -match 'ppf://pair\?node')
if (-not $alreadyOnInput) {
    if (-not (Wait-PhoneText -Text '无法扫码？手动输入配对串' -TimeoutSeconds 15)) {
        # Some builds land on the scan screen first; the manual link is there too.
        if (Wait-PhoneText -Text '扫码连接家里的电脑' -TimeoutSeconds 5) {
            Tap-PhoneText -Text '扫码连接家里的电脑' | Out-Null
            Start-Sleep -Milliseconds 800
        }
    }
    if (-not (Tap-PhoneText -Text '无法扫码？手动输入配对串' -TimeoutSeconds 20)) {
        Get-PhoneUi -EvidenceName 'phone-no-manual-link.xml' | Out-Null
        Finish $false "could not find the manual pairing link"
    }
    if (-not (Wait-PhoneText -Text 'ppf://pair?node' -TimeoutSeconds 15)) {
        Get-PhoneUi -EvidenceName 'phone-no-input-screen.xml' | Out-Null
        Finish $false "manual pairing input screen did not appear"
    }
}

if (-not (Wait-DesktopText -Text '添加设备' -TimeoutSeconds 15)) {
    Get-DesktopUi -EvidenceName 'desktop-no-main.xml' | Out-Null
    Finish $false "desktop main page not visible"
}

Log 'Requesting a fresh pairing string via daemon IPC (kept in memory only)'
$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $pairOut = & $bash $pairStart 2>&1; $pairCode = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
if ($pairCode -ne 0) { Finish $false "pair-start helper exit ${pairCode}: $((($pairOut | Out-String).Trim()))" }
$pairJson = (($pairOut | Out-String).Trim()) | ConvertFrom-Json
$qr = $pairJson.result.qr
if (-not $qr -or -not $qr.StartsWith('ppf://pair?')) {
    Finish $false "daemon did not return a ppf://pair string"
}
$script:pairingString = $qr
Log "PairingStringLength=$($qr.Length) (content not persisted)"

if (-not (Tap-PhoneEdit -TimeoutSeconds 10)) {
    Get-PhoneUi -EvidenceName 'phone-no-edit.xml' | Out-Null
    Finish $false "pairing string input field not found"
}
$escaped = $qr.Replace("'", "'\''")
$typed = Invoke-Adb -AdbArgs @('shell', "input text '$escaped'")
Log "input text exit=$($typed.Code) $($typed.Output)"
& $adb shell input keyevent 4 | Out-Null
Start-Sleep -Milliseconds 500
Get-PhoneUi -EvidenceName 'phone-filled.xml' | Out-Null

if (-not (Tap-PhoneText -Text '连接' -TimeoutSeconds 15)) {
    Get-PhoneUi -EvidenceName 'phone-no-connect-button.xml' | Out-Null
    Finish $false "could not click Connect"
}

$code = Get-PhonePairCode -TimeoutSeconds 45
if (-not $code) {
    Get-PhoneUi -EvidenceName 'phone-no-code.xml' | Out-Null
    Finish $false "phone did not show a 6-digit pairing code"
}
Log "PhonePairCode=present (6 digits)"
[IO.File]::WriteAllText((Join-Path $caseDir 'phone-code.txt'), "code_present=true`ntimestamp=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n", (New-Object Text.UTF8Encoding($false)))

if (-not (Wait-DesktopText -Text '6 位验证码' -TimeoutSeconds 45)) {
    # The dialog may use the reconnect wording; either way the code input exists.
    if (-not (Wait-DesktopText -Text '允许加入' -TimeoutSeconds 5)) {
        Get-DesktopUi -EvidenceName 'desktop-no-pending.xml' | Out-Null
        Finish $false "desktop pending-request dialog did not appear"
    }
}
$typedDesktop = Invoke-Uia -Action settext -Name '6 位验证码' -Value $code -OutName 'uia-code-set.txt'
Log "desktop code set exit=$($typedDesktop.Code): $($typedDesktop.Output)"
if ($typedDesktop.Code -ne 0) {
    Get-DesktopUi -EvidenceName 'desktop-code-type-failed.xml' | Out-Null
    Finish $false "could not set the pairing code on the desktop"
}
Start-Sleep -Milliseconds 500
Get-DesktopUi -EvidenceName 'desktop-code-filled.xml' | Out-Null

if (-not (Click-Desktop -Name '允许加入' -TimeoutSeconds 10)) {
    if (-not (Click-Desktop -Name '允许重连' -TimeoutSeconds 10)) {
        Get-DesktopUi -EvidenceName 'desktop-no-allow.xml' | Out-Null
        Finish $false "could not click Allow on the desktop"
    }
}

$pairOk = Wait-PhoneText -Text '选择要备份的相册' -TimeoutSeconds 45
$desktopTxt = Get-DesktopUi -EvidenceName 'desktop-after-pair.xml'
Get-PhoneUi -EvidenceName 'phone-after-pair.xml' | Out-Null

$pairedDev = $null
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    $pairedNow = @(Get-PairedDevices)
    $pairedDev = $pairedNow | Where-Object { $_.paired -eq $true } | Select-Object -First 1
    if ($pairedDev) {
        Save-PairedDevices -Devices $pairedNow
        break
    }
    Start-Sleep -Milliseconds 500
}

if (-not $pairOk) { Finish $false "phone did not reach the album picker after Allow" }
if (-not $pairedDev) { Finish $false "daemon devices.list has no paired device" }
Finish $true "paired with $($pairedDev.name); phone reached album picker"
