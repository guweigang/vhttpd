module protocol

import net
import os
import time

fn mcp_inheritance_pair() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }
	peer := net.dial_tcp(address.str()) or { panic(err) }
	server := listener.accept() or { panic(err) }
	return server, peer
}

fn mcp_inheritance_read(mut peer net.TcpConn, marker string) string {
	mut text := ''
	mut bytes := []u8{len: 4096}
	for !text.contains(marker) {
		n := peer.read(mut bytes) or { panic(err) }
		assert n > 0
		text += bytes[..n].bytestr()
	}
	return text
}

fn mcp_assert_exec_excludes(native int, interrupt int, control int) {
	mut child := os.new_process(os.find_abs_path_of_executable('test') or { panic(err) })
	defer { child.close() }
	child.set_args(['-S', '/dev/fd/${control}', '-a', '!', '-S', '/dev/fd/${native}', '-a', '!',
		'-S', '/dev/fd/${interrupt}'])
	child.run()
	assert child.pid > 0
	child.wait()
	assert child.code == 0
}

fn mcp_exercise_native_inheritance(protected bool) {
	mut state := McpState{}
	state.ensure_session('owned', '', '', '', '')
	mut server, mut peer := mcp_inheritance_pair()
	defer { peer.close() or {} }
	fd := server.sock.handle
	assert C.fcntl(i32(fd), C.F_SETFD, if protected { C.FD_CLOEXEC } else { 0 }) == 0
	control := C.fcntl(i32(fd), C.F_DUPFD, 0)
	assert control >= 0
	defer { net.close(control) or {} }
	mut stream := state.attach_stream('owned', server) or { panic(err) }
	defer { state.finish_stream('owned', mut stream) }
	interrupt := stream.interrupt or { panic('missing interrupt') }
	mcp_assert_exec_excludes(fd, interrupt, control)
	assert C.fcntl(i32(fd), C.F_GETFD, 0) & C.FD_CLOEXEC != 0
	stream.start(fn (mut _ net.TcpConn) ! {}) or { panic(err) }
	peer.set_read_timeout(time.second)
	assert mcp_inheritance_read(mut peer, ': connected\n\n') == ': connected\n\n'
	state.finish_stream('owned', mut stream)
	state.finish_stream('owned', mut stream)
	assert C.fcntl(i32(fd), C.F_GETFD, 0) < 0
	assert C.fcntl(i32(interrupt), C.F_GETFD, 0) < 0
	assert state.active_streams() == 0
}

fn test_mcp_stream_excludes_original_and_interrupt_from_exec() {
	mcp_exercise_native_inheritance(false)
}

fn test_mcp_stream_preserves_existing_native_protection_and_close_owner() {
	mcp_exercise_native_inheritance(true)
}
