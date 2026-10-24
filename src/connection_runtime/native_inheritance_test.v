module connection_runtime

import net
import net.websocket
import os
import time

// A positive inheritable control distinguishes descriptor exclusion from a
// child process implementation that closes every descriptor before exec.
fn assert_native_fd_excluded(fd int, control int) {
	mut child := os.new_process(os.find_abs_path_of_executable('test') or { panic(err) })
	defer { child.close() }
	child.set_args(['-S', '/dev/fd/${control}', '-a', '!', '-S', '/dev/fd/${fd}'])
	child.run()
	assert child.pid > 0
	child.wait()
	assert child.code == 0
}

fn exercise_native_session_inheritance(outbound bool, already_protected bool) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }
	mut dialed := net.dial_tcp(address.str()) or { panic(err) }
	defer { dialed.close() or {} }
	mut accepted := listener.accept() or { panic(err) }
	defer { accepted.close() or {} }
	mut native := if outbound { dialed } else { accepted }
	mut remote := if outbound { accepted } else { dialed }
	native.set_read_timeout(time.second)
	fd := native.sock.handle
	// Model both SDK defaults and an allocator that has already protected it.
	assert C.fcntl(fd, C.F_SETFD, if already_protected { C.FD_CLOEXEC } else { 0 }) == 0
	control := C.fcntl(fd, C.F_DUPFD, 0)
	assert control >= 0
	defer { net.close(control) or {} }
	assert C.fcntl(control, C.F_GETFD, 0) & C.FD_CLOEXEC == 0
	mut session := Session.connected(&websocket.Client{ conn: native }) or { panic(err) }
	defer { session.release() }
	interrupt := session.interrupt or { panic('missing interrupt') }
	assert_native_fd_excluded(fd, control)
	assert_native_fd_excluded(interrupt, control)
	session.release()
	session.release()
	assert C.fcntl(fd, C.F_GETFD, 0) & C.FD_CLOEXEC != 0
	// Releasing the interrupt must preserve the caller-owned native connection.
	remote.write_string('caller owns native') or { panic(err) }
	mut buffer := []u8{len: 32}
	count := native.read(mut buffer) or { panic(err) }
	assert buffer[..count].bytestr() == 'caller owns native'
}

fn test_outbound_session_excludes_native_socket_from_exec() {
	exercise_native_session_inheritance(true, false)
}

fn test_accepted_session_excludes_native_socket_from_exec() {
	exercise_native_session_inheritance(false, false)
}

fn test_session_preserves_already_protected_native_socket_and_caller_ownership() {
	exercise_native_session_inheritance(true, true)
}
