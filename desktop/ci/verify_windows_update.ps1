param([Parameter(Mandatory=$true)][System.Diagnostics.Process]$Process,
      [Parameter(Mandatory=$true)][string]$ResultDirectory)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class UpdateCheck {
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    public delegate bool Visitor(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
    public static bool Click(IntPtr control) {
        Rect rect;
        if (!GetWindowRect(control, out rect) || rect.Right <= rect.Left || rect.Bottom <= rect.Top) return false;
        if (!SetCursorPos((rect.Left+rect.Right)/2, (rect.Top+rect.Bottom)/2)) return false;
        mouse_event(2, 0, 0, 0, UIntPtr.Zero);
        mouse_event(4, 0, 0, 0, UIntPtr.Zero);
        return true;
    }
    [DllImport("user32.dll")] static extern IntPtr GetMenu(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr GetSubMenu(IntPtr menu, int pos);
    [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] static extern uint GetMenuItemID(IntPtr menu, int pos);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetMenuStringW(IntPtr menu, uint pos, StringBuilder title, int size, uint flags);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr root, Visitor visit, IntPtr data);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);

    static uint FindMenu(IntPtr menu, string title) {
        int count = GetMenuItemCount(menu);
        for (int i = 0; i < count; ++i) {
            var sub = GetSubMenu(menu, i);
            if (sub != IntPtr.Zero) {
                var nested = FindMenu(sub, title);
                if (nested != uint.MaxValue) return nested;
            }
            var label = new StringBuilder(256);
            GetMenuStringW(menu, (uint)i, label, label.Capacity, 0x400);
            if (label.ToString().Split('\t')[0].Replace("&", "") == title) return GetMenuItemID(menu, i);
        }
        return uint.MaxValue;
    }
    public static bool OpenUpdate(IntPtr window) {
        var item = FindMenu(GetMenu(window), "检查更新…");
        return item != uint.MaxValue && PostMessageW(window, 0x111, new IntPtr(item), IntPtr.Zero);
    }
    public static IntPtr FindCaption(IntPtr window, string text) {
        var result = IntPtr.Zero;
        EnumChildWindows(window, (child, _) => {
            var caption = new StringBuilder(512);
            GetWindowTextW(child, caption, caption.Capacity);
            if (!IsWindowVisible(child) || !caption.ToString().Contains(text)) return true;
            result = child;
            return false;
        }, IntPtr.Zero);
        return result;
    }
}
'@
$Process.Refresh()
$window = $Process.MainWindowHandle
if ($window -eq [IntPtr]::Zero -or ![UpdateCheck]::OpenUpdate($window)) { throw 'Check for updates menu item missing' }
$deadline = (Get-Date).AddSeconds(15)
do {
    $version = [UpdateCheck]::FindCaption($window, '发现新版 Desktop 0.2.0')
    $button = [UpdateCheck]::FindCaption($window, '前往 GitHub')
    if ($version -ne [IntPtr]::Zero -and $button -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 100
} while ((Get-Date) -lt $deadline)
if ($version -eq [IntPtr]::Zero -or $button -eq [IntPtr]::Zero) { throw 'Update version or GitHub button missing' }
Write-Host 'PASS: native settings displays Desktop 0.2.0 and GitHub button.'
if (![UpdateCheck]::Click($button)) { throw 'Cannot click GitHub button' }

$expected = 'https://github.com/guweigang/vhttpd/releases/tag/desktop-v0.2.0'
$deadline = (Get-Date).AddSeconds(30)
$observed = ''
do {
    foreach ($browser in (Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('msedge.exe', 'chrome.exe', 'firefox.exe') })) {
        if ($browser.CommandLine -and $browser.CommandLine.Contains($expected)) {
            $observed = 'browser command line'
            break
        }
        try {
            $proc = Get-Process -Id $browser.ProcessId -ErrorAction Stop
            if ($proc.MainWindowHandle -eq [IntPtr]::Zero) { continue }
            $element = [Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
            $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Edit)
            foreach ($field in $element.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)) {
                $pattern = $null
                if ($field.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern,[ref]$pattern) -and $pattern.Current.Value -in @($expected, $expected.Substring(8))) {
                    $observed = 'browser address bar'
                    break
                }
            }
        } catch { continue }
        if ($observed) { break }
    }
    if ($observed) { break }
    Start-Sleep -Milliseconds 300
} while ((Get-Date) -lt $deadline)
if (!$observed) { throw "Default browser did not receive $expected" }
@{version='0.2.0'; browser_url=$expected; observed_via=$observed; fixture=$true} |
    ConvertTo-Json | Set-Content "$ResultDirectory/update-acceptance.json"
Write-Host "PASS: $observed confirms $expected"
