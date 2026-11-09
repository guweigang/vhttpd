module main

import gg
import sokol.sapp

fn set_workbench_window_title(title string) {
	// Tests and initial preferences can run before the native window exists.
	if sapp.isvalid() { gg.set_window_title(title) }
}
