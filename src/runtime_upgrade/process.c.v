module runtime_upgrade

$if linux {
	#include "@VMODROOT/src/runtime_upgrade/process_linux.h"
	fn C.vhttpd_upgrade_pidfd_open(int) int
	fn C.vhttpd_upgrade_pidfd_term(int) int
	fn C.close(int) int
}

fn signal_checked(p Identity) ! {
	$if linux {
		fd := C.vhttpd_upgrade_pidfd_open(p.pid)
		if fd < 0 { return error('process_identity_unavailable') }
		defer { C.close(fd) }
		// The handle pins process identity across the verification/signal window.
		if !p.alive() { return error('process_identity_changed') }
		if C.vhttpd_upgrade_pidfd_term(fd) != 0 { return error('process_identity_changed') }
	} $else {
		return error('upgrade_platform_unsupported')
	}
}
