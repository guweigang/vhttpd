param([Parameter(Mandatory=$true)][int]$DesktopProcessId)
$ErrorActionPreference = 'Stop'
if (-not ('WorkbenchLifecycle' -as [type])) {
 Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WorkbenchLifecycle {
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
 [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr menu, int index);
 [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
 [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr menu, int index);
 [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
}
'@
}
$process = Get-Process -Id $DesktopProcessId
$window = $process.MainWindowHandle
if ($window -eq [IntPtr]::Zero) { throw 'Desktop window unavailable for lifecycle check' }
$fileMenu = [WorkbenchLifecycle]::GetSubMenu([WorkbenchLifecycle]::GetMenu($window), 0)
$quitId = [WorkbenchLifecycle]::GetMenuItemID($fileMenu, [WorkbenchLifecycle]::GetMenuItemCount($fileMenu) - 1)
if ($quitId -eq [uint32]::MaxValue) { throw 'Desktop Quit menu command unavailable' }
if (!$process.CloseMainWindow()) { throw 'Desktop did not accept window close' }
$deadline = (Get-Date).AddSeconds(5)
while ([WorkbenchLifecycle]::IsWindowVisible($window) -and !$process.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
if ($process.HasExited) { throw 'Window close unexpectedly quit the tray application' }
if ([WorkbenchLifecycle]::IsWindowVisible($window)) { throw 'Window close did not hide Desktop' }
[WorkbenchLifecycle]::ShowWindow($window, 9) | Out-Null
if (![WorkbenchLifecycle]::IsWindowVisible($window)) { throw 'Desktop window could not be restored' }
if (![WorkbenchLifecycle]::PostMessageW($window, 0x111, [IntPtr]$quitId, [IntPtr]::Zero)) { throw 'Desktop Quit command was not delivered' }
if (!$process.WaitForExit(15000)) { throw 'Desktop Quit did not exit cleanly' }
if ($process.ExitCode -ne 0) { throw "Desktop exited $($process.ExitCode)" }
