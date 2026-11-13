module main

import ui2
import os

#flag windows -ldwmapi
#include "@VMODROOT/desktop/workbench_window_windows.h"

fn C.vhttpd_workbench_activate_windows(voidptr)
fn C.vhttpd_workbench_configure_windows(voidptr)
fn C.vhttpd_workbench_verify_private_fonts() int
fn C.vhttpd_workbench_set_windows_appearance(voidptr, int)

// ui2's Win32 backend has already created and shown the HWND at this point.
fn configure_workbench_window(handle voidptr) {
	if handle != unsafe { nil } {
  C.vhttpd_workbench_configure_windows(handle)
		update_workbench_windows_appearance(handle)
		app := unsafe { workshop }
		configure_workbench_tray(app.brand_mark, @VMODROOT)
		if marker := os.getenv_opt('VHTTPD_DESKTOP_CI_READY') {
			if C.vhttpd_workbench_verify_private_fonts() == 0 {
				eprintln('Bundled Sarasa Term SC font probe failed')
				ui2.quit()
				return
			}
			os.write_file(marker, 'ready; Sarasa Term SC regular/bold; CJK glyphs verified') or {}
		}
	}
}

fn update_workbench_windows_appearance(handle voidptr) {
	dark := ui2.component_theme_mode_is_dark(workbench_appearance_mode, workbench_system_appearance)
	C.vhttpd_workbench_set_windows_appearance(handle, if dark { 1 } else { 0 })
}

fn bring_workbench_forward() {
	C.vhttpd_workbench_activate_windows(ui2.native_window_handle())
}
