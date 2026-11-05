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
	ui2.set_tray(ui2.TrayConfig{
		icon: icon
		tooltip: 'vhttpd Workbench'
		menu: [
			ui2.menu_item('tray:open', '打开工作台'),
			ui2.menu_separator(),
			ui2.menu_item('tray:quit', '退出工作台'),
		]
	})
}
