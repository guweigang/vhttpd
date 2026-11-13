module main

import os
import ui2

fn configure_workbench_tray(brand_mark string, root string) {
	if !ui2.tray_supported() { return }
	mut icon := if os.is_file(brand_mark) { brand_mark } else { 'symbol:server.rack' }
	$if windows {
		icon = os.join_path(os.dir(brand_mark), 'vhttpd-windows.ico')
		if !os.is_file(icon) {
			icon = os.join_path(root, 'desktop', 'assets', 'vhttpd-windows.ico')
		}
	}
	set_workbench_tray(icon)
}

fn set_workbench_tray(icon string) {
	app := unsafe { workshop }
	ui2.set_tray(ui2.TrayConfig{
		icon: icon
		tooltip: 'vhttpd Workbench'
		menu: workbench_tray_menu(!app.creating)
	})
}

fn workbench_tray_menu(available bool) []ui2.MenuItem {
	return [
		ui2.menu_item('tray:open', ui_text('打开工作台')),
		ui2.MenuItem{...ui2.menu_item('tray:updates', ui_text('检查更新…')), enabled: available},
		ui2.menu_separator(),
		ui2.menu_item('tray:quit', ui_text('退出工作台')),
	]
}

fn (app &Workshop) refresh_workbench_tray() {
	if !ui2.tray_visible() { return }
	current := ui2.tray()
	menu := workbench_tray_menu(!app.creating)
	if current.menu != menu { ui2.set_tray(ui2.TrayConfig{...current, menu: menu}) }
}
