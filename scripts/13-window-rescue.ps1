<#
.SYNOPSIS
Windows keeps an app's last position on a monitor that is now off, so it opens out of sight; this moves every such window onto the primary monitor.
.UNDO
None needed - it only moves windows.
#>

[CmdletBinding()]
param(
    [switch]$Watch,
    [ValidateRange(1,60)]
    [int]$IntervalSeconds = 3,
    [switch]$DryRun
)

# Guarded Add-Type for the WinRescue helper class
if (-not ('WinRescue' -as [type])) {
    Add-Type -Language CSharp @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class WinRescue
{
    // Constants
    private const uint GW_OWNER = 4;
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TOOLWINDOW = 0x80;
    private const uint MONITOR_DEFAULTTONULL = 0;
    private const int DWMWA_CLOAKED = 14;

    // Delegates
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    // P/Invoke signatures
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    private static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromRect(ref RECT lprc, uint dwFlags);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);

    // Structs
    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WINDOWPLACEMENT
    {
        public int length;
        public int flags;
        public int showCmd;
        public POINT ptMinPosition;
        public POINT ptMaxPosition;
        public RECT rcNormalPosition;
    }

    // Fields used by the callback
    private static int workLeft;
    private static int workTop;
    private static int workRight;
    private static int workBottom;
    private static bool dryRun;
    private static List<string> log;
    private static int movedCount;

    public static int Rescue(int workLeft, int workTop, int workRight, int workBottom, bool dryRun, List<string> log)
    {
        WinRescue.workLeft = workLeft;
        WinRescue.workTop = workTop;
        WinRescue.workRight = workRight;
        WinRescue.workBottom = workBottom;
        WinRescue.dryRun = dryRun;
        WinRescue.log = log;
        WinRescue.movedCount = 0;

        EnumWindowsProc callback = new EnumWindowsProc(Callback);
        EnumWindows(callback, IntPtr.Zero);
        return movedCount;
    }

    private static bool Callback(IntPtr hWnd, IntPtr lParam)
    {
        // Visibility check
        if (!IsWindowVisible(hWnd))
            return true;

        // Owner check
        if (GetWindow(hWnd, GW_OWNER) != IntPtr.Zero)
            return true;

        // Toolwindow check
        if ((GetWindowLong(hWnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0)
            return true;

        // Title length check
        int titleLen = GetWindowTextLength(hWnd);
        if (titleLen == 0)
            return true;

        // Cloaked check
        int cloaked;
        int hr = DwmGetWindowAttribute(hWnd, DWMWA_CLOAKED, out cloaked, Marshal.SizeOf(typeof(int)));
        if (hr != 0 || cloaked != 0)
            return true;

        // Get current placement
        WINDOWPLACEMENT placement = new WINDOWPLACEMENT();
        placement.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        if (!GetWindowPlacement(hWnd, ref placement))
            return true;

        RECT r = placement.rcNormalPosition;

        // If the window is on a live monitor, skip
        if (MonitorFromRect(ref r, MONITOR_DEFAULTTONULL) != IntPtr.Zero)
            return true;

        // Retrieve window title
        StringBuilder sb = new StringBuilder(titleLen + 1);
        GetWindowText(hWnd, sb, sb.Capacity);
        string title = sb.ToString();

        // Compute new position
        int maxWidth = workRight - workLeft;
        int maxHeight = workBottom - workTop;
        int width = Math.Min(r.Right - r.Left, maxWidth);
        int height = Math.Min(r.Bottom - r.Top, maxHeight);
        int newLeft = workLeft + 40;
        int newTop = workTop + 40;

        if (newLeft + width > workRight)
            newLeft = workRight - width;
        if (newTop + height > workBottom)
            newTop = workBottom - height;

        int oldLeft = r.Left;
        int oldTop = r.Top;

        // Apply new rectangle
        placement.rcNormalPosition.Left = newLeft;
        placement.rcNormalPosition.Top = newTop;
        placement.rcNormalPosition.Right = newLeft + width;
        placement.rcNormalPosition.Bottom = newTop + height;

        if (!dryRun)
        {
            SetWindowPlacement(hWnd, ref placement);
        }

        string line = dryRun
            ? string.Format("would move {0} from {1},{2} to {3},{4}", title, oldLeft, oldTop, newLeft, newTop)
            : string.Format("moved {0} from {1},{2} to {3},{4}", title, oldLeft, oldTop, newLeft, newTop);

        log.Add(line);
        movedCount++;
        return true;
    }
}
"@
}

function Invoke-Rescue {
    # Load Windows Forms for screen information
    Add-Type -AssemblyName System.Windows.Forms

    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $list = New-Object 'System.Collections.Generic.List[string]'

    $count = [WinRescue]::Rescue(
        $workArea.Left,
        $workArea.Top,
        $workArea.Right,
        $workArea.Bottom,
        $DryRun.IsPresent,
        $list
    )

    foreach ($line in $list) {
        Write-Output $line
    }
}

if (-not $Watch) {
    Invoke-Rescue
    exit 0
}
else {
    while ($true) {
        try {
            Invoke-Rescue
        }
        catch {
            Write-Warning $_
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}
