# Run a command OUTSIDE the Claude desktop app's MSIX package context.
# Processes spawned from inside the package inherit its file-system / HKCU
# virtualization (writes to %LOCALAPPDATA% land in Packages\Claude_*\LocalCache).
# Win32_Process.Create is executed by WmiPrvSE, which has no package identity,
# so the child sees the real file system and registry.
#
# Usage: outside.ps1 -Cmd '<cmd.exe command line>' [-Wait 120]
# Output goes to %USERPROFILE%\ppcheck\out.txt (not under AppData) and is printed.
param([Parameter(Mandatory)][string]$Cmd, [int]$Wait = 120)
$dir = Join-Path $env:USERPROFILE 'ppcheck'
New-Item -ItemType Directory -Force $dir | Out-Null
$out = Join-Path $dir 'out.txt'; $done = Join-Path $dir 'done.txt'
Remove-Item $out, $done -ErrorAction SilentlyContinue
$full = "cmd.exe /c chcp 65001 >nul & ($Cmd) > `"$out`" 2>&1 & echo %ERRORLEVEL% > `"$done`""
$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $full }
if ($r.ReturnValue -ne 0) { "WMI create failed: $($r.ReturnValue)"; exit 1 }
$t0 = Get-Date
while (-not (Test-Path $done) -and ((Get-Date) - $t0).TotalSeconds -lt $Wait) { Start-Sleep -Milliseconds 300 }
if (Test-Path $out) { Get-Content -Encoding utf8 $out }
if (Test-Path $done) { "[exit " + (Get-Content $done).Trim() + "]" } else { "[timeout after $Wait s]" }
