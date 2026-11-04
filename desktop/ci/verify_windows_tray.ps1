param([Parameter(Mandatory=$true)][System.Diagnostics.Process]$Process,
      [Parameter(Mandatory=$true)][string]$ResultDirectory)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

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
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string type, string title);
    [DllImport("user32.dll")]
    private static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

    public static bool HasIcon(IntPtr window) {
        var icon = new IconId { Window = window, Id = 1 };
        icon.Size = (uint)Marshal.SizeOf(icon);
        Rect rect;
        return Shell_NotifyIconGetRect(ref icon, out rect) >= 0 && rect.Right > rect.Left && rect.Bottom > rect.Top;
    }
    public static bool OpenMenu(IntPtr window) {
        return PostMessageW(window, 0x8000 + 78, new IntPtr(1), new IntPtr(0x202));
    }
    public static void Key(byte key) {
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
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
function Invoke-TrayItem([byte]$NavigationKey) {
    if (![TrayCheck]::OpenMenu($window)) { throw 'Cannot deliver shell click callback' }
    Wait-TrayCondition { [TrayCheck]::FindWindow('#32768', $null) -ne [IntPtr]::Zero } 'Native tray popup did not appear'
    [TrayCheck]::Key($NavigationKey)
    Start-Sleep -Milliseconds 200
    [TrayCheck]::Key(0x0D)
    Wait-TrayCondition { [TrayCheck]::FindWindow('#32768', $null) -eq [IntPtr]::Zero } 'Native tray popup did not close'
}

$Process.Refresh()
$window = $Process.MainWindowHandle
if ($window -eq [IntPtr]::Zero) { throw 'Extracted Desktop HWND is missing' }
Wait-TrayCondition { [TrayCheck]::HasIcon($window) } 'Windows Shell did not register the tray icon'
[TrayCheck]::ShowWindowAsync($window, 6) | Out-Null
Wait-TrayCondition { [TrayCheck]::IsIconic($window) } 'Workbench did not minimize'
Invoke-TrayItem 0x24
Wait-TrayCondition { ![TrayCheck]::IsIconic($window) -and [TrayCheck]::GetForegroundWindow() -eq $window } 'Tray Open did not restore the foreground window'
Invoke-TrayItem 0x23
if (!$Process.WaitForExit(30000) -or $Process.ExitCode -ne 0) { throw 'Tray Quit did not exit cleanly' }
Wait-TrayCondition { ![TrayCheck]::HasIcon($window) } 'Tray icon remained registered after Quit'
@{
    shell_icon = 'passed'
    menu = 'native popup opened via shell click callback'
    restore_foreground = 'passed'
    quit_and_remove_icon = 'passed'
} | ConvertTo-Json | Set-Content "$ResultDirectory/tray-acceptance.json"
