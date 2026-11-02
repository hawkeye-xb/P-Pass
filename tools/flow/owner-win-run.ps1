# Run a command in the owner's interactive logon session on the Windows test machine,
# via a temporary scheduled task (LogonType Interactive), then print its output and exit code.
#
# Why: over OpenSSH the token is a network logon (NT AUTHORITY\NETWORK). Named-pipe DACLs and
# ACL tests behave differently there (they fail or hang), so test results over ssh are not
# trustworthy. A scheduled task with LogonType Interactive runs with the interactive token.
#
# Keep this file pure ASCII: Windows PowerShell 5.1 reads BOM-less UTF-8 as the ANSI code page.
#
# Output contract (parsed by tools/flow/owner-win-test.sh):
#   ... command output ...
#   PPASS_TASK_RESULT=<LastTaskResult>
#   PPASS_EXIT=<exit code of the command, or 'none' when it never ran / timed out>
#
# Pass either -Command (one cmd.exe command line) or -ScriptFile (a .cmd script; owner-win-test.sh
# generates one with a step per mapping-table row).
param(
  [Parameter(Mandatory)][string]$Workdir,
  [string]$Command,
  [string]$ScriptFile,
  [int]$TimeoutMin = 180
)
$ErrorActionPreference = 'Stop'
if ($ScriptFile) { $Command = "call `"$ScriptFile`"" }
if (-not $Command) { throw 'pass -Command or -ScriptFile' }
$tn = 'ppass-owner-verify'
$out = Join-Path $Workdir 'owner-out.txt'
$rc = Join-Path $Workdir 'owner-rc.txt'
$cmdFile = Join-Path $Workdir 'owner-cmd.cmd'
Remove-Item $out, $rc -ErrorAction SilentlyContinue
"@echo off`r`n$Command > `"$out`" 2>&1`r`necho %ERRORLEVEL% > `"$rc`"`r`n" | Set-Content -Encoding ASCII $cmdFile

$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$cmdFile`""
$principal = New-ScheduledTaskPrincipal -UserId (whoami) -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes $TimeoutMin)
Register-ScheduledTask -TaskName $tn -Action $action -Principal $principal -Settings $settings -Force | Out-Null
try {
  Start-ScheduledTask -TaskName $tn
  $deadline = (Get-Date).AddMinutes($TimeoutMin)
  Start-Sleep 3
  while ((Get-Date) -lt $deadline -and (Get-ScheduledTask -TaskName $tn).State -eq 'Running') { Start-Sleep 10 }
  if ((Get-ScheduledTask -TaskName $tn).State -eq 'Running') { Stop-ScheduledTask -TaskName $tn }
  Start-Sleep 1
  $res = (Get-ScheduledTaskInfo -TaskName $tn).LastTaskResult
} finally {
  Unregister-ScheduledTask -TaskName $tn -Confirm:$false
}
if (Test-Path $out) { Get-Content $out }
"PPASS_TASK_RESULT=$res"
if (Test-Path $rc) { "PPASS_EXIT=" + (Get-Content $rc | Select-Object -First 1).Trim() } else { "PPASS_EXIT=none" }
