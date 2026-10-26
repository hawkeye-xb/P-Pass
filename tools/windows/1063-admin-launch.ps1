#Requires -Version 5.1
# 1063-admin-launch.ps1 - Trigger the single UAC prompt for 1063-admin-w4.ps1,
# then stay in this process until that elevated run writes ELEVATED DONE.
#
# This wrapper exists so an outer caller cannot mistake "UAC accepted" for
# "sampling finished": it only returns after the 15-minute sample is complete.
#
# Usage: run it as a background job, e.g. from the agent's shell, and poll
#   C:\Users\ethan\ppcheck\1063-test10\admin-once\launcher.log
#   C:\Users\ethan\ppcheck\1063-test10\admin-once\run2.log
param(
    [string]$WorkRoot = 'C:\Users\ethan\ppcheck\1063-test10',
    [int]$TimeoutSeconds = 1500
)

$ErrorActionPreference = 'Stop'
$admin = Join-Path $PSScriptRoot '1063-admin-w4.ps1'
$logDir = Join-Path $WorkRoot 'admin-once'
$runLog = Join-Path $logDir 'run2.log'
$launchLog = Join-Path $logDir 'launcher.log'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$lines = New-Object System.Collections.Generic.List[string]
function Log([string]$msg) {
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg
    $lines.Add($line)
    Write-Output $line
    [IO.File]::WriteAllLines($launchLog, $lines, (New-Object Text.UTF8Encoding($false)))
}

if (-not (Test-Path -LiteralPath $admin)) {
    Log "FAIL: missing $admin"
    exit 1
}

Log "launching elevated: $admin"
try {
    $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $admin
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arg -ErrorAction Stop
    Log 'UAC accepted / elevated process started'
} catch {
    Log "FAIL: UAC launch failed: $($_.Exception.Message)"
    exit 1
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$lastLen = -1
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $runLog) {
        $txt = Get-Content -LiteralPath $runLog -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($txt) {
            if ($txt.Length -ne $lastLen) {
                $lastLen = $txt.Length
                Log ("run2.log bytes={0}" -f $txt.Length)
            }
            if ($txt -match 'ELEVATED DONE') {
                Log 'ELEVATED DONE seen; sampling finished'
                exit 0
            }
            if ($txt -match 'ERROR: this process is NOT elevated') {
                Log 'FAIL: elevated process reported not elevated'
                exit 1
            }
        }
    }
    Start-Sleep -Seconds 2
}

Log ("FAIL: timeout after {0}s without ELEVATED DONE" -f $TimeoutSeconds)
exit 1
