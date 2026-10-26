#Requires -Version 5.1
# uia-click-native.ps1 - Click a native task-dialog button (class CCPushButton)
# with BM_CLICK, because those buttons expose no InvokePattern. Used by #1063
# for confirmations such as "移除设备" -> "确定".
param(
    [Parameter(Mandatory = $true)][string]$WindowName,
    [Parameter(Mandatory = $true)][string]$ButtonName,
    [string]$Proc = 'p-pass-desktop'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeClick {
    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@

$A = [Windows.Automation.AutomationElement]
$root = $A::RootElement
$p = Get-Process $Proc -ErrorAction Stop | Select-Object -First 1
$pc = New-Object Windows.Automation.PropertyCondition($A::ProcessIdProperty, $p.Id)
$wins = $root.FindAll([Windows.Automation.TreeScope]::Children, $pc)
$dialog = $null
$cond = New-Object Windows.Automation.PropertyCondition($A::NameProperty, $WindowName)
foreach ($w in $wins) {
    if ($w.Current.Name -eq $WindowName) { $dialog = $w; break }
    # Native task dialogs are often child windows of the Tauri window, not
    # top-level children of the desktop.
    $found = $w.FindFirst([Windows.Automation.TreeScope]::Descendants, $cond)
    if ($found) { $dialog = $found; break }
}
if (-not $dialog) {
    $dialog = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $cond)
}
if (-not $dialog) { "DIALOG NOT FOUND: $WindowName"; exit 2 }

$elements = $dialog.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
$button = $null
foreach ($e in $elements) {
    if ($e.Current.Name -eq $ButtonName) { $button = $e; break }
}
if (-not $button) { "BUTTON NOT FOUND: $ButtonName"; exit 2 }
$hwnd = $button.Current.NativeWindowHandle
if ($hwnd -eq 0) {
    $parent = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($button)
    if ($parent) { $hwnd = $parent.Current.NativeWindowHandle }
}
if ($hwnd -eq 0) { "NO NATIVE HANDLE: $ButtonName"; exit 3 }
[NativeClick]::SendMessage([IntPtr]$hwnd, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
"clicked native: $ButtonName (hwnd=$hwnd)"
