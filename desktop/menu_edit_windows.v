module main

fn C.vhttpd_workbench_edit_selection() int
fn C.vhttpd_workbench_edit_command(int)

fn menu_text_has_selection() bool { return C.vhttpd_workbench_edit_selection() != 0 }
fn menu_text_edit(action string) {
	C.vhttpd_workbench_edit_command(match action { 'all' { 0 } 'cut' { 1 } 'copy' { 2 } 'paste' { 3 } else { return } })
}
fn configure_platform_menus() {}
fn menu_window_action(_action string) {}
