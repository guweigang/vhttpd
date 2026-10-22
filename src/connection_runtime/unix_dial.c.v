module connection_runtime

import net
import net.unix
import time

// Own the candidate from allocation through connect and wrapper creation.
// unix.connect_stream returns from failed connect without closing its socket.
pub fn dial_unix(path string) !&unix.StreamConn {
	// Match the SDK's portable Unix path limit and reject truncated destinations.
	if path.len == 0 || path.contains('\x00') { return error('invalid Unix socket path') }
	if path.len >= 104 { return error('Socket path too long! Max length: 103 chars.') }
	addresses := net.resolve_addrs(path, .unix, .tcp)!
	address := addresses[0]
	fd := $if is_coroutine ? {
		net.socket_error(C.photon_socket(i32(net.AddrFamily.unix), i32(net.SocketType.tcp), 0))!
	} $else {
		net.socket_error(C.socket(i32(net.AddrFamily.unix), i32(net.SocketType.tcp), 0))!
	}
	mut transferred := false
	defer { if !transferred { net.close(fd) or {} } }
	net.socket_error_message(C.fcntl(i32(fd), C.F_SETFD, C.FD_CLOEXEC),
		'setting Unix connection close-on-exec failed')!
	$if net_nonblocking_sockets ? {
		net.set_blocking(fd, false)!
	}
	connected := $if is_coroutine ? {
		C.photon_connect(i32(fd), voidptr(&address), address.len(), 30 * time.second)
	} $else {
		C.connect(i32(fd), voidptr(&address), address.len())
	}
	net.socket_error(connected)!
	socket := unix.stream_socket_from_handle(fd)!
	mut conn := &unix.StreamConn{ sock: *socket }
	// Preserve the SDK's default I/O timeouts; request dispatch may override them.
	conn.set_read_timeout(30 * time.second)
	conn.set_write_timeout(30 * time.second)
	transferred = true
	return conn
}
