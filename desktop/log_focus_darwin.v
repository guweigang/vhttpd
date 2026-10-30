module main

import macos

#include "@VMODROOT/desktop/workbench_window.h"

fn C.vhttpd_workbench_window_minimum(f64, f64)

fn configure_workbench_window(_handle voidptr) {
	C.vhttpd_workbench_window_minimum(760, 660)
	configure_platform_menus()
}

fn bring_workbench_forward() {
	app := macos.msg_id(macos.get_class('NSApplication'), 'sharedApplication')
	mut window := macos.msg_id(app, 'mainWindow')
	if window == unsafe { nil } {
		windows := macos.msg_id(app, 'windows')
		if macos.msg_u64(windows, 'count') > 0 { window = macos.msg_id_u64(windows, 'objectAtIndex:', 0) }
	}
	macos.msg_void1(window, 'deminiaturize:', unsafe { nil })
	macos.msg_void1(window, 'makeKeyAndOrderFront:', unsafe { nil })
	macos.msg_void_bool(app, 'activateIgnoringOtherApps:', true)
}
