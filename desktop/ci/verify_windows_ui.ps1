param([Parameter(Mandatory=$true)][int]$DesktopProcessId, [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class WorkbenchUiCheck {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
 [StructLayout(LayoutKind.Sequential)] public struct Gui { public uint Size,Flags; public IntPtr Active,Focus,Capture,Menu,Move,Caret; public Rect CaretRect; }
 [StructLayout(LayoutKind.Sequential)] public struct Monitor { public int Size; public Rect Screen,Work; public uint Flags; }
 public delegate bool Visitor(IntPtr hwnd,IntPtr data);
 [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hwnd,Visitor callback,IntPtr data);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hwnd,StringBuilder text,int count);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd,StringBuilder text,int count);
 [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hwnd,uint message,IntPtr wparam,IntPtr lparam);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,IntPtr id);
 [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint id,ref Gui info);
 [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd,uint flags);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern bool GetMonitorInfoW(IntPtr monitor,ref Monitor info);
 public static string Text(IntPtr hwnd) { var b=new StringBuilder(2048); GetWindowTextW(hwnd,b,b.Capacity); return b.ToString(); }
 public static string Class(IntPtr hwnd) { var b=new StringBuilder(128); GetClassNameW(hwnd,b,b.Capacity); return b.ToString(); }
 public static IntPtr Find(IntPtr root,string text,string kind) { IntPtr result=IntPtr.Zero; EnumChildWindows(root,(h,d)=>{ if(Text(h)==text && Class(h)==kind) {result=h;return false;}return true;},IntPtr.Zero);return result; }
 public static IntPtr Focus(IntPtr root) { var i=new Gui();i.Size=(uint)Marshal.SizeOf(i);if(!GetGUIThreadInfo(GetWindowThreadProcessId(root,IntPtr.Zero),ref i))throw new Exception("Cannot read UI focus");return i.Focus; }
 public static void CheckWorkArea(IntPtr root) { Rect r;GetWindowRect(root,out r);var m=new Monitor();m.Size=Marshal.SizeOf(m);if(!GetMonitorInfoW(MonitorFromWindow(root,2),ref m))throw new Exception("No monitor");if(r.Left<m.Work.Left||r.Top<m.Work.Top||r.Right>m.Work.Right||r.Bottom>m.Work.Bottom)throw new Exception("Desktop extends outside monitor work area"); }
}
'@
function Save-Window($handle, $name) {
 $rect = New-Object WorkbenchUiCheck+Rect
 if (![WorkbenchUiCheck]::GetWindowRect($handle,[ref]$rect)) { throw 'Window bounds unavailable' }
 $bitmap = New-Object Drawing.Bitmap ($rect.Right-$rect.Left), ($rect.Bottom-$rect.Top)
 $graphics = [Drawing.Graphics]::FromImage($bitmap)
 try { $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size); $bitmap.Save("$OutputDirectory/$name.png",[Drawing.Imaging.ImageFormat]::Png) }
 finally { $graphics.Dispose(); $bitmap.Dispose() }
}
$process = Get-Process -Id $DesktopProcessId
$window = $process.MainWindowHandle
[WorkbenchUiCheck]::CheckWorkArea($window)
foreach ($type in @(0,1)) {
 if ([WorkbenchUiCheck]::SendMessageW($window,0x7F,[IntPtr]$type,[IntPtr]::Zero) -eq [IntPtr]::Zero) { throw 'Window icon is missing' }
}
$create = [WorkbenchUiCheck]::Find($window,'新建 vjsx 项目','UI2View')
if ($create -eq [IntPtr]::Zero) { throw 'Accessible create-project surface missing' }
$title = [WorkbenchUiCheck]::Find($window,'还没有项目','Static')
if ($title -eq [IntPtr]::Zero) { throw 'Empty-project title missing' }
# GDI reports the same actual font the native STATIC draws, including CJK fallback.
$fontHandle = [WorkbenchUiCheck]::SendMessageW($title,0x31,[IntPtr]::Zero,[IntPtr]::Zero)
$font = [Drawing.Font]::FromHfont($fontHandle)
$titleRect = New-Object WorkbenchUiCheck+Rect
[WorkbenchUiCheck]::GetWindowRect($title,[ref]$titleRect) | Out-Null
try { if (($titleRect.Bottom-$titleRect.Top) -lt [Math]::Ceiling($font.GetHeight())) { throw 'Heading frame clips the actual font height' } } finally { $font.Dispose() }
Save-Window $window 'desktop-home'
[WorkbenchUiCheck]::SendMessageW($create,0xF5,[IntPtr]::Zero,[IntPtr]::Zero) | Out-Null
Start-Sleep -Milliseconds 500
$first = [WorkbenchUiCheck]::Focus($window)
if ($first -eq [IntPtr]::Zero -or [WorkbenchUiCheck]::Class($first) -ne 'Edit') { throw 'New-project form did not focus its first input' }
[WorkbenchUiCheck]::SendMessageW($first,0x100,[IntPtr]9,[IntPtr]::Zero) | Out-Null
Start-Sleep -Milliseconds 300
$next = [WorkbenchUiCheck]::Focus($window)
if ($next -eq $first -or [WorkbenchUiCheck]::Class($next) -ne 'Edit') { throw 'Tab did not advance to the next form input' }
Save-Window $window 'desktop-new-project'
@{ work_area='passed'; title_font_bounds='passed'; window_icons='passed'; create_button='passed'; initial_form_focus='passed'; tab_navigation='passed' } | ConvertTo-Json | Set-Content "$OutputDirectory/ui-acceptance.json"
