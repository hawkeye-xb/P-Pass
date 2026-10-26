#Requires -Version 5.1
# 1063-admin-once.ps1 - one elevated process, two jobs: finish the #1161 residue
# cleanup and then sample W4 wake declarations for 15 minutes.
#
# This script is launched exactly once, by a human approving one UAC prompt:
#   Start-Process powershell -Verb RunAs -ArgumentList `
#     '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Users\ethan\personal\P-Pass-1063\tools\windows\1063-admin-once.ps1'
#
# Safety constraints for the other regression running on this machine:
#   - never kills a process;
#   - never touches C:\Users\ethan\AppData\Local\P-Pass;
#   - never touches the phone;
#   - never calls reset-ppass-env.ps1 / reset-ppass-admin.ps1.
#
# Every path below is an absolute literal: the elevated account may not be ethan,
# so $env:USERPROFILE / $env:ProgramData must not be used.
#
# Log:  C:\Users\ethan\ppcheck\1063-test10\admin-once\run.log
#       first line is "ELEVATED START <time> user=<whoami>"
# W4:   C:\Users\ethan\ppcheck\1063-test10\W4\powercfg-requests.txt (append)

$ErrorActionPreference = 'Continue'

# --- Fixed absolute paths -----------------------------------------------------
$LogDir              = 'C:\Users\ethan\ppcheck\1063-test10\admin-once'
$LogPath             = 'C:\Users\ethan\ppcheck\1063-test10\admin-once\run.log'
$W4Dir               = 'C:\Users\ethan\ppcheck\1063-test10\W4'
$W4LogPath           = 'C:\Users\ethan\ppcheck\1063-test10\W4\powercfg-requests.txt'
$KeepFirewallProgram = 'C:\Users\ethan\AppData\Local\P-Pass\ppf-daemon.exe'
$ServiceNames        = @('P-Pass', 'PPassPocSvc')
$ProgramDataRoots    = @('C:\ProgramData\P-Pass', 'C:\ProgramData\PPassPoc')

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# Keep an earlier run.log as evidence instead of appending to it: the first line
# of the new file must be the ELEVATED START marker.
if (Test-Path -LiteralPath $LogPath) {
    try {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Move-Item -LiteralPath $LogPath -Destination (Join-Path $LogDir ("run.prev-{0}.log" -f $stamp)) -Force -ErrorAction Stop
    } catch {
        # If it cannot be moved it will be overwritten below.
    }
}

function Write-Log {
    param([string]$Message)
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $Message
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Output $line
    }
}

# --- First line: ELEVATED START -------------------------------------------------
$whoamiText = ''
try { $whoamiText = ((& whoami.exe 2>&1) | Out-String).Trim() } catch { }
$whoamiText = ($whoamiText -replace '\r?\n', ' ').Trim()
if ($whoamiText -eq '') { $whoamiText = [Security.Principal.WindowsIdentity]::GetCurrent().Name }

$startLine = 'ELEVATED START {0} user={1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $whoamiText
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($LogPath, $startLine + "`r`n", $utf8NoBom)
} catch {
    Set-Content -LiteralPath $LogPath -Value $startLine -Encoding UTF8
}

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Log ("identity={0} elevated={1}" -f $identity.Name, $isAdmin)
Write-Log ("powershell={0}" -f $PSVersionTable.PSVersion)
Write-Log ("script={0}" -f $MyInvocation.MyCommand.Path)
Write-Log ("keep-firewall-program={0}" -f $KeepFirewallProgram)

if (-not $isAdmin) {
    Write-Log 'ERROR: this process is NOT elevated; no cleanup performed.'
    Write-Log 'ELEVATED DONE'
    exit 1
}

# --- Helpers -------------------------------------------------------------------
function Invoke-Sc {
    param([string[]]$ScArgs)
    $out  = & sc.exe @ScArgs 2>&1
    $code = $LASTEXITCODE
    $text = (($out | Out-String).Trim())
    return [pscustomobject]@{ Code = $code; Output = $text }
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

function Normalize-ProgramPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return (($Path -replace '/', '\').Trim())
}

function Test-SameProgram {
    param([string]$A, [string]$B)
    return [string]::Equals((Normalize-ProgramPath $A), (Normalize-ProgramPath $B),
        [System.StringComparison]::OrdinalIgnoreCase)
}

# InstanceID of every application filter equals the owning rule's Name. Read the
# program paths from Get-NetFirewallApplicationFilter once, then join by rule.
function Get-FirewallProgramMap {
    $map = @{}
    $filters = @(Get-NetFirewallApplicationFilter -ErrorAction Stop)
    foreach ($f in $filters) {
        $id = [string]$f.InstanceID
        if (-not $map.ContainsKey($id)) {
            $map[$id] = New-Object System.Collections.Generic.List[string]
        }
        $map[$id].Add([string]$f.Program)
    }
    return $map
}

# --- STEP A: #1161 residue cleanup ---------------------------------------------
Write-Log '=== STEP A: 1161 residue cleanup ==='

foreach ($name in $ServiceNames) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "[SERVICE] $name : not installed -> SKIP stop/delete"
        continue
    }

    Write-Log "[SERVICE] $name : status=$($svc.Status) startType=$($svc.StartType)"

    # Stop first (no-op when already stopped), then delete.
    $r = Invoke-Sc -ScArgs @('stop', $name)
    Write-Log ("  sc.exe stop {0} -> exit {1}{2}" -f $name, $r.Code, $(if ($r.Output) { ': ' + $r.Output } else { '' }))
    if (Wait-ServiceState -Name $name -Wanted 'Stopped' -TimeoutSeconds 20) {
        Write-Log "  [STOPPED] $name"
    } else {
        Write-Log "  [WARN] $name did not reach STOPPED within 20s"
    }

    $r = Invoke-Sc -ScArgs @('delete', $name)
    Write-Log ("  sc.exe delete {0} -> exit {1}{2}" -f $name, $r.Code, $(if ($r.Output) { ': ' + $r.Output } else { '' }))

    if ($r.Code -ne 0) {
        # #1161's sc sdset left Administrators without DELETE; widen once and retry.
        $sddl = 'D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWRPWPDTLOCRRC;;;IU)'
        $d = Invoke-Sc -ScArgs @('sdset', $name, $sddl)
        Write-Log ("  [RETRY] sc.exe sdset {0} -> exit {1}" -f $name, $d.Code)
        if ($d.Output) { Write-Log "    $($d.Output)" }
        $r = Invoke-Sc -ScArgs @('delete', $name)
        Write-Log ("  sc.exe delete {0} (retry) -> exit {1}{2}" -f $name, $r.Code, $(if ($r.Output) { ': ' + $r.Output } else { '' }))
    }

    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 250
    }
    $still = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($still) {
        Write-Log "  [FAIL] service $name still present (status $($still.Status))"
    } else {
        Write-Log "  [DELETED] service $name (verified absent)"
    }
    if (Test-Path -LiteralPath ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $name)) {
        Write-Log "  [WARN] service registry key still present: HKLM:\SYSTEM\CurrentControlSet\Services\$name"
    } else {
        Write-Log "  [OK] service registry key absent: HKLM:\SYSTEM\CurrentControlSet\Services\$name"
    }
}

foreach ($path in $ProgramDataRoots) {
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Log "[DIR] $path : absent -> SKIP"
        continue
    }
    try {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
        Write-Log "[DIR] $path : REMOVED"
    } catch {
        Write-Log "[DIR] $path : FAIL $($_.Exception.Message)"
    }
    if (Test-Path -LiteralPath $path) {
        Write-Log "[DIR] $path : STILL PRESENT (verify failed)"
    } else {
        Write-Log "[DIR] $path : verified absent"
    }
}

# Firewall: identify P-Pass rules by rule name OR by the program path obtained
# from Get-NetFirewallApplicationFilter, then keep exactly the rules whose
# program is the daemon test.10 is using.
$progMap = $null
try {
    $progMap = Get-FirewallProgramMap
    Write-Log ("[FIREWALL] application filters indexed: {0}" -f $progMap.Count)
} catch {
    Write-Log "[FIREWALL][FAIL] cannot enumerate application filters: $($_.Exception.Message)"
}

$kept = 0
$deleted = 0
$failed = 0
if ($progMap) {
    try {
        $allRules = @(Get-NetFirewallRule -ErrorAction Stop)
    } catch {
        $allRules = @()
        Write-Log "[FIREWALL][FAIL] cannot enumerate rules: $($_.Exception.Message)"
    }

    $namePattern = '(?i)p-pass|ppass|ppf-daemon'
    foreach ($rule in $allRules) {
        $ruleName    = [string]$rule.Name
        $displayName = [string]$rule.DisplayName

        $programs = @()
        if ($progMap.ContainsKey($ruleName)) { $programs = @($progMap[$ruleName]) }

        $isPpass = ($displayName -match $namePattern) -or ($ruleName -match $namePattern)
        if (-not $isPpass) {
            foreach ($p in $programs) {
                if ([string]$p -match $namePattern) { $isPpass = $true; break }
            }
        }
        if (-not $isPpass) { continue }

        $keep = $false
        foreach ($p in $programs) {
            if (Test-SameProgram -A $p -B $KeepFirewallProgram) { $keep = $true; break }
        }

        if ($programs.Count -gt 0) { $programText = ($programs -join '; ') } else { $programText = '<no application filter>' }

        if ($keep) {
            Write-Log "[FIREWALL][KEEP] '$displayName' program=$programText"
            $kept++
            continue
        }

        try {
            $rule | Remove-NetFirewallRule -ErrorAction Stop
            Write-Log "[FIREWALL][DELETED] '$displayName' program=$programText"
            $deleted++
        } catch {
            Write-Log "[FIREWALL][FAIL] '$displayName' program=$programText : $($_.Exception.Message)"
            $failed++
        }
    }

    # Verification: the two test.10 rules (program exactly the keep path) must remain.
    try {
        $progMap2 = Get-FirewallProgramMap
        $keepRules = @()
        foreach ($r in @(Get-NetFirewallRule -ErrorAction Stop)) {
            $pl = @()
            if ($progMap2.ContainsKey([string]$r.Name)) { $pl = @($progMap2[[string]$r.Name]) }
            foreach ($p in $pl) {
                if (Test-SameProgram -A $p -B $KeepFirewallProgram) { $keepRules += $r; break }
            }
        }
        Write-Log ("[FIREWALL][VERIFY] rules still using {0}: {1}" -f $KeepFirewallProgram, $keepRules.Count)
        foreach ($r in $keepRules) {
            Write-Log ("  [PRESENT] '{0}'" -f $r.DisplayName)
        }
    } catch {
        Write-Log "[FIREWALL][VERIFY][FAIL] $($_.Exception.Message)"
    }
}

Write-Log ("[FIREWALL][SUMMARY] kept={0} deleted={1} failed={2}" -f $kept, $deleted, $failed)
Write-Log '=== STEP A DONE ==='

# --- STEP B: W4 wake-declaration sampling (15 min, every 2 s) -------------------
Write-Log '=== STEP B: W4 powercfg /requests sampling (15 min, every 2 s) ==='
New-Item -ItemType Directory -Force -Path $W4Dir | Out-Null
$sampleStart = Get-Date
$deadline    = $sampleStart.AddMinutes(15)
$nextTick    = $sampleStart
$sampleCount = 0

Write-Log ("[W4] start={0} file={1}" -f $sampleStart.ToString('yyyy-MM-dd HH:mm:ss'), $W4LogPath)

while ((Get-Date) -lt $deadline) {
    $ts = Get-Date
    try {
        Add-Content -LiteralPath $W4LogPath -Value ("=== {0} ===" -f $ts.ToString('yyyy-MM-dd HH:mm:ss.fff')) -Encoding UTF8 -ErrorAction Stop
        $req  = & powercfg.exe /requests 2>&1
        $body = (($req | Out-String).TrimEnd())
        Add-Content -LiteralPath $W4LogPath -Value $body -Encoding UTF8 -ErrorAction Stop
        Add-Content -LiteralPath $W4LogPath -Value '' -Encoding UTF8 -ErrorAction Stop
        $sampleCount++
    } catch {
        Write-Log ("[W4][FAIL] sample {0}: {1}" -f ($sampleCount + 1), $_.Exception.Message)
        break
    }

    $nextTick = $nextTick.AddSeconds(2)
    $waitMs = [int](($nextTick - (Get-Date)).TotalMilliseconds)
    if ($waitMs -gt 0) { Start-Sleep -Milliseconds $waitMs }
}

$elapsed = [int]((Get-Date) - $sampleStart).TotalSeconds
Write-Log ("[W4] done: samples={0} elapsed={1}s file={2}" -f $sampleCount, $elapsed, $W4LogPath)
Write-Log '=== STEP B DONE ==='

Write-Log 'ELEVATED DONE'
exit 0
