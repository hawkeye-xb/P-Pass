#Requires -Version 5.1
# 1063-r64-smartscreen.ps1 - R6.4: prove SmartScreen gates a browser-downloaded
# test.10 installer, then finish the interactive NSIS wizard.
#
# The release is a draft, so an anonymous browser download is impossible. We
# reproduce the browser case with the standard Mark-of-the-Web: copy the asset
# to Downloads and write the Zone.Identifier ADS (ZoneId=3 + ReferrerUrl/HostUrl).
#
# The human only clicks SmartScreen ("更多信息 -> 仍要运行"). Everything else is
# automated: NSIS pages are classic #32770 dialogs that do not expose a UIA tree
# here, so the wizard is driven by EnumChildWindows + WM_COMMAND/BM_CLICK
# (win32-windows.ps1). SmartScreen is detected with Get-Process/MainWindowTitle,
# because a UIA FindAll on the SmartScreen window blocks for the whole prompt.
#
# Evidence: %USERPROFILE%\ppcheck\1063-test10\R6.4\
#   result.txt, smartscreen-win32.txt, wizard-*.txt, motw.txt
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\1063-r64-smartscreen.ps1
param(
    [string]$Setup = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10\assets\P-Pass_0.10.0-test.10_x64-setup.exe'),
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [int]$SmartScreenTimeoutSeconds = 180,
    [int]$WizardTimeoutSeconds = 420
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot 'R6.4'
New-Item -ItemType Directory -Force $caseDir | Out-Null
$logPath = Join-Path $caseDir 'result.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
$win32 = Join-Path $PSScriptRoot 'win32-windows.ps1'
$downloads = Join-Path $env:USERPROFILE 'Downloads'
$setupDst = Join-Path $downloads 'P-Pass_0.10.0-test.10_x64-setup.exe'
$releaseUrl = 'https://github.com/hawkeye-xb/P-Pass/releases/download/v0.10.0-test.10/P-Pass_0.10.0-test.10_x64-setup.exe'
$installerName = 'P-Pass_0.10.0-test.10_x64-setup'

function Log([string]$msg) {
    [Console]::WriteLine($msg)
    $script:lines.Add($msg)
}
function Finish([string]$result, [string]$detail) {
    Log ''
    Log ("RESULT={0} {1}" -f $result, $detail)
    [IO.File]::WriteAllLines($logPath, $script:lines, (New-Object Text.UTF8Encoding($false)))
    if ($result -eq 'PASS') { exit 0 }
    if ($result -eq 'UNCOVERED') { exit 2 }
    exit 1
}
function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    return [pscustomobject]@{ Code = $code; Output = (($out | Out-String).Trim()) }
}
function Dump-Win32 {
    param([int]$ProcId, [string]$Out, [switch]$All)
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $win32, '-ProcId', [string]$ProcId, '-Out', $Out)
    if ($All) { $a += '-All' }
    return Invoke-Checked -Exe 'powershell.exe' -Arguments $a
}
function Click-Win32 {
    param([int]$ProcId, [string]$Text)
    $out = Join-Path $caseDir ('click-' + ($Text -replace '[^\w]', '_') + '.txt')
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $win32,
        '-ProcId', [string]$ProcId, '-Click', $Text, '-Out', $out, '-All')
    return Invoke-Checked -Exe 'powershell.exe' -Arguments $a
}
function Get-InstallerPid {
    $p = Get-CimInstance Win32_Process -Filter ("Name='{0}.exe'" -f $installerName) -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($p) { return [int]$p.ProcessId }
    return 0
}
function Set-PpassTask([string]$State) {
    $r = & schtasks.exe /change /tn 'P-Pass' /$State 2>&1
    Log ("schtasks /change /{0} -> exit {1}: {2}" -f $State, $LASTEXITCODE, (($r | Out-String).Trim()))
}

Log "=== #1063 R6.4 SmartScreen $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Log "Setup=$Setup"
if (-not (Test-Path -LiteralPath $Setup)) { Finish 'FAIL' "setup not found: $Setup" }
$srcHash = (Get-FileHash -LiteralPath $Setup -Algorithm SHA256).Hash.ToLowerInvariant()
Log "SourceSha256=$srcHash"

# --- 1. Browser-equivalent copy + Mark-of-the-Web ------------------------------
if (-not (Test-Path -LiteralPath $downloads)) { New-Item -ItemType Directory -Force $downloads | Out-Null }
if (Test-Path -LiteralPath $setupDst) { Remove-Item -LiteralPath $setupDst -Force }
Copy-Item -LiteralPath $Setup -Destination $setupDst -Force
$dstHash = (Get-FileHash -LiteralPath $setupDst -Algorithm SHA256).Hash.ToLowerInvariant()
if ($srcHash -ne $dstHash) { Finish 'FAIL' 'copied setup hash mismatch' }
Log "DownloadsCopy=$setupDst"
Log "CopySha256=$dstHash"

$zone = @('[ZoneTransfer]', 'ZoneId=3', ("ReferrerUrl={0}" -f $releaseUrl), ("HostUrl={0}" -f $releaseUrl))
$zonePath = $setupDst + ':Zone.Identifier'
Set-Content -LiteralPath $zonePath -Value $zone -Encoding ASCII
$zoneBack = @(Get-Content -LiteralPath $zonePath -Encoding ASCII)
$motwOk = (($zoneBack -join "`n") -match 'ZoneId=3') -and (($zoneBack -join "`n") -match 'ReferrerUrl=https://github.com/')
Log '[MOTW]'
foreach ($z in $zoneBack) { Log "  $z" }
[IO.File]::WriteAllLines((Join-Path $caseDir 'motw.txt'), $zoneBack, (New-Object Text.UTF8Encoding($false)))
if (-not $motwOk) { Finish 'FAIL' 'Zone.Identifier ADS was not written correctly' }

# --- 2. Stop the app and its watchdog task so the installer can replace files -
Set-PpassTask 'disable'
Get-Process -Name 'p-pass-desktop', 'ppf-daemon' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
$exe = Join-Path $env:LOCALAPPDATA 'P-Pass\p-pass-desktop.exe'
$beforeWrite = if (Test-Path -LiteralPath $exe) { (Get-Item -LiteralPath $exe).LastWriteTime } else { [datetime]::MinValue }
Log "ExeBeforeWrite=$($beforeWrite.ToString('yyyy-MM-dd HH:mm:ss'))"

Log '[LAUNCH] explorer.exe <Downloads copy> (interactive, no /S)'
$launchAt = Get-Date
Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $setupDst)

# --- 3. Watch for SmartScreen with Get-Process (UIA blocks on this dialog) -----
$smartDeadline = (Get-Date).AddSeconds($SmartScreenTimeoutSeconds)
$smartSeen = $false
$smartText = ''
$smartDump = Join-Path $caseDir 'smartscreen-win32.txt'
$installerPid = 0
while ((Get-Date) -lt $smartDeadline) {
    $ss = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -ieq 'SmartScreen' -or $_.MainWindowTitle -match '保护你的电脑|Windows protected your PC|安全警告|Open File - Security'
        })
    if ($ss.Count -gt 0) {
        $smartSeen = $true
        $p = $ss[0]
        Log ("[SMARTSCREEN] process={0} pid={1} title='{2}' after {3:N1}s" -f $p.ProcessName, $p.Id, $p.MainWindowTitle, ((Get-Date) - $launchAt).TotalSeconds)
        Dump-Win32 -ProcId $p.Id -Out $smartDump -All | Out-Null
        if (Test-Path -LiteralPath $smartDump) { $smartText = Get-Content -LiteralPath $smartDump -Raw -Encoding UTF8 }
        $dismiss = (Get-Date).AddSeconds($SmartScreenTimeoutSeconds)
        while ((Get-Date) -lt $dismiss) {
            if (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 500
        }
        Log ("[SMARTSCREEN] dismissed after {0:N1}s" -f ((Get-Date) - $launchAt).TotalSeconds)
        break
    }
    $installerPid = Get-InstallerPid
    if ($installerPid -ne 0) { break }
    Start-Sleep -Milliseconds 300
}

if (-not $smartSeen) { Log ("[SMARTSCREEN] ABSENT: no dialog within {0}s" -f $SmartScreenTimeoutSeconds) }
if ($installerPid -eq 0) {
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        $installerPid = Get-InstallerPid
        if ($installerPid -ne 0) { break }
        Start-Sleep -Milliseconds 500
    }
}
if ($installerPid -eq 0) { Finish 'FAIL' 'installer process did not start' }
Log "InstallerPid=$installerPid StartedAfter=$([int]((Get-Date) - $launchAt).TotalSeconds)s"

# --- 4. Drive the NSIS wizard with Win32 messages ----------------------------
$wizardDeadline = (Get-Date).AddSeconds($WizardTimeoutSeconds)
$step = 0
while ((Get-Date) -lt $wizardDeadline) {
    if (-not (Get-Process -Id $installerPid -ErrorAction SilentlyContinue)) {
        Log '[WIZARD] installer process exited'
        break
    }
    $step++
    $pagePath = Join-Path $caseDir ('wizard-{0:d2}.txt' -f $step)
    $r = Dump-Win32 -ProcId $installerPid -Out $pagePath -All
    $text = if (Test-Path -LiteralPath $pagePath) { Get-Content -LiteralPath $pagePath -Raw -Encoding UTF8 } else { '' }
    if ($step -le 3 -or ($text -match '无法打开|重试|完成|正在安装')) {
        Log ("--- wizard step {0} ---" -f $step)
        foreach ($line in ($text -split "`r?`n")) {
            if ($line -match '^TOP\||CHILD\|.*(Button|Static)') { Log "  $line" }
        }
    }

    if ($text -match '无法打开要写入的文件' -or $text -match '重试\(&R\)') {
        Set-PpassTask 'disable'
        Get-Process -Name 'p-pass-desktop', 'ppf-daemon' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        if ((Click-Win32 -ProcId $installerPid -Text '重试').Code -eq 0) {
            Log 'clicked: 重试 after stopping the daemon'
            Start-Sleep -Seconds 1
            continue
        }
    }
    if ($text -match '完成\(&F\)' -or $text -match '安装程序成功完成安装') {
        if ((Click-Win32 -ProcId $installerPid -Text '完成').Code -eq 0) {
            Log 'clicked: 完成'
            Start-Sleep -Seconds 2
            continue
        }
    }
    if ($text -match '添加/重新安装组件') {
        Click-Win32 -ProcId $installerPid -Text '添加/重新安装组件' | Out-Null
        Start-Sleep -Milliseconds 400
        if ((Click-Win32 -ProcId $installerPid -Text '下一步').Code -eq 0) {
            Log 'clicked: 添加/重新安装组件 + 下一步'
            Start-Sleep -Seconds 1
            continue
        }
    }
    if ($text -match '我接受\(&I\)') {
        Click-Win32 -ProcId $installerPid -Text '我接受' | Out-Null
        Start-Sleep -Milliseconds 400
        if ((Click-Win32 -ProcId $installerPid -Text '下一步').Code -eq 0) {
            Log 'clicked: 我接受 + 下一步'
            Start-Sleep -Seconds 1
            continue
        }
    }
    if ($text -match '下一步\(&N\)') {
        if ((Click-Win32 -ProcId $installerPid -Text '下一步').Code -eq 0) {
            Log 'clicked: 下一步'
            Start-Sleep -Seconds 1
            continue
        }
    }
    if ($text -match '安装\(&I\)|开始安装') {
        if ((Click-Win32 -ProcId $installerPid -Text '安装').Code -eq 0) {
            Log 'clicked: 安装'
            Start-Sleep -Seconds 1
            continue
        }
    }
    Start-Sleep -Milliseconds 800
}
if (Get-Process -Id $installerPid -ErrorAction SilentlyContinue) {
    Finish 'FAIL' 'installer wizard did not finish within the timeout'
}

# --- 5. Restart the app and verify ------------------------------------------
Set-PpassTask 'enable'
& schtasks.exe /run /tn 'P-Pass' 2>&1 | Out-Null
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) {
    if (Get-Process -Name 'p-pass-desktop' -ErrorAction SilentlyContinue) { break }
    Start-Sleep -Milliseconds 500
}
if (-not (Get-Process -Name 'p-pass-desktop' -ErrorAction SilentlyContinue)) {
    Log '[START] installer did not launch the shell; starting it'
    $cmd = 'cmd.exe /c start "" "{0}"' -f $exe
    Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd } | Out-Null
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        if (Get-Process -Name 'p-pass-desktop' -ErrorAction SilentlyContinue) { break }
        Start-Sleep -Milliseconds 500
    }
}
Start-Sleep -Seconds 3

$version = ''
$display = ''
try { $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion } catch { }
try { $display = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass' -ErrorAction Stop).DisplayVersion } catch { }
$afterWrite = if (Test-Path -LiteralPath $exe) { (Get-Item -LiteralPath $exe).LastWriteTime } else { [datetime]::MinValue }
$daemon = Get-Process -Name 'ppf-daemon' -ErrorAction SilentlyContinue | Select-Object -First 1
$ipc = $null
try {
    $bash = 'C:\Program Files\Git\bin\bash.exe'
    $ipcScript = Join-Path $PSScriptRoot '1063-ipc-status.sh'
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $bash $ipcScript 2>&1
    $ErrorActionPreference = $old
    if ($LASTEXITCODE -eq 0) { $ipc = (($out | Out-String).Trim()) | ConvertFrom-Json }
} catch { }

Log ''
Log "ProductVersion=$version"
Log "DisplayVersion=$display"
Log "ExeBeforeWrite=$($beforeWrite.ToString('yyyy-MM-dd HH:mm:ss'))"
Log "ExeAfterWrite=$($afterWrite.ToString('yyyy-MM-dd HH:mm:ss'))"
if ($daemon) { Log "ppf-daemon pid=$($daemon.Id)" } else { Log 'ppf-daemon=MISSING' }
if ($ipc) {
    Log ("ipc state={0} version={1} paired_devices={2} devices={3} photo_count={4}" -f `
        $ipc.result.state, $ipc.result.version, $ipc.result.paired_devices, $ipc.result.devices, $ipc.result.photo_count)
} else {
    Log 'ipc=DOWN'
}

$installOk = ($version -eq '0.10.0-test.10') -and ($display -eq '0.10.0-test.10') -and
    ($null -ne $daemon) -and ($null -ne $ipc) -and ([int]$ipc.result.paired_devices -ge 1)
$smartCriterion = $smartSeen -and ($smartText -match '保护你的电脑|protected your PC')
if ($installOk -and $smartCriterion) {
    Finish 'PASS' 'SmartScreen shown and dismissed; test.10 installed; daemon up; pairing intact'
}
if ($installOk -and -not $smartCriterion) {
    Finish 'UNCOVERED' 'test.10 installed and pairing intact, but the SmartScreen dialog was not observed'
}
Finish 'FAIL' "install/verify failed (smartSeen=$smartSeen installOk=$installOk)"
