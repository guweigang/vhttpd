param([Parameter(Mandatory=$true)][System.Diagnostics.Process]$Process,
      [Parameter(Mandatory=$true)][string]$ResultDirectory)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class TrayCheck {
    [StructLayout(LayoutKind.Sequential)]
    private struct IconId {
        public uint Size;
        public IntPtr Window;
        public uint Id;
        public Guid Guid;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }

    [DllImport("shell32.dll")]
    private static extern int Shell_NotifyIconGetRect(ref IconId icon, out Rect rect);
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hwnd, int command);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    public delegate bool WindowVisitor(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")]
    private static extern bool EnumThreadWindows(uint thread, WindowVisitor visit, IntPtr data);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, IntPtr process);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassNameW(IntPtr hwnd, StringBuilder name, int size);
    [DllImport("user32.dll")]
    private static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern IntPtr SendMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetMenuStringW(IntPtr menu, uint item, StringBuilder title, int size, uint flags);
    [DllImport("user32.dll")]
    private static extern bool GetMenuItemRect(IntPtr hwnd, IntPtr menu, uint item, out Rect rect);
    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);

    public static bool HasIcon(IntPtr window) {
        var icon = new IconId { Window = window, Id = 1 };
        icon.Size = (uint)Marshal.SizeOf(icon);
        Rect rect;
        return Shell_NotifyIconGetRect(ref icon, out rect) >= 0 && rect.Right > rect.Left && rect.Bottom > rect.Top;
    }
    public static bool OpenMenu(IntPtr window) {
        return PostMessageW(window, 0x8000 + 78, new IntPtr(1), new IntPtr(0x202));
    }
    public static IntPtr Popup(IntPtr owner) {
        var found = IntPtr.Zero;
        EnumThreadWindows(GetWindowThreadProcessId(owner, IntPtr.Zero), (window, data) => {
            var name = new StringBuilder(32);
            GetClassNameW(window, name, name.Capacity);
            if (name.ToString() != "#32768" || !IsWindowVisible(window)) return true;
            found = window;
            return false;
        }, IntPtr.Zero);
        return found;
    }
    public static void ClickMenuItem(IntPtr popup, string title) {
        var menu = SendMessageW(popup, 0x1E1, IntPtr.Zero, IntPtr.Zero); // MN_GETHMENU
        int count = GetMenuItemCount(menu);
        for (uint i = 0; i < count; ++i) {
            var label = new StringBuilder(128);
            GetMenuStringW(menu, i, label, label.Capacity, 0x400); // MF_BYPOSITION
            if (label.ToString() != title) continue;
            Rect rect;
            if (!GetMenuItemRect(IntPtr.Zero, menu, i, out rect) ||
                !SetCursorPos((rect.Left + rect.Right) / 2, (rect.Top + rect.Bottom) / 2)) {
                throw new Exception("Cannot locate tray menu row: " + title);
            }
            mouse_event(2, 0, 0, 0, UIntPtr.Zero);
            mouse_event(4, 0, 0, 0, UIntPtr.Zero);
            return;
        }
        throw new Exception("Missing tray menu row: " + title);
    }
}
'@
function Wait-TrayCondition([scriptblock]$Condition, [string]$Failure, [int]$Seconds = 10) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw $Failure
}
function Invoke-TrayItem([string]$Title) {
    if (![TrayCheck]::OpenMenu($window)) { throw 'Cannot deliver shell click callback' }
    Wait-TrayCondition { [TrayCheck]::Popup($window) -ne [IntPtr]::Zero } 'Native tray popup did not appear'
    [TrayCheck]::ClickMenuItem([TrayCheck]::Popup($window), $Title)
    Wait-TrayCondition { [TrayCheck]::Popup($window) -eq [IntPtr]::Zero } "Native tray popup did not close after clicking $Title"
}

$Process.Refresh()
$window = $Process.MainWindowHandle
if ($window -eq [IntPtr]::Zero) { throw 'Extracted Desktop HWND is missing' }
Wait-TrayCondition { [TrayCheck]::HasIcon($window) } 'Windows Shell did not register the tray icon'
[TrayCheck]::ShowWindowAsync($window, 6) | Out-Null
Wait-TrayCondition { [TrayCheck]::IsIconic($window) } 'Workbench did not minimize'
Invoke-TrayItem '打开工作台'
Wait-TrayCondition { ![TrayCheck]::IsIconic($window) -and [TrayCheck]::GetForegroundWindow() -eq $window } 'Tray Open did not restore the foreground window'
Invoke-TrayItem '退出工作台'
if (!$Process.WaitForExit(30000) -or $Process.ExitCode -ne 0) { throw 'Tray Quit did not exit cleanly' }
Wait-TrayCondition { ![TrayCheck]::HasIcon($window) } 'Tray icon remained registered after Quit'
@{
    shell_icon = 'passed'
    menu = 'native popup opened via shell click callback; menu rows selected by pointer'
    restore_foreground = 'passed'
    quit_and_remove_icon = 'passed'
} | ConvertTo-Json | Set-Content "$ResultDirectory/tray-acceptance.json"
