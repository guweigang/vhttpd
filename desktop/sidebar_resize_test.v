module main

import os
import ui2

fn test_sidebar_window_shrink_keeps_preference_and_content_readable() {
	preferred := 340.0
	assert sidebar_visible_width(preferred, 980) == 340
	assert sidebar_visible_width(preferred, 760) == 214
	assert 760 - sidebar_visible_width(preferred, 760) - sidebar_content_insets >= sidebar_content_min_width
	assert sidebar_visible_width(preferred, 980) == 340
	assert sidebar_visible_width(200, 760) == 200
}

fn sidebar_pointer(phase string, x f64) ui2.PointerEvent {
	return ui2.PointerEvent{action: sidebar_resize_id, phase: phase, x: x, y: 180}
}

fn test_sidebar_drag_commits_on_release_and_double_click_resets() {
	mut state := SidebarResize{}
	assert !state.pointer(sidebar_pointer('down', 214), 980, 1000)
	assert !state.pointer(sidebar_pointer('drag', 314), 980, 1100)
	assert state.width == 314
	assert state.pointer(sidebar_pointer('up', 314), 980, 1150)
	// The drag must not count as the first click of a reset.
	assert !state.pointer(sidebar_pointer('down', 314), 980, 1200)
	assert state.width == 314
	assert !state.pointer(sidebar_pointer('up', 314), 980, 1250)
	assert state.pointer(sidebar_pointer('down', 314), 980, 1350)
	assert state.width == sidebar_default_width
	assert !state.dragging
	assert !state.pointer(sidebar_pointer('up', 314), 980, 1400)
}

fn test_sidebar_click_while_window_is_narrow_does_not_overwrite_wide_preference() {
	mut state := SidebarResize{width: 340}
	assert !state.pointer(sidebar_pointer('down', 214), 760, 1000)
	assert !state.pointer(sidebar_pointer('up', 214), 760, 1050)
	assert state.width == 340
	assert !state.pointer(sidebar_pointer('down', 214), 760, 2000)
	assert !state.pointer(sidebar_pointer('drag', 500), 760, 2100)
	assert state.width == 214
	assert state.pointer(sidebar_pointer('up', 500), 760, 2150)
}

fn test_sidebar_saved_width_survives_reload_and_invalid_values_fall_back() ! {
	root := os.join_path(os.temp_dir(), 'vhttpd-sidebar-width-' + os.getpid().str())
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'width')
	assert load_sidebar_width(path) == sidebar_default_width
	save_sidebar_width(path, 302)!
	assert load_sidebar_width(path) == 302
	save_sidebar_width(path, sidebar_default_width)!
	assert load_sidebar_width(path) == sidebar_default_width
	for invalid in ['garbage', 'NaN', 'inf', '100', '9999'] {
		os.write_file(path, invalid)!
		assert load_sidebar_width(path) == sidebar_default_width
	}
}
