module ws

import net
import os
import time

fn ingress_inheritance_pair() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }
	peer := net.dial_tcp(address.str()) or { panic(err) }
	server := listener.accept() or { panic(err) }
	return server, peer
}

fn ingress_assert_exec_excludes(native int, interrupt int, control int) {
	mut child := os.new_process(os.find_abs_path_of_executable('test') or { panic(err) })
	defer { child.close() }
	child.set_args(['-S', '/dev/fd/${control}', '-a', '!', '-S', '/dev/fd/${native}', '-a', '!',
		'-S', '/dev/fd/${interrupt}'])
	child.run()
	assert child.pid > 0
	child.wait()
	assert child.code == 0
}

fn ingress_exercise_native_inheritance(outbound bool, protected bool) {
	mut owner := &IngressOwner{}
	mut run := owner.reserve() or { panic('reserve') }
	defer { run.finish() }
	mut server, mut dialed := ingress_inheritance_pair()
	defer {
		server.close() or {}
		dialed.close() or {}
	}
	mut original := if outbound { dialed } else { server }
	mut peer := if outbound { server } else { dialed }
	fd := original.sock.handle
	assert C.fcntl(fd, C.F_SETFD, if protected { C.FD_CLOEXEC } else { 0 }) == 0
	control := C.fcntl(fd, C.F_DUPFD, 0)
	assert control >= 0
	defer { net.close(control) or {} }
	assert run.attach(fd)
	interrupt := run.handles[0]
	ingress_assert_exec_excludes(fd, interrupt, control)
	assert C.fcntl(fd, C.F_GETFD, 0) & C.FD_CLOEXEC != 0
	run.finish()
	run.finish()
	assert C.fcntl(interrupt, C.F_GETFD, 0) < 0
	assert C.fcntl(fd, C.F_GETFD, 0) & C.FD_CLOEXEC != 0
	peer.write_string('caller owns native') or { panic(err) }
	original.set_read_timeout(time.second)
	mut bytes := []u8{len: 32}
	n := original.read(mut bytes) or { panic(err) }
	assert bytes[..n].bytestr() == 'caller owns native'
	assert owner.active() == 0
}

fn test_ingress_excludes_accepted_native_and_interrupt_from_exec() {
	ingress_exercise_native_inheritance(false, false)
}

fn test_ingress_excludes_outbound_native_and_interrupt_from_exec() {
	ingress_exercise_native_inheritance(true, false)
}

fn test_ingress_preserves_native_protection_and_caller_ownership() {
	ingress_exercise_native_inheritance(false, true)
}
