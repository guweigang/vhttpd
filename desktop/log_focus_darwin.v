module main

import macos
import ui2

#include "@VMODROOT/desktop/workbench_window.h"

fn C.vhttpd_workbench_window_minimum(f64, f64)

fn configure_workbench_window(_handle voidptr) {
	C.vhttpd_workbench_window_minimum(760, 660)
	configure_platform_menus()
}

fn bring_workbench_forward() {
	window := macos.Id(ui2.native_window_handle())
	if window == unsafe { nil } { return }
	app := macos.msg_id(macos.get_class('NSApplication'), 'sharedApplication')
	macos.msg_void1(window, 'deminiaturize:', unsafe { nil })
	macos.msg_void1(window, 'makeKeyAndOrderFront:', unsafe { nil })
	macos.msg_void_bool(app, 'activateIgnoringOtherApps:', true)
}
