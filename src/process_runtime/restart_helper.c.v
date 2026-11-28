module process_runtime

$if !windows {
import os
}

$if !windows {
	#include "@VMODROOT/src/process_runtime/restart_helper.h"
	fn C.vhttpd_restart_detach(&char) int
}

pub fn detach_restart_helper(log_path string) ! {
	$if windows {
		return error('manual_restart_platform_unsupported')
	} $else {
		if C.vhttpd_restart_detach(log_path.str) != 0 { return error('restart_detach_failed') }
	}
}

// Only used for the original parent; the helper never signals a saved PID.
pub fn pid_alive(pid int) bool {
	$if windows {
		return false
	} $else {
		return C.kill(pid, 0) == 0
	}
}

pub fn terminate_self() {
	$if !windows {
		C.kill(os.getpid(), 15)
	}
}
