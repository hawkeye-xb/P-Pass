#Requires -Version 5.1
# 1063-admin-w4.ps1 - The one elevated process for the #1063 Windows rerun.
#
# It is launched once by a human approving one UAC prompt (1063-admin-launch.ps1):
#   Start-Process powershell -Verb RunAs -ArgumentList `
#     '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ...\1063-admin-w4.ps1'
#
# STEP A: create a one-shot SYSTEM task (schtasks /RU SYSTEM) that runs
#         1063-system-cleanup.ps1: sc stop + sc delete for the #1161 services
#         P-Pass and PPassPocSvc, then remove C:\ProgramData\P-Pass with a
#         takeown/icacls fallback. Wait for DONE, then delete that task.
# STEP B: sample `powercfg /requests` every 2 s for 15 minutes into
#         W4\powercfg-requests-2.txt. The script does not return until the
#         whole sample is written; the launcher also waits for ELEVATED DONE.
#
# Log: C:\Users\ethan\ppcheck\1063-test10\admin-once\run2.log
param(
    [string]$WorkRoot = 'C:\Users\ethan\ppcheck\1063-test10',
    [string]$CleanupTaskName = 'PPass1063Cleanup',
    [string]$W4File = 'C:\Users\ethan\ppcheck\1063-test10\W4\powercfg-requests-2.txt',
    [int]$W4Minutes = 15,
    [int]$SampleSeconds = 2
)

$ErrorActionPreference = 'Continue'
$logDir = Join-Path $WorkRoot 'admin-once'
$logPath = Join-Path $logDir 'run2.log'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $W4File) | Out-Null

if (Test-Path -LiteralPath $logPath) {
    try {
        Move-Item -LiteralPath $logPath -Destination (Join-Path $logDir ("run2.prev-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Force -ErrorAction Stop
    } catch { }
}

$script:lines = New-Object System.Collections.Generic.List[string]
function Log([string]$msg) {
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg
    $script:lines.Add($line)
    try { [IO.File]::AppendAllText($logPath, $line + "`r`n", (New-Object Text.UTF8Encoding($false))) } catch { }
    Write-Output $line
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$startLine = 'ELEVATED START {0} user={1} admin={2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $identity.Name, $isAdmin
[IO.File]::WriteAllText($logPath, $startLine + "`r`n", (New-Object Text.UTF8Encoding($false)))
Write-Output $startLine

if (-not $isAdmin) {
    Log 'ERROR: this process is NOT elevated; no cleanup and no sample performed.'
    Log 'ELEVATED DONE'
    exit 1
}

# --- STEP A: SYSTEM one-shot cleanup -----------------------------------------
Log '=== STEP A: #1161 residue cleanup via one-shot SYSTEM task ==='
$cleanupScript = Join-Path $PSScriptRoot '1063-system-cleanup.ps1'
$cleanupLog = Join-Path $logDir 'system-cleanup.log'
$wrapper = Join-Path $logDir 'cleanup-task.cmd'
if (-not (Test-Path -LiteralPath $cleanupScript)) {
    Log "ERROR: missing $cleanupScript"
} else {
    $cmd = '@echo off' + "`r`n" + ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $cleanupScript) + "`r`n"
    [IO.File]::WriteAllText($wrapper, $cmd, (New-Object System.Text.ASCIIEncoding))

    if (Test-Path -LiteralPath $cleanupLog) { Remove-Item -LiteralPath $cleanupLog -Force -ErrorAction SilentlyContinue }
    $st = (Get-Date).AddMinutes(5).ToString('HH:mm')
    $create = & schtasks.exe /create /tn $CleanupTaskName /ru SYSTEM /rl HIGHEST /sc ONCE /st $st /tr $wrapper /f 2>&1
    Log ("schtasks /create -> exit {0}: {1}" -f $LASTEXITCODE, (($create | Out-String).Trim()))
    if ($LASTEXITCODE -eq 0) {
        $run = & schtasks.exe /run /tn $CleanupTaskName 2>&1
        Log ("schtasks /run -> exit {0}: {1}" -f $LASTEXITCODE, (($run | Out-String).Trim()))

        $deadline = (Get-Date).AddSeconds(180)
        $done = $false
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $cleanupLog) {
                $txt = Get-Content -LiteralPath $cleanupLog -Raw -Encoding UTF8
                if ($txt -match '(?m)^\[.*\] DONE\s*$') { $done = $true; break }
            }
            Start-Sleep -Milliseconds 500
        }
        Log ("system task done={0} elapsed-wait-finished={1}" -f $done, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        if (Test-Path -LiteralPath $cleanupLog) {
            Log '--- system-cleanup.log ---'
            foreach ($line in (Get-Content -LiteralPath $cleanupLog -Encoding UTF8)) { Log "  $line" }
            $txt = Get-Content -LiteralPath $cleanupLog -Raw -Encoding UTF8
            if ($txt -notmatch 'RESULT=PASS') { Log '[WARN] system cleanup did not report PASS' }
        } else {
            Log '[FAIL] system-cleanup.log was not created'
        }

        $del = & schtasks.exe /delete /tn $CleanupTaskName /f 2>&1
        Log ("schtasks /delete -> exit {0}: {1}" -f $LASTEXITCODE, (($del | Out-String).Trim()))
    } else {
        Log '[FAIL] could not create the SYSTEM cleanup task'
    }
}
Log '=== STEP A DONE ==='

# --- STEP B: W4 sampling ------------------------------------------------------
Log '=== STEP B: W4 powercfg /requests sampling (15 min, every 2 s) ==='
if (Test-Path -LiteralPath $W4File) { Remove-Item -LiteralPath $W4File -Force -ErrorAction SilentlyContinue }
$sampleStart = Get-Date
$deadline = $sampleStart.AddMinutes($W4Minutes)
$nextTick = $sampleStart
$sampleCount = 0
Log ("[W4] start={0} file={1}" -f $sampleStart.ToString('yyyy-MM-dd HH:mm:ss'), $W4File)

$writer = New-Object System.IO.StreamWriter($W4File, $false, (New-Object Text.UTF8Encoding($false)))
try {
    while ((Get-Date) -lt $deadline) {
        $ts = Get-Date
        $req = & powercfg.exe /requests 2>&1
        $body = (($req | Out-String).TrimEnd())
        $writer.WriteLine(("=== {0} ===" -f $ts.ToString('yyyy-MM-dd HH:mm:ss.fff')))
        $writer.WriteLine($body)
        $writer.WriteLine('')
        $writer.Flush()
        $sampleCount++

        $nextTick = $nextTick.AddSeconds($SampleSeconds)
        $waitMs = [int](($nextTick - (Get-Date)).TotalMilliseconds)
        if ($waitMs -gt 0) { Start-Sleep -Milliseconds $waitMs }
    }
} catch {
    Log ("[W4][FAIL] {0}" -f $_.Exception.Message)
} finally {
    try { $writer.Close() } catch { }
}

$elapsed = [int]((Get-Date) - $sampleStart).TotalSeconds
Log ("[W4] done: samples={0} elapsed={1}s file={2}" -f $sampleCount, $elapsed, $W4File)
Log '=== STEP B DONE ==='
Log 'ELEVATED DONE'
exit 0
