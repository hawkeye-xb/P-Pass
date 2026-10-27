#Requires -Version 5.1
# verify-service-dacl.ps1 - Prove the service DACL that installer-hooks.nsh applies
# (#1161) lets an elevated Administrator delete the service (what PREUNINSTALL's
# `sc delete` needs) while interactive users can still only query/start/stop.
#
# Uses two throw-away services, never the real "P-Pass" one:
#   PPassDaclOld  <- the pre-fix SDDL  (expect: admin delete DENIED = bug reproduced)
#   PPassDaclNew  <- the SDDL under test (expect: admin delete OK; user stop/start
#                    allowed, user delete/sdset denied)
# One UAC prompt: the script re-launches itself elevated for the admin half and
# runs the interactive-user half itself, coordinating through marker files.
# PPassDaclOld cannot be deleted by an admin (that is the bug), so it is removed by
# a one-shot SYSTEM scheduled task created from the elevated half.
#
# Usage (non-elevated, from an interactive desktop session):
#   powershell -NoProfile -ExecutionPolicy Bypass -File verify-service-dacl.ps1 [-NewSddl "<sddl>"]
# Output: one line per check, then RESULT=PASS|FAIL; exit code 0 on PASS.
param(
    [string]$Phase = 'user',
    [string]$WorkDir = (Join-Path $env:USERPROFILE 'ppcheck\service-dacl'),
    [string]$OldSddl = 'D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCLCSWRPWPDTLOCRRC;;;BA)(A;;CCLCSWRPWPDTLOCRRC;;;IU)',
    [string]$NewSddl = 'D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWRPWPDTLOCRRC;;;IU)'
)

$ErrorActionPreference = 'Continue'
$sc = Join-Path $env:SystemRoot 'System32\sc.exe'
$old = 'PPassDaclOld'
$new = 'PPassDaclNew'
$ready = Join-Path $WorkDir 'admin-ready'
$userDone = Join-Path $WorkDir 'user-done'
$adminDone = Join-Path $WorkDir 'admin-done'
$results = Join-Path $WorkDir 'results.txt'

# Not named `Sc`: in Windows PowerShell `sc` is an alias of Set-Content and aliases
# win over functions, so `Sc @(...)` would silently prompt for -Value and hang.
function Invoke-Sc([string[]]$a) {
    $out = & $sc @a 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out.Trim() }
}
function Record([string]$who, [string]$check, [bool]$ok, [string]$detail) {
    $line = '{0} {1} {2} {3}' -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $who, $check, $detail
    Add-Content -Path $results -Value $line -Encoding ASCII
}
function Wait-File([string]$path, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) { if (Test-Path $path) { return $true }; Start-Sleep -Milliseconds 500 }
    return $false
}
function Exists([string]$name) { (Invoke-Sc @('query', $name)).Code -ne 1060 }

function Remove-AsSystem([string[]]$names) {
    $todo = @($names | Where-Object { Exists $_ })
    if ($todo.Count -eq 0) { return $true }
    $cmd = ($todo | ForEach-Object { "$sc delete $_" }) -join ' & '
    $task = 'PPassDaclCleanup'
    & schtasks.exe /Create /F /RU SYSTEM /SC ONCE /ST 23:59 /TN $task /TR "cmd.exe /c $cmd" | Out-Null
    & schtasks.exe /Run /TN $task | Out-Null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and (@($todo | Where-Object { Exists $_ }).Count -gt 0)) { Start-Sleep -Milliseconds 500 }
    & schtasks.exe /Delete /F /TN $task | Out-Null
    return (@($todo | Where-Object { Exists $_ }).Count -eq 0)
}

if ($Phase -eq 'admin') {
    # A transcript, because this half runs hidden and an error would otherwise vanish.
    Start-Transcript -Path (Join-Path $WorkDir 'admin-transcript.txt') -Force | Out-Null
    # An earlier elevated copy may still be waiting on marker files; it would race this one.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*verify-service-dacl.ps1*-Phase admin*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    # Leftovers from an earlier run would make `sc create` fail.
    Remove-AsSystem @($old, $new) | Out-Null
    foreach ($pair in @(@($old, $OldSddl), @($new, $NewSddl))) {
        $c = Invoke-Sc @('create', $pair[0], 'binPath=', 'C:\Windows\System32\cmd.exe /c exit 0', 'start=', 'demand')
        Record 'admin' "create-$($pair[0])" ($c.Code -eq 0) "exit=$($c.Code)"
        $s = Invoke-Sc @('sdset', $pair[0], $pair[1])
        Record 'admin' "sdset-$($pair[0])" ($s.Code -eq 0) "exit=$($s.Code)"
    }
    Set-Content -Path $ready -Value 'ready' -Encoding ASCII
    if (-not (Wait-File $userDone 180)) { Record 'admin' 'wait-user-half' $false 'timeout' }

    $d = Invoke-Sc @('delete', $old)
    Record 'admin' 'delete-old-is-denied(bug-repro)' ($d.Code -eq 5) "exit=$($d.Code)"
    $d = Invoke-Sc @('delete', $new)
    Record 'admin' 'delete-new-succeeds' ($d.Code -eq 0) "exit=$($d.Code)"
    Start-Sleep -Seconds 1
    Record 'admin' 'new-is-gone' (-not (Exists $new)) ''
    $cleaned = Remove-AsSystem @($old, $new)
    Record 'admin' 'cleanup-probes-via-SYSTEM' $cleaned ''
    Set-Content -Path $adminDone -Value 'done' -Encoding ASCII
    exit 0
}

# ---- user half (non-elevated) ----
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $ready, $userDone, $adminDone, $results
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) { Write-Output 'RESULT=FAIL run this from a NON-elevated shell (the user half must not hold admin rights)'; exit 2 }

$argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"",
    '-Phase', 'admin', '-WorkDir', "`"$WorkDir`"", '-OldSddl', "`"$OldSddl`"", '-NewSddl', "`"$NewSddl`"")
try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argsList | Out-Null
} catch {
    Write-Output "RESULT=FAIL UAC was declined or failed: $($_.Exception.Message)"; exit 3
}
if (-not (Wait-File $ready 300)) { Write-Output 'RESULT=FAIL elevated half never became ready (UAC not approved within 5 min?)'; exit 4 }

$stop = Invoke-Sc @('stop', $new)
Record 'user' 'stop-new-allowed' ($stop.Code -ne 5) "exit=$($stop.Code) (1062=not started is the expected allow)"
$start = Invoke-Sc @('start', $new)
Record 'user' 'start-new-allowed' ($start.Code -ne 5) "exit=$($start.Code) (1053 = dummy binary is not a service; access was granted)"
$del = Invoke-Sc @('delete', $new)
Record 'user' 'delete-new-denied' ($del.Code -eq 5) "exit=$($del.Code)"
$sd = Invoke-Sc @('sdset', $new, 'D:(A;;GA;;;WD)')
Record 'user' 'sdset-new-denied' ($sd.Code -eq 5) "exit=$($sd.Code)"
Set-Content -Path $userDone -Value 'done' -Encoding ASCII

if (-not (Wait-File $adminDone 120)) { Record 'user' 'wait-admin-half' $false 'timeout' }
$lines = @(Get-Content -Path $results -Encoding ASCII)
$lines | ForEach-Object { Write-Output $_ }
$failed = @($lines | Where-Object { $_ -like 'FAIL *' })
if ($failed.Count -eq 0 -and $lines.Count -ge 12) { Write-Output 'RESULT=PASS'; exit 0 }
Write-Output "RESULT=FAIL ($($failed.Count) failed, $($lines.Count) checks recorded)"
exit 1
