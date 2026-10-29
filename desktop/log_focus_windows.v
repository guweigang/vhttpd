module main

import ui2

#include "@VMODROOT/desktop/workbench_window_windows.h"

fn C.vhttpd_workbench_activate_windows(voidptr)

// ui2's Win32 backend has already created and shown the HWND at this point.
fn configure_workbench_window(_handle voidptr) {}

fn bring_workbench_forward() {
 C.vhttpd_workbench_activate_windows(ui2.native_window_handle())
}
