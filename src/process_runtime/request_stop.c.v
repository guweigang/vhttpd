module process_runtime

import os

$if windows {
	#include "@VMODROOT/src/process_runtime/request_stop_windows.h"
	fn C.vhttpd_request_process_stop(int) int
}

// The caller must retain its os.Process until exit is observed and reaped.
// Desktop and standalone launchers share the same graceful shutdown boundary.
pub fn request_owned_process_stop(mut process os.Process) ! {
	if !process.is_alive() { return }
	$if windows {
		if C.vhttpd_request_process_stop(process.pid) == 0 {
			return error('runtime_shutdown_event_unavailable')
		}
	} $else {
		process.signal_term()
	}
}
