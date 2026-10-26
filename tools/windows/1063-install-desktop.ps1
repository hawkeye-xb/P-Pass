#Requires -Version 5.1
# 1063-install-desktop.ps1 - Install the Windows test.10 build silently, then
# start the desktop shell once. Evidence goes to
#   %USERPROFILE%\ppcheck\1063-test10\R0.2\
#
# Uses run-outside-package.ps1 for the installer (SOP §9.0: installers launched
# from an MSIX host inherit HKCU/file virtualization). The app itself is started
# via Win32_Process.Create, not through that wrapper (its shared out.txt would be
# held open by a long-lived app; SOP §9.0).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\1063-install-desktop.ps1 `
#     -Setup C:\Users\ethan\ppcheck\1063-test10\assets\P-Pass_0.10.0-test.10_x64-setup.exe
param(
    [Parameter(Mandatory = $true)][string]$Setup,
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [int]$InstallTimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot 'R0.2'
New-Item -ItemType Directory -Force $caseDir | Out-Null
$log = Join-Path $caseDir 'install-desktop.txt'
$script:lines = New-Object System.Collections.Generic.List[string]

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

Log "=== #1063 desktop install $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Log "Setup=$Setup"
if (-not (Test-Path -LiteralPath $Setup)) {
    Finish $false "setup not found: $Setup"
}
$hash = (Get-FileHash -LiteralPath $Setup -Algorithm SHA256).Hash.ToLowerInvariant()
Log "SetupSha256=$hash"
Log ""

$wrapper = Join-Path $PSScriptRoot 'run-outside-package.ps1'
if (-not (Test-Path -LiteralPath $wrapper)) {
    Finish $false "run-outside-package.ps1 not found"
}

Log '[INSTALL] running NSIS silently outside the MSIX package context'
$installCmd = '"{0}" /S' -f $Setup
$installOut = & $wrapper -Cmd $installCmd -Wait $InstallTimeoutSeconds 2>&1
$wrapperExit = $null
foreach ($line in @($installOut)) {
    Log ([string]$line)
    if ([string]$line -match '^\[exit (\d+)\]') { $wrapperExit = [int]$Matches[1] }
}
if ($null -eq $wrapperExit) {
    Finish $false "installer wrapper produced no exit marker"
}
if ($wrapperExit -ne 0) {
    Finish $false "installer wrapper exit $wrapperExit"
}

$exe = Join-Path $env:LOCALAPPDATA 'P-Pass\p-pass-desktop.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    Finish $false "install dir missing after installer: $exe"
}
$version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
Log "InstalledExe=$exe"
Log "ProductVersion=$version"

$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass'
$display = $null
try { $display = (Get-ItemProperty -Path $uninstallKey -ErrorAction Stop).DisplayVersion } catch { }
Log "DisplayVersion=$display"

Log ''
Log '[START] launching p-pass-desktop.exe via Win32_Process.Create'
$startCmd = 'cmd.exe /c start "" "{0}"' -f $exe
$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $startCmd }
if ($r.ReturnValue -ne 0) {
    Finish $false "Win32_Process.Create returned $($r.ReturnValue)"
}

$deadline = (Get-Date).AddSeconds(60)
$proc = $null
while ((Get-Date) -lt $deadline) {
    $proc = Get-Process -Name 'p-pass-desktop' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $proc) {
    Finish $false "p-pass-desktop did not start within 60s"
}
Log "ProcessId=$($proc.Id) StartTime=$($proc.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"

$expected = '0.10.0-test.10'
if ($version -ne $expected) {
    Finish $false "ProductVersion $version != $expected"
}
if ($display -ne $expected) {
    Finish $false "DisplayVersion $display != $expected"
}
Finish $true "test.10 installed and started (version $version)"
