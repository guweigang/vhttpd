module socket_runtime

import net

#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>

fn C.fcntl(int, int, ...voidptr) int

struct C.pollfd {
	fd      i32
	events  i16
	revents i16
}

fn C.poll(&C.pollfd, u64, i32) i32
fn C.getsockopt(i32, i32, i32, voidptr, &u32) i32

pub fn duplicate(fd int) !int {
	owned := C.fcntl(fd, C.F_DUPFD_CLOEXEC, 0)
	if owned < 0 { return error('socket_interrupt_dup_failed') }
	return owned
}

pub fn protect(fd int) ! {
	flags := C.fcntl(fd, C.F_GETFD, 0)
	if flags < 0 || C.fcntl(fd, C.F_SETFD, flags | C.FD_CLOEXEC) < 0 {
		return error('socket_native_cloexec_failed')
	}
}

pub fn connect_pending(code int) bool {
	return code in [C.EINPROGRESS, C.EAGAIN, C.EINTR]
}

pub fn wait_writable(fd int, milliseconds int) !bool {
	mut event := C.pollfd{ fd: fd, events: C.POLLOUT }
	result := C.poll(&event, 1, milliseconds)
	if result < 0 {
		if net.error_code() == C.EINTR { return false }
		return error('socket_poll_failed')
	}
	return result > 0
}

pub fn connect_error(fd int) !int {
	mut code := i32(0)
	mut size := u32(sizeof(code))
	net.socket_error(C.getsockopt(fd, C.SOL_SOCKET, C.SO_ERROR, &code, &size))!
	return code
}
