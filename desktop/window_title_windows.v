module main

$if ui2_custom_rendering ? {
	import gg
	import sokol.sapp

	fn set_workbench_window_title(title string) {
		if sapp.isvalid() { gg.set_window_title(title) }
	}
} $else {
	import ui2

	fn set_workbench_window_title(title string) {
		ui2.set_window_title(title)
	}
}
