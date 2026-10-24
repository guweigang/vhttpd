module listener_runtime

import net.unix
import os
import time

fn inheritance_path() string {
	return '/tmp/vhttpd-accepted-fd-${os.getpid()}-${time.sys_mono_now()}.sock'
}

fn inherited_socket_in_child(fd int) bool {
	executable := os.find_abs_path_of_executable('test') or { panic(err) }
	mut child := os.new_process(executable)
	defer { child.close() }
	// Exec a POSIX utility directly: no shell or subprocess library closes the fd.
	child.set_args(['-S', '/dev/fd/${fd}'])
	child.run()
	assert child.pid > 0
	child.wait()
	assert child.code == 0 || child.code == 1
	return child.code == 0
}

fn test_accepted_connection_is_cloexec_before_publication_and_still_usable() {
	path := inheritance_path()
	mut listener := listen(path) or { panic(err) }
	defer { listener.close() or {} }
	mut peer := unix.connect_stream(path) or { panic(err) }
	defer { peer.close() or {} }
	mut conn := listener.accept() or { panic(err) }
	defer { conn.close() or {} }
	assert C.fcntl(i32(listener.native.sock.handle), C.F_GETFD) & C.FD_CLOEXEC != 0
	assert C.fcntl(i32(conn.sock.handle), C.F_GETFD) & C.FD_CLOEXEC != 0
	peer.write_string('request') or { panic(err) }
	mut buffer := []u8{len: 7}
	assert conn.read(mut buffer) or { panic(err) } == 7
	assert buffer.bytestr() == 'request'
	conn.write_string('reply') or { panic(err) }
	mut reply := []u8{len: 5}
	assert peer.read(mut reply) or { panic(err) } == 5
	assert reply.bytestr() == 'reply'
}

fn test_exec_child_does_not_inherit_published_listener_or_accepted_socket() {
	path := inheritance_path()
	mut listener := listen(path) or { panic(err) }
	defer { listener.close() or {} }
	mut peer := unix.connect_stream(path) or { panic(err) }
	defer { peer.close() or {} }
	mut conn := listener.accept() or { panic(err) }
	defer { conn.close() or {} }
	assert !inherited_socket_in_child(listener.native.sock.handle)
	assert !inherited_socket_in_child(conn.sock.handle)
	conn.write_string('live') or { panic(err) }
	mut reply := []u8{len: 4}
	assert peer.read(mut reply) or { panic(err) } == 4
	assert reply.bytestr() == 'live'
}

fn test_closing_listener_does_not_release_the_handlers_accepted_connection() {
	path := inheritance_path()
	mut listener := listen(path) or { panic(err) }
	defer { listener.close() or {} }
	mut peer := unix.connect_stream(path) or { panic(err) }
	defer { peer.close() or {} }
	mut conn := listener.accept() or { panic(err) }
	defer { conn.close() or {} }
	listener.close() or { panic(err) }
	assert !os.exists(path)
	assert C.fcntl(i32(conn.sock.handle), C.F_GETFD) & C.FD_CLOEXEC != 0
	peer.write_string('held') or { panic(err) }
	mut buffer := []u8{len: 4}
	assert conn.read(mut buffer) or { panic(err) } == 4
	assert buffer.bytestr() == 'held'
}

fn test_request_owner_and_reused_accepted_fds_are_not_inherited() {
	path := inheritance_path()
	mut owner := Owner{}
	generation := owner.reserve() or { panic('reservation') }
	mut listener := listen(path) or { panic(err) }
	assert owner.publish(generation, listener)
	defer { assert owner.finish(generation) }
	for i in 0 .. 24 {
		mut peer := unix.connect_stream(path) or { panic(err) }
		mut conn := listener.accept() or { panic(err) }
		request := owner.accept_request(generation, conn.sock.handle) or { panic('admission') }
		assert C.fcntl(i32(conn.sock.handle), C.F_GETFD) & C.FD_CLOEXEC != 0
		duplicate := owner.requests[request].interrupt
		assert C.fcntl(i32(duplicate), C.F_GETFD) & C.FD_CLOEXEC != 0
		if i == 0 {
			assert !inherited_socket_in_child(conn.sock.handle)
			assert !inherited_socket_in_child(duplicate)
		}
		conn.close() or { panic(err) }
		owner.complete_request(request)
		peer.close() or { panic(err) }
	}
	assert owner.active_requests(generation) == 0
}
