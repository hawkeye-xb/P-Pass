# uia-windows.ps1 - Dump the UI Automation tree of top-level windows, so dialogs
# that do not belong to a known process (SmartScreen, NSIS installer) can be read
# without a screenshot. Used by 1063-r64-smartscreen.ps1.
#
# Usage:
#   uia-windows.ps1 -Match 'Windows 已保护你的电脑' -Out <file>
#   uia-windows.ps1 -ProcId 1234 -Out <file>
#   uia-windows.ps1 -All -Out <file>
#
# Exit codes: 0 at least one window matched, 2 none.
param(
    [string]$Match = '',
    [string]$ProcName = '',
    [int]$ProcId = 0,
    [switch]$All,
    [string]$Out = "$env:TEMP\uia-windows.txt"
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [Windows.Automation.AutomationElement]
$root = $A::RootElement
$wins = $root.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)

$lines = New-Object System.Collections.Generic.List[string]
$matched = 0
foreach ($w in $wins) {
    $name = ''
    $class = ''
    $wpid = 0
    try {
        $name = [string]$w.Current.Name
        $class = [string]$w.Current.ClassName
        $wpid = [int]$w.Current.ProcessId
    } catch { continue }

    if ($ProcId -ne 0 -and $wpid -ne $ProcId) { continue }

    $pname = ''
    try { $pname = (Get-Process -Id $wpid -ErrorAction Stop).ProcessName } catch { }

    $hit = $All.IsPresent
    if (-not $hit -and $Match -ne '') {
        $hit = ($name -match $Match) -or ($class -match $Match)
    }
    if (-not $hit -and $ProcName -ne '') {
        $hit = ($pname -ieq $ProcName)
    }
    if (-not $hit) { continue }

    $matched++
    $lines.Add(("WIN|{0}|{1}|pid={2}|proc={3}" -f $name, $class, $wpid, $pname))
    try {
        $all = $w.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
        foreach ($e in $all) {
            $n = ''
            try { $n = [string]$e.Current.Name } catch { }
            if (-not $n) { continue }
            $t = ''
            try { $t = [string]$e.Current.ControlType.ProgrammaticName } catch { }
            $aid = ''
            try { $aid = [string]$e.Current.AutomationId } catch { }
            $lines.Add(("{0}|{1}|{2}" -f $t, $n, $aid))
        }
    } catch { }
    $lines.Add('')
}

[IO.File]::WriteAllLines($Out, $lines, (New-Object Text.UTF8Encoding($false)))
"windows=$matched out=$Out"
if ($matched -eq 0) { exit 2 }
exit 0
