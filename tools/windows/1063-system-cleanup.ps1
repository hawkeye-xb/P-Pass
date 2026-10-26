#Requires -Version 5.1
# 1063-system-cleanup.ps1 - Run as SYSTEM by 1063-admin-once.ps1.
#
# Removes the #1161 Windows service residue that an Administrator token cannot
# touch: the two legacy services and C:\ProgramData\P-Pass (owned by SYSTEM).
# The caller creates a one-shot SYSTEM task, runs it, waits for "DONE", then
# deletes the task.
#
# Log: C:\Users\ethan\ppcheck\1063-test10\admin-once\system-cleanup.log
param(
    [string]$LogPath = 'C:\Users\ethan\ppcheck\1063-test10\admin-once\system-cleanup.log',
    [string[]]$ServiceNames = @('P-Pass', 'PPassPocSvc'),
    [string]$ProgramDataRoot = 'C:\ProgramData\P-Pass'
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
$script:lines = New-Object System.Collections.Generic.List[string]

function Log([string]$msg) {
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg
    $script:lines.Add($line)
    Write-Output $line
}
function Save-Log {
    [IO.File]::WriteAllLines($LogPath, $script:lines, (New-Object Text.UTF8Encoding($false)))
}
function Invoke-Sc {
    param([string[]]$ScArgs)
    $out = & sc.exe @ScArgs 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = (($out | Out-String).Trim()) }
}

$who = ''
try { $who = ((& whoami.exe 2>&1) | Out-String).Trim() } catch { }
Log ("START user={0} elevated={1}" -f $who, ([Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)))

$ok = $true
foreach ($name in $ServiceNames) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Log "[SERVICE] $name : not installed -> SKIP"
        continue
    }
    Log "[SERVICE] $name : status=$($svc.Status) startType=$($svc.StartType)"

    $r = Invoke-Sc -ScArgs @('stop', $name)
    Log ("  sc stop {0} -> exit {1}{2}" -f $name, $r.Code, $(if ($r.Output) { ': ' + $r.Output } else { '' }))
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $s = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $s -or $s.Status -eq 'Stopped') { break }
        Start-Sleep -Milliseconds 500
    }

    $r = Invoke-Sc -ScArgs @('delete', $name)
    Log ("  sc delete {0} -> exit {1}{2}" -f $name, $r.Code, $(if ($r.Output) { ': ' + $r.Output } else { '' }))
    if ($r.Code -ne 0) {
        # #1161's sc sdset left some principals without DELETE; grant SYSTEM and
        # Administrators full control once, then retry.
        $sddl = 'D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWRPWPDTLOCRRC;;;IU)'
        $d = Invoke-Sc -ScArgs @('sdset', $name, $sddl)
        Log ("  [RETRY] sc sdset {0} -> exit {1}" -f $name, $d.Code)
        if ($d.Output) { Log "    $($d.Output)" }
        $r = Invoke-Sc -ScArgs @('delete', $name)
        Log ("  sc delete {0} (retry) -> exit {1}{2}" -f $name, $r.Code, $(if ($r.Output) { ': ' + $r.Output } else { '' }))
    }

    Start-Sleep -Milliseconds 500
    $still = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($still) {
        Log "  [FAIL] service $name still present (status $($still.Status))"
        $ok = $false
    } else {
        Log "  [DELETED] service $name (verified absent)"
    }
    $reg = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
    if (Test-Path -LiteralPath $reg) {
        Log "  [FAIL] registry key still present: $reg"
        $ok = $false
    } else {
        Log "  [OK] registry key absent: $reg"
    }
}

if (-not (Test-Path -LiteralPath $ProgramDataRoot)) {
    Log "[DIR] $ProgramDataRoot : absent -> SKIP"
} else {
    try {
        Remove-Item -LiteralPath $ProgramDataRoot -Recurse -Force -ErrorAction Stop
        Log "[DIR] removed with Remove-Item"
    } catch {
        Log "[DIR] Remove-Item failed: $($_.Exception.Message)"
        Log "[DIR] takeown + icacls fallback"
        $t = & takeown.exe /f $ProgramDataRoot /r /d y 2>&1
        Log ("  takeown exit={0}" -f $LASTEXITCODE)
        foreach ($l in @($t)) { if ([string]$l.Trim()) { Log "    $l" } }
        $i = & icacls.exe $ProgramDataRoot /grant 'Administrators:F' /t 2>&1
        Log ("  icacls exit={0}" -f $LASTEXITCODE)
        foreach ($l in @($i)) { if ([string]$l.Trim()) { Log "    $l" } }
        try {
            Remove-Item -LiteralPath $ProgramDataRoot -Recurse -Force -ErrorAction Stop
            Log "[DIR] removed after takeown/icacls"
        } catch {
            Log "[DIR] still failed: $($_.Exception.Message)"
        }
    }
    if (Test-Path -LiteralPath $ProgramDataRoot) {
        Log "[DIR][FAIL] $ProgramDataRoot still present"
        $ok = $false
    } else {
        Log "[DIR][OK] $ProgramDataRoot verified absent"
    }
}

Log 'DONE'
if ($ok) { Log 'RESULT=PASS' } else { Log 'RESULT=FAIL' }
Save-Log
if ($ok) { exit 0 } else { exit 1 }
