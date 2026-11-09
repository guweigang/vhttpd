module main

import macos
import ui2

#include "@VMODROOT/desktop/workbench_window.h"

fn C.vhttpd_workbench_window_minimum(voidptr, f64, f64)
fn C.vhttpd_workbench_window_content_floor(voidptr, f64, f64)

fn configure_workbench_window(_handle voidptr) {
	// Read the published NSWindow directly. The current V compiler passes the
	// address of ui2's aliased NativeView in the ready callback, rather than
	// its value; treating that callback argument as an ObjC object crashes.
	C.vhttpd_workbench_window_minimum(ui2.native_window_handle(), 760, 660)
	ui2.on_window_resize(constrain_workbench_window)
	configure_platform_menus()
}

fn constrain_workbench_window(_width int, _height int) {
	C.vhttpd_workbench_window_content_floor(ui2.native_window_handle(), 760, 660)
}

fn bring_workbench_forward() {
	window := macos.Id(ui2.native_window_handle())
	if window == unsafe { nil } { return }
	app := macos.msg_id(macos.get_class('NSApplication'), 'sharedApplication')
	macos.msg_void1(window, 'deminiaturize:', unsafe { nil })
	macos.msg_void1(window, 'makeKeyAndOrderFront:', unsafe { nil })
	macos.msg_void_bool(app, 'activateIgnoringOtherApps:', true)
}
