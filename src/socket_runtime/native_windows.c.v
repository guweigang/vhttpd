module socket_runtime

#include "@VMODROOT/src/socket_runtime/windows.h"

fn C.vhttpd_socket_duplicate(int) int
fn C.vhttpd_socket_protect(int) int
fn C.vhttpd_socket_wait_writable(int, int) int
fn C.vhttpd_socket_connect_error(int, &int) int

pub fn duplicate(fd int) !int {
	owned := C.vhttpd_socket_duplicate(fd)
	if owned < 0 { return error('socket_interrupt_dup_failed') }
	return owned
}

pub fn protect(fd int) ! {
	if C.vhttpd_socket_protect(fd) == 0 { return error('socket_native_noinherit_failed') }
}

pub fn connect_pending(code int) bool {
	return code in [10035, 10036, 10004] // WSAEWOULDBLOCK, WSAEINPROGRESS, WSAEINTR
}

pub fn wait_writable(fd int, milliseconds int) !bool {
	result := C.vhttpd_socket_wait_writable(fd, milliseconds)
	if result < 0 { return error('socket_poll_failed') }
	return result > 0
}

pub fn connect_error(fd int) !int {
	mut code := 0
	if C.vhttpd_socket_connect_error(fd, &code) != 0 {
		return error('socket_connect_status_failed')
	}
	return code
}
