#Requires -Version 5.1
# watch-new-windows.ps1 - Report every visible top-level window that appears
# while it runs. Used by the Windows full regression (full-regression-sop.md
# W1) to prove that install / start / stop / self-heal never flash a console.
#
# Why not "is there a conhost.exe": a console child started with
# CREATE_NO_WINDOW still gets a hidden conhost. The only reliable signal is a
# new *visible* top-level window, so this polls EnumWindows + IsWindowVisible
# every 5 ms (a flash lasts tens of ms; a slower poll misses it).
#
# Console windows show up as class ConsoleWindowClass (conhost) or
# CASCADIA_HOSTING_WINDOW_CLASS (Windows Terminal as default terminal).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\watch-new-windows.ps1 -Seconds 60
# Run it, then trigger the action in another shell. Exit code 1 = at least one
# console-class window appeared; 0 = none. Every new window is printed either
# way (time, pid, process, class, title).

param([int]$Seconds = 60)

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class PpWin {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static List<string[]> Visible() {
        var r = new List<string[]>();
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            var c = new StringBuilder(256); GetClassName(h, c, 256);
            var t = new StringBuilder(256); GetWindowText(h, t, 256);
            uint pid; GetWindowThreadProcessId(h, out pid);
            r.Add(new string[] { h.ToInt64().ToString(), pid.ToString(), c.ToString(), t.ToString() });
            return true;
        }, IntPtr.Zero);
        return r;
    }
}
"@

$seen = @{}
foreach ($w in [PpWin]::Visible()) { $seen[$w[0]] = $true }
$consoleClasses = @('ConsoleWindowClass', 'CASCADIA_HOSTING_WINDOW_CLASS')
$hits = 0
$deadline = (Get-Date).AddSeconds($Seconds)
Write-Output "watching for $Seconds s ..."
while ((Get-Date) -lt $deadline) {
    foreach ($w in [PpWin]::Visible()) {
        if ($seen.ContainsKey($w[0])) { continue }
        $seen[$w[0]] = $true
        $name = (Get-Process -Id ([int]$w[1]) -ErrorAction SilentlyContinue).ProcessName
        $tag = ''
        if ($consoleClasses -contains $w[2]) { $hits++; $tag = '  <== CONSOLE' }
        Write-Output ("{0:HH:mm:ss.fff} pid={1} proc={2} class={3} title='{4}'{5}" -f (Get-Date), $w[1], $name, $w[2], $w[3], $tag)
    }
    Start-Sleep -Milliseconds 5
}
Write-Output "console windows seen: $hits"
if ($hits -gt 0) { exit 1 } else { exit 0 }
