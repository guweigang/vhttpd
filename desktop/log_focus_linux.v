module main

import os
import ui2
import sokol.sapp

#include "@VMODROOT/desktop/workbench_window_linux.h"

fn C.vhttpd_workbench_activate_x11(voidptr, uint)

// The workbench's fixed frames were designed in macOS points (one logical
// pixel). ui2's Linux renderer uses 96-dpi points; keep text in those frames
// at the intended logical pixel size, while display scaling remains with ui2.
fn linux_pixel_layout(element ui2.Element) ui2.Element {
	mut children := []ui2.Element{cap: element.children.len}
	for child in element.children { children << linux_pixel_layout(child) }
	return ui2.Element{
		...element
		text_style: ui2.TextStyle{ ...element.text_style, size: element.text_style.size * 0.75 }
		children:   children
	}
}

fn configure_linux_fonts() {
	if os.getenv('UI2_FONT') != '' { return }
	dir := os.join_path(os.dir(os.executable()), 'fonts')
	regular := os.join_path(dir, 'NotoSansCJKsc-Regular.otf')
	bold := os.join_path(dir, 'NotoSansCJKsc-Bold.otf')
	if os.is_file(regular) {
		os.setenv('UI2_FONT', regular, true)
		if os.is_file(bold) { os.setenv('UI2_FONT_BOLD', bold, true) }
	}
}

// The custom ui2 backend owns the Linux window. A log handoff updates its
// mounted tree; no platform-specific AppKit handle is used.
fn configure_workbench_window(_handle voidptr) {
	// Some Linux graphics drivers probe in a child and wait for any child
	// during initialization. Start owned commands only after that phase, so
	// a driver cannot consume the runtime version process's exit status.
	mut app := unsafe { workshop }
	app.inspect_binary(app.binary, false)
	if app.projects.len > 0 { app.select_current() }
}

fn bring_workbench_forward() {
	ui2.scroll_to_rect('project_overview_page', 0, 520, 1, 190)
	C.vhttpd_workbench_activate_x11(sapp.x11_get_display(), uint(sapp.x11_get_window()))
}
