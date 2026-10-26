#Requires -Version 5.1
# reset-ppass-admin.ps1 - Finish the #1063 Windows cleanup that needs Administrator.
#
# The normal reset script (reset-ppass-env.ps1) deliberately never elevates. It
# leaves exactly the residuals that a non-admin token cannot remove:
#   - Windows services "P-Pass" and "PPassPocSvc" (the #1161 experiment)
#   - C:\ProgramData\P-Pass and C:\ProgramData\PPassPoc (protected DACLs)
#   - the 12 P-Pass/ppf-daemon Windows Firewall allow rules
#
# This script self-elevates with Start-Process -Verb RunAs, stops/deletes the
# services, removes the ProgramData roots and firewall rules, then asserts every
# item is gone. It writes a transcript to
#   %USERPROFILE%\ppcheck\1063-test10\admin-reset\reset-admin-<timestamp>.log
# so the result is still inspectable after the elevated window closes.
#
# The #1161 installer's sc sdset gave Interactive Users (and BA) stop/start but
# not DELETE. If a plain sc.exe delete is denied, this script repairs the
# service DACL to grant Administrators full control and retries the delete once.
# That is the only retry, and it is the reason this script exists.
#
# Human command (the only thing a person needs to run):
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\ethan\personal\P-Pass-1063\tools\windows\reset-ppass-admin.ps1
#
# Do NOT run this from an automated agent: it opens a UAC prompt. -Elevated and
# -LogPath are internal parameters used by the self-elevation hop.

param(
    [switch]$Elevated,
    [string]$LogPath = ""
)

$ErrorActionPreference = 'Stop'
$services = @('P-Pass', 'PPassPocSvc')
$programDataRoots = @(
    (Join-Path $env:ProgramData 'P-Pass'),
    (Join-Path $env:ProgramData 'PPassPoc')
)
$serviceKeys = @(
    'HKLM:\SYSTEM\CurrentControlSet\Services\P-Pass',
    'HKLM:\SYSTEM\CurrentControlSet\Services\PPassPocSvc'
)

if ($LogPath -eq '') {
    $logDir = Join-Path $env:USERPROFILE 'ppcheck\1063-test10\admin-reset'
    New-Item -ItemType Directory -Force $logDir | Out-Null
    $LogPath = Join-Path $logDir ('reset-admin-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Write-Log([string]$msg) { Write-Output $msg }

# --- Self-elevation hop -------------------------------------------------------
if (-not $Elevated) {
    $logDir = Split-Path -Parent $LogPath
    if ($logDir) { New-Item -ItemType Directory -Force $logDir | Out-Null }
    $scriptPath = $MyInvocation.MyCommand.Path
    $childArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $scriptPath),
        '-Elevated',
        '-LogPath', ('"{0}"' -f $LogPath)
    )
    Write-Log "Elevating for #1063 admin cleanup; log: $LogPath"
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $childArgs -Verb RunAs -Wait -PassThru
        exit $p.ExitCode
    } catch {
        $msg = "Elevation cancelled or failed: $($_.Exception.Message)"
        Write-Log $msg
        try { Add-Content -LiteralPath $LogPath -Value $msg -Encoding UTF8 } catch { }
        exit 1
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "ERROR: -Elevated was passed but the process is not an Administrator. No changes made."
    exit 1
}

$logDir = Split-Path -Parent $LogPath
if ($logDir) { New-Item -ItemType Directory -Force $logDir | Out-Null }
$transcriptStarted = $false
try {
    Start-Transcript -Path $LogPath -Append -Force | Out-Null
    $transcriptStarted = $true
} catch {
    Write-Log "WARN: could not start transcript ($LogPath): $($_.Exception.Message)"
}

$exitCode = 0
$residuals = New-Object System.Collections.Generic.List[string]

function Invoke-Sc {
    param([string[]]$ScArgs)
    $out = & sc.exe @ScArgs 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = (($out | Out-String).Trim()) }
}

function Wait-ServiceState {
    param([string]$Name, [string]$Wanted, [int]$TimeoutSeconds = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $svc) { return $true }
        if ($svc.Status -eq $Wanted) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Repair-ServiceDacl {
    param([string]$Name)
    # The installer's own DACL, plus DELETE/CHANGE_CONFIG for Administrators.
    # BA otherwise has only stop/start/query, which is why even an elevated
    # sc.exe delete can be denied after #1161's sdset.
    $sddl = 'D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWRPWPDTLOCRRC;;;IU)'
    $r = Invoke-Sc -ScArgs @('sdset', $Name, $sddl)
    if ($r.Code -eq 0) {
        Write-Log "  [OK] repaired service DACL for $Name"
    } else {
        Write-Log "  [WARN] could not repair service DACL for $Name (sc.exe exit $($r.Code)): $($r.Output)"
    }
}

function Stop-AndDeleteService {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "[SKIP] service not installed: $Name"
        return
    }
    Write-Log "[SERVICE] $Name (current: $($svc.Status), start: $($svc.StartType))"

    if ($svc.Status -ne 'Stopped') {
        $r = Invoke-Sc -ScArgs @('stop', $Name)
        Write-Log "  sc.exe stop $Name -> exit $($r.Code)"
        if ($r.Output) { Write-Log "  $($r.Output)" }
        if (-not (Wait-ServiceState -Name $Name -Wanted 'Stopped' -TimeoutSeconds 20)) {
            Write-Log "  [WARN] service $Name did not reach STOPPED"
        } else {
            Write-Log "  [STOPPED] $Name"
        }
    } else {
        Write-Log "  [SKIP] already stopped"
    }

    $r = Invoke-Sc -ScArgs @('delete', $Name)
    if ($r.Code -ne 0) {
        Write-Log "  [WARN] sc.exe delete $Name -> exit $($r.Code): $($r.Output)"
        Write-Log "  [INFO] retrying once after widening the service DACL"
        Repair-ServiceDacl -Name $Name
        $r = Invoke-Sc -ScArgs @('delete', $Name)
    }
    if ($r.Code -eq 0) {
        Write-Log "  [DELETED] $Name"
    } else {
        Write-Log "  [FAIL] sc.exe delete $Name -> exit $($r.Code): $($r.Output)"
    }

    # DeleteService only marks; wait briefly so the self-check does not race SCM.
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 250
    }
    $still = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($still) { Write-Log "  [PENDING] service $Name still visible (status $($still.Status))" }
}

function Remove-ProtectedPath {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "[SKIP] $Label not found: $Path"
        return
    }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Log "[REMOVED] $Label -> $Path"
    } catch {
        Write-Log "[FAIL] could not remove $Label ($Path): $($_.Exception.Message)"
    }
}

function Get-PPassFirewallRules {
    try {
        return @(Get-NetFirewallRule -ErrorAction Stop | Where-Object {
            $_.DisplayName -match '(?i)ppf-daemon|p-pass|ppass'
        })
    } catch {
        Write-Log "[WARN] could not query Windows Firewall rules: $($_.Exception.Message)"
        return @()
    }
}

Write-Log '=== #1063 P-Pass Administrator cleanup ==='
Write-Log "User: $($identity.Name)"
Write-Log "Log: $LogPath"
Write-Log ''

# Stop and delete the service-mode experiment. Do this before ProgramData so the
# daemon cannot hold files open.
foreach ($name in $services) {
    Stop-AndDeleteService -Name $name
}
Write-Log ''

# A stopped service should have exited; kill any orphan (only the installed
# names, never a developer's arbitrary process).
foreach ($procName in @('ppf-daemon', 'ppf-daemon-debug')) {
    $procs = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) {
        Write-Log "[SKIP] process not running: $procName"
        continue
    }
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            Write-Log "[KILLED] $procName (pid $($p.Id))"
        } catch {
            Write-Log "[WARN] could not kill $procName (pid $($p.Id)): $($_.Exception.Message)"
        }
    }
}
Write-Log ''

foreach ($path in $programDataRoots) {
    Remove-ProtectedPath -Path $path -Label 'ProgramData service root'
}
Write-Log ''

$rules = @(Get-PPassFirewallRules)
if ($rules.Count -eq 0) {
    Write-Log '[SKIP] no P-Pass firewall rules found'
} else {
    Write-Log "[FIREWALL] removing $($rules.Count) P-Pass rule(s)"
    try {
        $rules | Remove-NetFirewallRule -ErrorAction Stop
        Write-Log "[REMOVED] firewall rules: $($rules.Count)"
    } catch {
        Write-Log "[FAIL] could not remove firewall rules: $($_.Exception.Message)"
    }
}
Write-Log ''

# --- Self-check --------------------------------------------------------------
Write-Log '=== Administrator self-check ==='

function Assert-AbsentPath {
    param([string]$Label, [string]$Path)
    if (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue) {
        Write-Log "[FAIL] $Label still present: $Path"
        $script:residuals.Add("$Label : $Path")
    } else {
        Write-Log "[OK] absent: $Label"
    }
}

function Assert-AbsentService {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Log "[FAIL] service still installed: $Name (status $($svc.Status))"
        $script:residuals.Add("service : $Name (status $($svc.Status))")
    } else {
        Write-Log "[OK] service absent: $Name"
    }
}

function Assert-AbsentServiceKey {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue) {
        Write-Log "[FAIL] service registry key still present: $Path"
        $script:residuals.Add("service registry key : $Path")
    } else {
        Write-Log "[OK] absent: $Path"
    }
}

foreach ($name in $services) {
    Assert-AbsentService -Name $name
}
foreach ($key in $serviceKeys) {
    Assert-AbsentServiceKey -Path $key
}
foreach ($path in $programDataRoots) {
    Assert-AbsentPath -Label 'ProgramData root' -Path $path
}

$remainingRules = @(Get-PPassFirewallRules)
if ($remainingRules.Count -gt 0) {
    Write-Log "[FAIL] P-Pass firewall rules still present: $($remainingRules.Count)"
    $script:residuals.Add("firewall rules : $($remainingRules.Count)")
} else {
    Write-Log '[OK] absent: P-Pass firewall rules'
}

if (Get-Process -Name 'ppf-daemon' -ErrorAction SilentlyContinue) {
    Write-Log '[FAIL] ppf-daemon is still running'
    $script:residuals.Add('process : ppf-daemon still running')
} else {
    Write-Log '[OK] absent: ppf-daemon process'
}

Write-Log ''
if ($script:residuals.Count -gt 0) {
    Write-Log "SELF-CHECK FAILED: $($script:residuals.Count) item(s) remain."
    foreach ($r in $script:residuals) { Write-Log "  - $r" }
    $exitCode = 1
} else {
    Write-Log 'SELF-CHECK PASSED: services, ProgramData roots and firewall rules are gone.'
    $exitCode = 0
}
Write-Log "Result log: $LogPath"

if ($transcriptStarted) {
    try { Stop-Transcript | Out-Null } catch { }
}
exit $exitCode
