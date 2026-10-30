param([Parameter(Mandatory=$true)][int]$DesktopProcessId, [Parameter(Mandatory=$true)][string]$OutputDirectory, [switch]$CaptionOnly, [switch]$RootCompositedDiagnostic)
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
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtrW(IntPtr hwnd,int index);
 [DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtrW(IntPtr hwnd,int index,IntPtr value);
 [DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr hwnd,IntPtr rect,IntPtr region,uint flags);
 [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu,uint item,uint flags);
 [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr menu,uint item,StringBuilder text,int count,uint flags);
 [DllImport("user32.dll")] public static extern bool GetMenuItemRect(IntPtr owner,IntPtr menu,uint item,out Rect rect);
 [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd,uint message,IntPtr wparam,IntPtr lparam);
 [DllImport("user32.dll")] public static extern bool EnumThreadWindows(uint id,Visitor callback,IntPtr data);
 [DllImport("user32.dll")] public static extern void keybd_event(byte key,byte scan,uint flags,UIntPtr extra);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern bool UpdateWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
 [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,IntPtr id);
 [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint id,ref Gui info);
 [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd,uint flags);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern bool GetMonitorInfoW(IntPtr monitor,ref Monitor info);
 public static string Text(IntPtr hwnd) { var b=new StringBuilder(2048); GetWindowTextW(hwnd,b,b.Capacity); return b.ToString(); }
 public static string Class(IntPtr hwnd) { var b=new StringBuilder(128); GetClassNameW(hwnd,b,b.Capacity); return b.ToString(); }
 public static IntPtr[] Children(IntPtr root) {var items=new List<IntPtr>();EnumChildWindows(root,(h,d)=>{items.Add(h);return true;},IntPtr.Zero);return items.ToArray();}
 public static IntPtr Find(IntPtr root,string text,string kind) { IntPtr result=IntPtr.Zero; EnumChildWindows(root,(h,d)=>{ if(Text(h)==text && String.Equals(Class(h),kind,StringComparison.OrdinalIgnoreCase)) {result=h;return false;}return true;},IntPtr.Zero);return result; }
 public static IntPtr Popup(IntPtr root) { IntPtr result=IntPtr.Zero;EnumThreadWindows(GetWindowThreadProcessId(root,IntPtr.Zero),(h,d)=>{if(Class(h)=="#32768" && IsWindowVisible(h)){result=h;return false;}return true;},IntPtr.Zero);return result; }
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
if ($RootCompositedDiagnostic) {
 $extended=[WorkbenchUiCheck]::GetWindowLongPtrW($window,-20).ToInt64()
 [WorkbenchUiCheck]::SetWindowLongPtrW($window,-20,[IntPtr]($extended -bor 0x02000000)) | Out-Null
 [WorkbenchUiCheck]::RedrawWindow($window,[IntPtr]::Zero,[IntPtr]::Zero,0x585) | Out-Null
 Start-Sleep -Milliseconds 200
}
[WorkbenchUiCheck]::CheckWorkArea($window)
foreach ($type in @(0,1)) {
 if ([WorkbenchUiCheck]::SendMessageW($window,0x7F,[IntPtr]$type,[IntPtr]::Zero) -eq [IntPtr]::Zero) { throw 'Window icon is missing' }
}
function Measure-BrandInk($name) {
 $label = [WorkbenchUiCheck]::Find($window,'vhttpd','Static')
 if ($label -eq [IntPtr]::Zero) { throw 'Brand label missing' }
 $r = New-Object WorkbenchUiCheck+Rect
 [WorkbenchUiCheck]::GetWindowRect($label,[ref]$r) | Out-Null
 $bitmap = New-Object Drawing.Bitmap ($r.Right-$r.Left), ($r.Bottom-$r.Top)
 $graphics = [Drawing.Graphics]::FromImage($bitmap)
 try {
  $graphics.CopyFromScreen($r.Left,$r.Top,0,0,$bitmap.Size)
  $bitmap.Save("$OutputDirectory/$name.png",[Drawing.Imaging.ImageFormat]::Png)
  $ink = 0
  for ($y=0;$y -lt $bitmap.Height;$y++) { for ($x=0;$x -lt $bitmap.Width;$x++) {
   $color=$bitmap.GetPixel($x,$y)
   if ($color.R -lt 140 -and $color.G -lt 140 -and $color.B -lt 140) {$ink++}
  }}
  return $ink
 } finally {$graphics.Dispose();$bitmap.Dispose()}
}
function Menu-Key([byte]$key) {
 [WorkbenchUiCheck]::keybd_event($key,0,0,[UIntPtr]::Zero)
 [WorkbenchUiCheck]::keybd_event($key,0,2,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 100
}
function Wait-MenuClosed {
 $deadline=(Get-Date).AddSeconds(5)
 while ([WorkbenchUiCheck]::Popup($window) -ne [IntPtr]::Zero -and (Get-Date) -lt $deadline) {Start-Sleep -Milliseconds 50}
 if ([WorkbenchUiCheck]::Popup($window) -ne [IntPtr]::Zero) {throw 'Environment popup did not dismiss'}
 # Let the physical outside-click button-up finish before posting a new invoke.
 Start-Sleep -Milliseconds 200
}
function Open-Environment($caption,$name) {
 $selector=[WorkbenchUiCheck]::Find($window,$caption,'UI2Container')
 if ($selector -eq [IntPtr]::Zero) {throw "Environment selector missing: $caption"}
 $r=New-Object WorkbenchUiCheck+Rect
 [WorkbenchUiCheck]::GetWindowRect($selector,[ref]$r) | Out-Null
 [WorkbenchUiCheck]::SetCursorPos($r.Left+20,$r.Top+15) | Out-Null
 [WorkbenchUiCheck]::PostMessageW($selector,0xF5,[IntPtr]::Zero,[IntPtr]::Zero) | Out-Null
 $deadline=(Get-Date).AddSeconds(5)
 while ([WorkbenchUiCheck]::Popup($window) -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {Start-Sleep -Milliseconds 50}
 Save-Window $window $name
 if ([WorkbenchUiCheck]::Popup($window) -eq [IntPtr]::Zero) {throw 'Native environment popup did not open'}
 $visible=Measure-BrandInk ($name+'-brand')
 if ($visible -lt $script:brandInk*0.8) {throw 'Opening environment menu blanked existing page content'}
}
function Wait-Environment($caption) {
 Wait-MenuClosed
 $deadline=(Get-Date).AddSeconds(5)
 while ([WorkbenchUiCheck]::Find($window,$caption,'UI2Container') -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {Start-Sleep -Milliseconds 50}
 if ([WorkbenchUiCheck]::Find($window,$caption,'UI2Container') -eq [IntPtr]::Zero) {throw "Environment selection did not apply: $caption"}
}
function Native-EnvironmentMenu {
 $popup=[WorkbenchUiCheck]::Popup($window)
 # Documented MN_GETHMENU: https://learn.microsoft.com/windows/win32/winmsg/mn-gethmenu
 $menu=[WorkbenchUiCheck]::SendMessageW($popup,0x1E1,[IntPtr]::Zero,[IntPtr]::Zero)
 if ($menu -eq [IntPtr]::Zero) {throw 'Cannot inspect active environment menu'}
 return $menu
}
function Find-EnvironmentItem($menu,$title) {
 $count=[WorkbenchUiCheck]::GetMenuItemCount($menu)
 for ($i=0;$i -lt $count;$i++) {
  $label=New-Object Text.StringBuilder 256
  [WorkbenchUiCheck]::GetMenuStringW($menu,[uint32]$i,$label,$label.Capacity,0x400) | Out-Null
  if ($label.ToString() -eq $title) {return $i}
 }
 throw "Native menu item missing: $title"
}
function Select-EnvironmentKey($title) {
 $menu=Native-EnvironmentMenu
 $index=Find-EnvironmentItem $menu $title
 $count=[WorkbenchUiCheck]::GetMenuItemCount($menu)
 # Move until the native menu reports the desired item highlighted. Do not
 # assume a Home key or the checked radio item defines initial keyboard focus.
 for ($attempt=0;$attempt -le $count+1;$attempt++) {
  $state=[WorkbenchUiCheck]::GetMenuState($menu,[uint32]$index,0x400)
  if ($state -ne [uint32]::MaxValue -and ($state -band 0x80)) {Menu-Key 0x0D;return}
  Menu-Key 0x28
 }
 throw 'Arrow navigation failed to highlight the environment'
}
function Select-EnvironmentMouse($title) {
 $menu=Native-EnvironmentMenu
 $index=Find-EnvironmentItem $menu $title
 $r=New-Object WorkbenchUiCheck+Rect
 if (![WorkbenchUiCheck]::GetMenuItemRect([IntPtr]::Zero,$menu,[uint32]$index,[ref]$r)) {throw 'Cannot locate native environment menu item'}
 [WorkbenchUiCheck]::SetCursorPos([int](($r.Left+$r.Right)/2),[int](($r.Top+$r.Bottom)/2)) | Out-Null
 [WorkbenchUiCheck]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 [WorkbenchUiCheck]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
}
$script:brandInk=Measure-BrandInk 'environment-before'
if ($script:brandInk -lt 30) {throw 'Initial page content is already blank'}
Open-Environment '本机 Windows ▾' 'environment-open-escape'
# Verify the Windows-only presentation, not just that a native popup exists.
$menu=Native-EnvironmentMenu
$state=[WorkbenchUiCheck]::GetMenuState($menu,0,0x400)
if (($state -band 0x100) -eq 0) {throw 'Environment menu lost workbench row rendering'}
$row=New-Object WorkbenchUiCheck+Rect
if (![WorkbenchUiCheck]::GetMenuItemRect([IntPtr]::Zero,$menu,0,[ref]$row)) {throw 'Environment row bounds unavailable'}
if (($row.Bottom-$row.Top) -lt 36) {throw 'Environment menu rows are too cramped'}
Save-Window ([WorkbenchUiCheck]::Popup($window)) 'environment-styled-popup'
$bitmap=New-Object Drawing.Bitmap ($row.Right-$row.Left),($row.Bottom-$row.Top)
$graphics=[Drawing.Graphics]::FromImage($bitmap)
try {
 $graphics.CopyFromScreen($row.Left,$row.Top,0,0,$bitmap.Size)
 $blue=0
 for ($y=0;$y -lt $bitmap.Height;$y++) {for ($x=0;$x -lt $bitmap.Width;$x++) {
  $c=$bitmap.GetPixel($x,$y)
  if ($c.B -gt 180 -and $c.R -lt 100 -and $c.G -gt 50 -and $c.G -lt 160) {$blue++}
 }}
 if ($blue -lt 10) {throw 'Selected environment is missing its brand-blue text and checkmark'}
} finally {$graphics.Dispose();$bitmap.Dispose()}
Menu-Key 0x1B
Wait-Environment '本机 Windows ▾'
Open-Environment '本机 Windows ▾' 'environment-open-outside'
$r=New-Object WorkbenchUiCheck+Rect
[WorkbenchUiCheck]::GetWindowRect($window,[ref]$r) | Out-Null
[WorkbenchUiCheck]::SetCursorPos($r.Left+550,$r.Top+90) | Out-Null
[WorkbenchUiCheck]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
[WorkbenchUiCheck]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Wait-Environment '本机 Windows ▾'
Open-Environment '本机 Windows ▾' 'environment-open-select'
Select-EnvironmentKey '远端 · CI Menu Host'
Wait-Environment '远端 · CI Menu Host ▾'
Save-Window $window 'environment-remote'
Open-Environment '远端 · CI Menu Host ▾' 'environment-open-return'
Select-EnvironmentMouse '本机 Windows'
Wait-Environment '本机 Windows ▾'
Save-Window $window 'environment-local-restored'
# Focus remains visible, but it must be a continuous brand-blue outline.
$selector=[WorkbenchUiCheck]::Find($window,'本机 Windows ▾','UI2Container')
$focusRect=New-Object WorkbenchUiCheck+Rect
[WorkbenchUiCheck]::GetWindowRect($selector,[ref]$focusRect) | Out-Null
# Obtain focus through a real user click, not SetFocus across GUI threads.
[WorkbenchUiCheck]::SetCursorPos($focusRect.Left+20,$focusRect.Top+15) | Out-Null
[WorkbenchUiCheck]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
[WorkbenchUiCheck]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
$deadline=(Get-Date).AddSeconds(5)
while ([WorkbenchUiCheck]::Popup($window) -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {Start-Sleep -Milliseconds 50}
if ([WorkbenchUiCheck]::Popup($window) -eq [IntPtr]::Zero) {throw 'Pointer did not open the environment selector'}
Menu-Key 0x1B
Wait-Environment '本机 Windows ▾'
[WorkbenchUiCheck]::UpdateWindow($selector) | Out-Null
Save-Window $selector 'environment-focus-outline'
$bitmap=New-Object Drawing.Bitmap ($focusRect.Right-$focusRect.Left),($focusRect.Bottom-$focusRect.Top)
$graphics=[Drawing.Graphics]::FromImage($bitmap)
try {
 $graphics.CopyFromScreen($focusRect.Left,$focusRect.Top,0,0,$bitmap.Size)
 $longest=0
 for ($y=1;$y -lt [Math]::Min(8,$bitmap.Height);$y++) {
  $run=0
  for ($x=12;$x -lt $bitmap.Width-12;$x++) {
   $c=$bitmap.GetPixel($x,$y)
   if ($c.B -ge 160 -and $c.R -lt 100 -and $c.G -ge 40 -and $c.G -lt 160) {$run++;if ($run -gt $longest) {$longest=$run}} else {$run=0}
  }
 }
 if ($longest -lt ($bitmap.Width-24)*0.85) {throw 'Environment focus outline is dotted or missing'}
} finally {$graphics.Dispose();$bitmap.Dispose()}
@{workbench_style='passed';open='passed';page_content_preserved='passed';escape='passed';outside_dismiss='passed';remote_selection='passed';return_local='passed'} | ConvertTo-Json | Set-Content "$OutputDirectory/environment-menu-acceptance.json"
$create = [WorkbenchUiCheck]::Find($window,'新建 vjsx 项目','UI2Container')
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
# Sample actual screen pixels while a real mouse press holds focus on the
# button. Checking only HWND text or the final post-click image misses this bug.
function Measure-Caption($handle, $name) {
 $r = New-Object WorkbenchUiCheck+Rect
 [WorkbenchUiCheck]::GetWindowRect($handle,[ref]$r) | Out-Null
 $bitmap = New-Object Drawing.Bitmap ($r.Right-$r.Left-12), ($r.Bottom-$r.Top-10)
 $graphics = [Drawing.Graphics]::FromImage($bitmap)
 try {
  $graphics.CopyFromScreen($r.Left+6,$r.Top+5,0,0,$bitmap.Size)
  $bitmap.Save("$OutputDirectory/$name.png",[Drawing.Imaging.ImageFormat]::Png)
  $white = 0
  for ($y=0; $y -lt $bitmap.Height; $y++) {
   for ($x=0; $x -lt $bitmap.Width; $x++) {
    $color = $bitmap.GetPixel($x,$y)
    if ($color.R -ge 225 -and $color.G -ge 225 -and $color.B -ge 225) { $white++ }
   }
  }
  return $white
 } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
# Keep real captured WM_MOUSEMOVE coordinates consistent with the simulated press.
$pressRect = New-Object WorkbenchUiCheck+Rect
[WorkbenchUiCheck]::GetWindowRect($create,[ref]$pressRect) | Out-Null
[WorkbenchUiCheck]::SetCursorPos($pressRect.Left+20,$pressRect.Top+15) | Out-Null
Start-Sleep -Milliseconds 150
$baseline = Measure-Caption $create 'caption-idle'
if ($baseline -lt 12) { throw 'Button caption was already missing before the press' }
$measurements = @()
$position = [IntPtr]((15 -shl 16) -bor 20)
try {
 [WorkbenchUiCheck]::SendMessageW($create,0x201,[IntPtr]1,$position) | Out-Null
 [WorkbenchUiCheck]::UpdateWindow($create) | Out-Null
 for ($frame=0; $frame -lt 12; $frame++) {
  Start-Sleep -Milliseconds 16
  $pixels = Measure-Caption $create ("caption-held-{0:D2}" -f $frame)
  $measurements += $pixels
  @{idle_white_pixels=$baseline;held_white_pixels=$measurements} | ConvertTo-Json | Set-Content "$OutputDirectory/caption-frames.json"
  if ($pixels -lt [Math]::Max(8,[Math]::Floor($baseline*0.6))) { throw 'Button caption disappeared while pressed; see caption-frames.json' }
 }
} finally {
 [WorkbenchUiCheck]::SendMessageW($create,0x202,[IntPtr]::Zero,$position) | Out-Null
}
if ($CaptionOnly) { return }
Start-Sleep -Milliseconds 500
$first = [WorkbenchUiCheck]::Focus($window)
if ($first -eq [IntPtr]::Zero -or [WorkbenchUiCheck]::Class($first) -ne 'Edit') { throw 'New-project form did not focus its first input' }
if (([WorkbenchUiCheck]::GetWindowLongPtrW($first,-20).ToInt64() -band 0x200) -ne 0) {throw 'Input has an extra native client-edge border'}
if (([WorkbenchUiCheck]::GetWindowLongPtrW($first,-16).ToInt64() -band 0x800000) -ne 0) {throw 'Input has an extra native rectangular border'}
Save-Window ([WorkbenchUiCheck]::GetParent($first)) 'input-single-rounded-border'
[WorkbenchUiCheck]::SendMessageW($first,0x100,[IntPtr]9,[IntPtr]::Zero) | Out-Null
Start-Sleep -Milliseconds 300
$next = [WorkbenchUiCheck]::Focus($window)
if ($next -eq $first -or [WorkbenchUiCheck]::Class($next) -ne 'Edit') { throw 'Tab did not advance to the next form input' }
Save-Window $window 'desktop-new-project'
@{ single_input_border='passed'; solid_focus_outline='passed'; work_area='passed'; title_font_bounds='passed'; window_icons='passed'; create_button='passed'; initial_form_focus='passed'; tab_navigation='passed'; pressed_caption_frames='passed' } | ConvertTo-Json | Set-Content "$OutputDirectory/ui-acceptance.json"

function Invoke-WorkbenchButton($title) {
 $button=[WorkbenchUiCheck]::Find($window,$title,'UI2Container')
 if ($button -eq [IntPtr]::Zero) {throw "Button unavailable: $title"}
 [WorkbenchUiCheck]::PostMessageW($button,0xF5,[IntPtr]::Zero,[IntPtr]::Zero) | Out-Null
 Start-Sleep -Milliseconds 500
}
$script:formChecks=@()
function Assert-FormLayout($page,[int]$minimum) {
 $count=0
 foreach ($field in [WorkbenchUiCheck]::Children($window)) {
  if ([WorkbenchUiCheck]::Class($field) -ne 'Edit' -or ![WorkbenchUiCheck]::IsWindowVisible($field)) {continue}
  if (([WorkbenchUiCheck]::GetWindowLongPtrW($field,-16).ToInt64() -band 4) -ne 0) {continue} # multiline logs stay top aligned
  $frame=[WorkbenchUiCheck]::GetParent($field)
  if ([WorkbenchUiCheck]::Class($frame) -ne 'UI2Container') {throw "Unframed input on $page"}
  $inner=New-Object WorkbenchUiCheck+Rect; $outer=New-Object WorkbenchUiCheck+Rect
  [WorkbenchUiCheck]::GetWindowRect($field,[ref]$inner) | Out-Null
  [WorkbenchUiCheck]::GetWindowRect($frame,[ref]$outer) | Out-Null
  $top=$inner.Top-$outer.Top; $bottom=$outer.Bottom-$inner.Bottom
  if ([Math]::Abs($top-$bottom) -gt 1 -or $top -lt 4) {throw "Input text is not vertically centred on $page"}
  if (($inner.Left-$outer.Left) -ne 10 -or ($outer.Right-$inner.Right) -ne 10) {throw "Input horizontal padding is inconsistent on $page"}
  if (($outer.Bottom-$outer.Top) -ne 36) {throw "Input control height differs on $page"}
  if (([WorkbenchUiCheck]::GetWindowLongPtrW($field,-20).ToInt64() -band 0x200) -ne 0) {throw 'Duplicate native input edge'}
  $fontHandle=[WorkbenchUiCheck]::SendMessageW($field,0x31,[IntPtr]::Zero,[IntPtr]::Zero)
  $font=[Drawing.Font]::FromHfont($fontHandle)
  try {
   if ([Math]::Abs($font.SizeInPoints-10.5) -gt 0.3) {throw "Input font differs on $page"}
   if ($font.GetHeight() -gt ($inner.Bottom-$inner.Top)+2) {throw "Native input font is clipped on $page"}
  } finally {$font.Dispose()}
  $count++
 }
 if ($count -lt $minimum) {throw "Too few input fields inspected on $page ($count)"}
 Save-Window $window ("form-"+$page)
 $script:formChecks+=@{page=$page;inputs=$count;vertical_alignment='passed';font='passed';padding='passed'}
}
Assert-FormLayout 'new-project' 2
# Clicking the padding around the native editor must focus the field too.
$frame=[WorkbenchUiCheck]::GetParent($first)
$paddingPoint=[IntPtr]((3 -shl 16) -bor 3)
[WorkbenchUiCheck]::SendMessageW($frame,0x201,[IntPtr]1,$paddingPoint) | Out-Null
[WorkbenchUiCheck]::SendMessageW($frame,0x202,[IntPtr]::Zero,$paddingPoint) | Out-Null
Start-Sleep -Milliseconds 200
if ([WorkbenchUiCheck]::Focus($window) -ne $first) {throw 'Clicking input padding did not focus the editor'}
Invoke-WorkbenchButton '服务器与实例'
Invoke-WorkbenchButton '+ 添加服务器'
Assert-FormLayout 'ssh-key' 4
Invoke-WorkbenchButton '密码'
Assert-FormLayout 'ssh-password' 5
# Only verify native ES_PASSWORD; never enter or capture a user credential.
$secure=@([WorkbenchUiCheck]::Children($window) | Where-Object { [WorkbenchUiCheck]::Class($_) -eq 'Edit' -and ([WorkbenchUiCheck]::GetWindowLongPtrW($_,-16).ToInt64() -band 0x20) -ne 0 })
if ($secure.Count -ne 1) {throw 'Password input lost native masking'}
Invoke-WorkbenchButton '共享 Relay'
Invoke-WorkbenchButton '+ 新建连接'
Assert-FormLayout 'shared-relay' 4
Invoke-WorkbenchButton '运行环境'
Save-Window $window 'form-runtime'
$script:formChecks | ConvertTo-Json -Depth 4 | Set-Content "$OutputDirectory/form-layout-acceptance.json"
