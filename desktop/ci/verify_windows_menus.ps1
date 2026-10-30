param([Parameter(Mandatory=$true)][int]$DesktopProcessId,[Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class WorkbenchMenuCheck {
 [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr menu,int position);
 [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
 [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr menu,int position);
 [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu,uint position,uint flags);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr menu,uint position,StringBuilder text,int count,uint flags);
}
'@
$window=(Get-Process -Id $DesktopProcessId).MainWindowHandle
function Menu-At([int]$index) {return [WorkbenchMenuCheck]::GetSubMenu([WorkbenchMenuCheck]::GetMenu($window),$index)}
function Menu-Index($menu,$title) {
 for ($i=0;$i -lt [WorkbenchMenuCheck]::GetMenuItemCount($menu);$i++) {
  $text=New-Object Text.StringBuilder 512
  [WorkbenchMenuCheck]::GetMenuStringW($menu,[uint32]$i,$text,$text.Capacity,0x400) | Out-Null
  if ($text.ToString().Split("`t")[0] -eq $title) {return $i}
 }
 throw "Menu item missing: $title"
}
function Menu-Enabled($menu,$title) {return ([WorkbenchMenuCheck]::GetMenuState($menu,[uint32](Menu-Index $menu $title),0x400) -band 3) -eq 0}
function Menu-Invoke($menu,$title) {
 if (!(Menu-Enabled $menu $title)) {throw "Menu unexpectedly disabled: $title"}
 $id=[WorkbenchMenuCheck]::GetMenuItemID($menu,(Menu-Index $menu $title))
 [WorkbenchUiCheck]::PostMessageW($window,0x111,[IntPtr]$id,[IntPtr]::Zero) | Out-Null
 Start-Sleep -Milliseconds 650
}
$bar=[WorkbenchMenuCheck]::GetMenu($window)
if ([WorkbenchMenuCheck]::GetMenuItemCount($bar) -ne 6) {throw 'Expected six top-level workbench menus'}
foreach ($title in @('项目','编辑','运行','环境','查看','帮助')) {Menu-Index $bar $title | Out-Null}
$environments=[WorkbenchMenuCheck]::GetSubMenu((Menu-At 3),0)
Menu-Invoke $environments '本机 Windows'
$environments=[WorkbenchMenuCheck]::GetSubMenu((Menu-At 3),0)
if (([WorkbenchMenuCheck]::GetMenuState($environments,0,0x400) -band 8) -eq 0) {throw 'Environment menu checkmark did not update'}
if (Menu-Enabled (Menu-At 2) '启动') {throw 'Empty project enables start'}
Menu-Invoke (Menu-At 0) '新建项目…'
$field=[WorkbenchUiCheck]::Focus($window)
if ([WorkbenchUiCheck]::Class($field) -ne 'Edit') {throw 'Menu New did not focus the project form'}
if (Menu-Enabled (Menu-At 0) '新建项目…') {throw 'Menu New stayed enabled while a project form is active'}
$fixture=[Runtime.InteropServices.Marshal]::StringToHGlobalUni('menu-shortcut-fixture')
try {[WorkbenchUiCheck]::SendMessageW($field,0x0C,[IntPtr]::Zero,$fixture) | Out-Null} finally {[Runtime.InteropServices.Marshal]::FreeHGlobal($fixture)}
# Direct WM_COMMAND must also be rejected for a currently disabled command.
$id=[WorkbenchMenuCheck]::GetMenuItemID((Menu-At 0),(Menu-Index (Menu-At 0) '新建项目…'))
[WorkbenchUiCheck]::PostMessageW($window,0x111,[IntPtr]$id,[IntPtr]::Zero) | Out-Null
Start-Sleep -Milliseconds 300
if ([WorkbenchUiCheck]::Text($field) -ne 'menu-shortcut-fixture') {throw 'Disabled command bypassed state validation'}
Menu-Invoke (Menu-At 1) '全选'
if (!(Menu-Enabled (Menu-At 1) '复制')) {throw 'Selection did not enable Copy'}
Menu-Invoke (Menu-At 1) '剪切'
if ([WorkbenchUiCheck]::Text($field) -ne '') {throw 'Menu Cut did not edit the focused field'}
Menu-Invoke (Menu-At 1) '粘贴'
if ([WorkbenchUiCheck]::Text($field) -ne 'menu-shortcut-fixture') {throw 'Menu Paste did not restore fixture text'}
Menu-Key 0x1B
Start-Sleep -Milliseconds 500
if (!(Menu-Enabled (Menu-At 0) '新建项目…')) {throw 'Returning from the form did not re-enable New'}
Menu-Invoke (Menu-At 0) '新建项目…'
Save-Window $window 'menus-new-project'
@{structure='passed';environment_checkmark='passed';empty_state='passed';native_menu_actions='passed';native_shortcuts='deferred';disabled_dispatch='passed';editing='passed'} | ConvertTo-Json | Set-Content "$OutputDirectory/menu-acceptance.json"
