#Requires -Version 5.1
# 1063-desktop-wizard.ps1 - Walk the Windows first-run wizard (3 steps:
# library -> sleep note -> resident service) with UIA. If the app is already on
# the main page, this is a no-op PASS (useful for re-runs).
#
# Evidence: %USERPROFILE%\ppcheck\1063-test10\R0.3\wizard.txt + uia-*.txt
param(
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10')
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot 'R0.3'
New-Item -ItemType Directory -Force $caseDir | Out-Null
$log = Join-Path $caseDir 'wizard.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
$uia = Join-Path $PSScriptRoot 'uia-drive.ps1'

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
function Invoke-Uia {
    param([string]$Action, [string]$Name = '', [string]$OutName = 'uia.txt')
    $outPath = Join-Path $caseDir $OutName
    $uiaArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $uia, '-Action', $Action, '-Out', $outPath)
    if ($Name -ne '') { $uiaArgs += @('-Name', $Name) }
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
function Get-UiText {
    param([string]$OutName = 'uia.txt')
    $r = Invoke-Uia -Action dump -OutName $OutName
    if ($r.Code -ne 0) { throw "uia dump failed: $($r.Output)" }
    return (Get-Content -LiteralPath $r.Path -Raw -Encoding UTF8)
}
function Wait-UiText {
    param([string]$Text, [int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $txt = Get-UiText
            if ($txt -like "*$Text*") { return $true }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Click-Ui {
    param([string]$Name, [int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Uia -Action click -Name $Name -OutName ('click-' + ($Name -replace '[^\w]', '_') + '.txt')
        if ($r.Code -eq 0) {
            Log "clicked: $Name"
            Start-Sleep -Milliseconds 800
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

Log "=== #1063 desktop wizard $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
if (-not (Get-Process -Name 'p-pass-desktop' -ErrorAction SilentlyContinue)) {
    Finish $false "p-pass-desktop is not running"
}

$txt = Get-UiText -OutName 'uia-initial.txt'
if ($txt -like '*添加设备*') {
    Log '[SKIP] already on the main page'
} else {
    # A first launch may offer an update; the baseline must cancel it.
    if ($txt -like '*发现新版本*' -or $txt -like '*取消*') {
        if (Click-Ui -Name '取消' -TimeoutSeconds 10) { Log '[SKIP] update prompt cancelled' }
    }
    for ($i = 1; $i -le 2; $i++) {
        if (-not (Click-Ui -Name '继续' -TimeoutSeconds 30)) {
            Get-UiText -OutName ("uia-no-continue-{0}.txt" -f $i) | Out-Null
            Finish $false "Continue button not found on wizard step $i"
        }
        Start-Sleep -Milliseconds 800
        Get-UiText -OutName ("uia-after-continue-{0}.txt" -f $i) | Out-Null
    }
    if (-not (Click-Ui -Name '完成' -TimeoutSeconds 30)) {
        Get-UiText -OutName 'uia-no-finish.txt' | Out-Null
        Finish $false "Finish button not found"
    }
    if (-not (Wait-UiText -Text '添加设备' -TimeoutSeconds 45)) {
        Get-UiText -OutName 'uia-no-main.txt' | Out-Null
        Finish $false "main page did not appear after Finish"
    }
}

Start-Sleep -Seconds 2
$final = Get-UiText -OutName 'uia-final.txt'
$daemon = Get-Process -Name 'ppf-daemon' -ErrorAction SilentlyContinue | Select-Object -First 1
$task = Get-ScheduledTask -TaskName 'P-Pass' -ErrorAction SilentlyContinue
if (-not $daemon) { Finish $false "ppf-daemon is not running after wizard" }
if (-not $task) { Finish $false "scheduled task P-Pass is missing after wizard" }
Log "ppf-daemon pid=$($daemon.Id) task=$($task.State)"
if ($final -notmatch '添加设备') { Finish $false "main page text not visible" }
Finish $true "wizard complete; main page and resident service are up"
