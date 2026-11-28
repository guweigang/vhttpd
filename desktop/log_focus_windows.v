module main

import ui2
import os

#include "@VMODROOT/desktop/workbench_window_windows.h"

fn C.vhttpd_workbench_activate_windows(voidptr)
fn C.vhttpd_workbench_hide_windows(voidptr)
fn C.vhttpd_workbench_configure_windows(voidptr)
fn C.vhttpd_workbench_verify_private_fonts() int

// ui2's Win32 backend has already created and shown the HWND at this point.
fn C.vhttpd_workbench_close_to_tray(voidptr, int)

fn set_workbench_close_to_tray(enabled bool) { C.vhttpd_workbench_close_to_tray(ui2.native_window_handle(), int(enabled)) }

fn configure_workbench_window(handle voidptr) {
	if handle != unsafe { nil } {
  C.vhttpd_workbench_configure_windows(handle)
		app := unsafe { workshop }
		configure_workbench_tray(app.brand_mark, @VMODROOT)
		set_workbench_close_to_tray(ui2.tray_visible())
		if marker := os.getenv_opt('VHTTPD_DESKTOP_CI_READY') {
			if C.vhttpd_workbench_verify_private_fonts() == 0 {
				eprintln('Bundled Sarasa Term SC font probe failed')
				set_workbench_close_to_tray(false)
				ui2.quit()
				return
			}
			os.write_file(marker, 'ready; Sarasa Term SC regular/bold; CJK glyphs verified') or {}
		}
	}
}

fn bring_workbench_forward() {
	C.vhttpd_workbench_activate_windows(ui2.native_window_handle())
}

fn hide_workbench_window() { C.vhttpd_workbench_hide_windows(ui2.native_window_handle()) }
