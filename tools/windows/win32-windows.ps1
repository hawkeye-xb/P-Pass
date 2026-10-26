# win32-windows.ps1 - Legacy Win32 window/control dump and button click.
# NSIS installers expose their pages as classic #32770 dialogs; some of them do
# not publish a UI Automation tree, so UIA cannot see the buttons. This helper
# enumerates child windows with EnumChildWindows and clicks a Button by text.
#
# Usage:
#   win32-windows.ps1 -ProcId 1234 -Out <file>
#   win32-windows.ps1 -ProcId 1234 -Click '安装' -Out <file>
#
# Exit codes: 0 ok, 2 process/window not found, 3 button not found.
param(
    [int]$ProcId = 0,
    [string]$Out = "$env:TEMP\win32-windows.txt",
    [string]$Click = '',
    [switch]$All
)

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class W1063 {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hWnd, EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int max);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int max);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hWnd);

    public static string Text(IntPtr h) {
        StringBuilder sb = new StringBuilder(1024);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }
    public static string Class(IntPtr h) {
        StringBuilder sb = new StringBuilder(256);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }
    public static List<IntPtr> TopWindows(uint pid) {
        List<IntPtr> list = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list;
    }
    public static List<IntPtr> Children(IntPtr parent) {
        List<IntPtr> list = new List<IntPtr>();
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr l) {
            list.Add(h); return true;
        }, IntPtr.Zero);
        return list;
    }
    public static IntPtr FindButton(uint pid, string want) {
        foreach (IntPtr top in TopWindows(pid)) {
            foreach (IntPtr h in Children(top)) {
                string cls = Class(h);
                string txt = Text(h);
                if (cls == "Button" && txt.IndexOf(want, StringComparison.OrdinalIgnoreCase) >= 0) return h;
            }
            if (Class(top) == "Button" && Text(top).IndexOf(want, StringComparison.OrdinalIgnoreCase) >= 0) return top;
        }
        return IntPtr.Zero;
    }
    public static bool Click(IntPtr h) {
        IntPtr parent = GetParent(h);
        int id = GetDlgCtrlID(h);
        // NSIS pages are classic dialogs: a synchronous WM_COMMAND/BN_CLICKED is
        // more reliable than a posted BM_CLICK when the dialog is not focused.
        if (parent != IntPtr.Zero && id != 0) {
            SendMessage(parent, 0x0111, (IntPtr)(id & 0xFFFF), h);
        }
        SendMessage(h, 0x00F5, IntPtr.Zero, IntPtr.Zero); // BM_CLICK
        return true;
    }
}
'@

$lines = New-Object System.Collections.Generic.List[string]
$pids = @()
if ($ProcId -ne 0) { $pids = @($ProcId) }
else {
    $pids = @(Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object { $_.Id })
}

$found = 0
foreach ($p in $pids) {
    foreach ($top in [W1063]::TopWindows([uint32]$p)) {
        $t = [W1063]::Text($top)
        $c = [W1063]::Class($top)
        $vis = [W1063]::IsWindowVisible($top)
        if (-not $All -and -not $vis) { continue }
        $found++
        $lines.Add(("TOP|{0}|{1}|pid={2}|visible={3}" -f $t, $c, $p, $vis))
        foreach ($h in [W1063]::Children($top)) {
            $ct = [W1063]::Text($h)
            $cc = [W1063]::Class($h)
            if ($ct -ne '' -or $cc -match 'Button|Edit|Static|ComboBox') {
                $lines.Add(("  CHILD|{0}|{1}" -f $ct, $cc))
            }
        }
        $lines.Add('')
    }
}

$clicked = $false
if ($Click -ne '' -and $pids.Count -gt 0) {
    foreach ($p in $pids) {
        $h = [W1063]::FindButton([uint32]$p, $Click)
        if ($h -ne [IntPtr]::Zero) {
            [W1063]::SetForegroundWindow($h) | Out-Null
            [W1063]::Click($h) | Out-Null
            "clicked=$Click hwnd=$h pid=$p"
            $clicked = $true
            break
        }
    }
}

[IO.File]::WriteAllLines($Out, $lines, (New-Object Text.UTF8Encoding($false)))
"windows=$found out=$Out"
if ($Click -ne '' -and -not $clicked) { exit 3 }
if ($found -eq 0) { exit 2 }
exit 0
