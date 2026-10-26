# uia-drive.ps1 - Drive the P-Pass desktop window through UI Automation, so the
# Windows full regression (full-regression-sop.md section 9) does not need a
# human for wizard / settings / photo-wall clicks. WebView2 exposes the page's
# accessibility tree to UIA, so buttons are found by their visible label.
#
# Usage:
#   uia-drive.ps1 -Action dump                 # list "ControlType | Name" lines to -Out (UTF-8)
#   uia-drive.ps1 -Action click -Name <label>  # invoke the first button/listitem with that exact name
#   uia-drive.ps1 -Action click -Name <part> -Like  # ... whose name contains <part>
#   uia-drive.ps1 -Action type -Name <label> -Value <text>  # focus an Edit and type (SendKeys)
#   uia-drive.ps1 -Action settext -Name <label> -Value <text>  # Edit.ValuePattern.SetValue
#   uia-drive.ps1 -Action getvalue -Name <label>  # print an Edit's ValuePattern value
#   uia-drive.ps1 -Action dumpfull -Out <file>    # TSV: ControlType<TAB>Name<TAB>L,T,R,B
# Exit codes for click/type/settext: 0 ok, 2 not found (page may still be rendering; retry), 3 no pattern.
# Pass Chinese labels from PowerShell, not Git Bash (MSYS mangles the argument encoding).
param(
    [string]$Action = 'dump',      # dump | click | type
    [string]$Name = '',            # element name (exact match) for click/type
    [string]$Value = '',           # text for -Action type (digits only are enough for the pair code)
    [string]$Out = "$env:TEMP\uia.txt",
    [string]$Proc = 'p-pass-desktop',
    [switch]$Like          # click the first control whose name contains -Name
)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
$A = [Windows.Automation.AutomationElement]
$root = $A::RootElement
$p = Get-Process $Proc -ErrorAction Stop | Select-Object -First 1
$pc = New-Object Windows.Automation.PropertyCondition($A::ProcessIdProperty, $p.Id)
$wins = $root.FindAll([Windows.Automation.TreeScope]::Children, $pc)
$lines = New-Object System.Collections.Generic.List[string]
$fullLines = New-Object System.Collections.Generic.List[string]
$target = $null
foreach ($w in $wins) {
    $lines.Add("WIN: " + $w.Current.Name + " | " + $w.Current.ClassName)
    $all = $w.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) {
        $n = $e.Current.Name
        $t = $e.Current.ControlType.ProgrammaticName
        if ($n) { $lines.Add($t + " | " + $n) }
        if ($Action -eq 'dumpfull' -and $n) {
            $r = $e.Current.BoundingRectangle
            $fullLines.Add(("{0}`t{1}`t{2},{3},{4},{5}" -f $t, $n, [int]$r.Left, [int]$r.Top, [int]$r.Right, [int]$r.Bottom))
        }
        $nameHit = ($n -eq $Name) -or ($Like.IsPresent -and $n -like "*$Name*")
        if ($Action -eq 'click' -and -not $target -and $nameHit) {
            if ($t -eq 'ControlType.Button' -or $t -eq 'ControlType.Hyperlink' -or $t -eq 'ControlType.MenuItem' -or $t -eq 'ControlType.CheckBox' -or $t -eq 'ControlType.RadioButton' -or $t -eq 'ControlType.ListItem') { $target = $e }
        }
        if (($Action -eq 'type' -or $Action -eq 'settext' -or $Action -eq 'getvalue') -and -not $target -and $n -eq $Name -and $t -eq 'ControlType.Edit') { $target = $e }
    }
}
if ($Action -eq 'click') {
    if (-not $target) { "NOT FOUND: $Name"; exit 2 }
    $ip = $null
    if ($target.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$ip)) { $ip.Invoke(); "invoked: $Name"; exit 0 }
    $tp = $null
    if ($target.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$tp)) { $tp.Toggle(); "toggled: $Name"; exit 0 }
    $sp = $null
    if ($target.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sp)) { $sp.Select(); "selected: $Name"; exit 0 }
    "NO PATTERN: $Name"; exit 3
}
if ($Action -eq 'type') {
    if (-not $target) { "NOT FOUND: $Name"; exit 2 }
    $target.SetFocus()
    Start-Sleep -Milliseconds 150
    [Windows.Forms.SendKeys]::SendWait($Value)
    "typed: $Name"
    exit 0
}
if ($Action -eq 'settext') {
    if (-not $target) { "NOT FOUND: $Name"; exit 2 }
    $vp = $null
    if ($target.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
        $vp.SetValue($Value)
        "set value: $Name"
        exit 0
    }
    "NO VALUE PATTERN: $Name"; exit 3
}
if ($Action -eq 'getvalue') {
    if (-not $target) { "NOT FOUND: $Name"; exit 2 }
    $vp = $null
    if ($target.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
        "value: " + $vp.Current.Value
        exit 0
    }
    "NO VALUE PATTERN: $Name"; exit 3
}
if ($Action -eq 'dumpfull') {
    [IO.File]::WriteAllLines($Out, $fullLines, (New-Object Text.UTF8Encoding($false)))
    "lines=" + $fullLines.Count
    exit 0
}
[IO.File]::WriteAllLines($Out, $lines, (New-Object Text.UTF8Encoding($false)))
"lines=" + $lines.Count
