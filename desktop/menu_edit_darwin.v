module main

import macos
import ui2

fn menu_text_has_selection() bool {
	if ui2.focused_id() == '' { return false }
	window := macos.Id(ui2.native_window_handle())
	if window == unsafe { nil } { return false }
	responder := macos.msg_id(window, 'firstResponder')
	if responder == unsafe { nil } || !macos.msg_bool_id(responder, 'respondsToSelector:', macos.Id(voidptr(macos.sel('selectedRange')))) { return false }
	return macos.msg_range(responder, 'selectedRange').length > 0
}

fn menu_text_edit(action string) {
	selector := match action { 'all' { 'selectAll:' } 'cut' { 'cut:' } 'copy' { 'copy:' } 'paste' { 'paste:' } else { return } }
	app := macos.msg_id(macos.get_class('NSApplication'), 'sharedApplication')
	macos.msg_bool_sel_id_id(app, 'sendAction:to:from:', macos.sel(selector), unsafe { nil }, unsafe { nil })
}

fn C.vhttpd_workbench_configure_app_menu()
fn C.vhttpd_workbench_menu_tracking() int

fn configure_platform_menus() { C.vhttpd_workbench_configure_app_menu() }

fn menu_window_action(action string) {
	window := macos.Id(ui2.native_window_handle())
	selector := match action { 'minimize' { 'performMiniaturize:' } 'zoom' { 'performZoom:' } 'fullscreen' { 'toggleFullScreen:' } else { return } }
	if window != unsafe { nil } { macos.msg_void1(window, selector, unsafe { nil }) }
}
