module process_runtime

import os

#include "@VMODROOT/src/process_runtime/shutdown_windows.h"

fn C.vhttpd_shutdown_console_install() int
fn C.vhttpd_shutdown_console_wait() int
fn C.vhttpd_shutdown_console_finished()

fn windows_shutdown_signal_loop(handler fn (os.Signal)) {
	sig := C.vhttpd_shutdown_console_wait()
	if sig < 0 { return }
	handler(unsafe { os.Signal(sig) })
	C.vhttpd_shutdown_console_finished()
}

pub fn install_shutdown_signal_handler(handler fn (os.Signal)) ! {
	if C.vhttpd_shutdown_console_install() == 0 {
		return error('shutdown_console_handler_install_failed')
	}
	spawn windows_shutdown_signal_loop(handler)
}
