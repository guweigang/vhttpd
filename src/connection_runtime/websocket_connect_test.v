module connection_runtime

import net
import net.websocket
import os
import time

fn connect_fd_count() int { return (os.ls('/dev/fd') or { panic(err) }).len }

fn test_stopped_run_cannot_allocate_or_publish_connect_session() {
	before := connect_fd_count()
	mut run := Run{}
	run.request_stop()
	mut client := websocket.new_client('ws://127.0.0.1:1') or { panic(err) }
	defer { close_client(mut client) }
	if mut unexpected := connect_websocket(mut client, mut run) {
		unexpected.release()
		panic('stopped run connected')
	} else {
		assert err.msg() == 'websocket_connect_cancelled'
	}
	assert run.session == none
	assert isnil(client.conn)
	assert connect_fd_count() == before
	close_client(mut client)
	close_client(mut client)
}

fn test_failed_connect_candidates_release_aliases_and_allow_next_attempt() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	address := listener.addr() or { panic(err) }
	listener.close() or { panic(err) }
	before := connect_fd_count()
	mut run := Run{}
	for _ in 0 .. 32 {
		mut client := websocket.new_client('ws://${address}') or { panic(err) }
		if mut unexpected := connect_websocket(mut client, mut run) {
			unexpected.release()
			panic('closed listener connected')
		}
		close_client(mut client)
		assert run.session == none
		assert !run.stopped()
	}
	assert connect_fd_count() == before
}

fn test_stopped_session_rejects_candidate_without_retaining_or_closing_borrowed_fd() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	mut session := &Session{}
	session.request_stop()
	if _ := session.retain_native(listener.sock.handle) {
		assert false
	}
	assert session.interrupt == none
	assert C.fcntl(i32(listener.sock.handle), C.F_GETFD, 0) >= 0
}

fn test_cancelled_connect_poll_exits_before_using_native_socket() {
	mut session := &Session{}
	session.request_stop()
	if _ := session.wait_connected(-1) {
		assert false
	} else {
		assert err.msg() == 'websocket_connect_cancelled'
	}
}

fn test_failed_connect_candidate_releases_interrupt_before_next_generation() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }
	mut session := &Session{}
	mut native := session.dial_tcp(address.str()) or { panic(err) }
	mut peer := listener.accept() or { panic(err) }
	defer { peer.close() or {} }
	old := session.interrupt or { panic('missing alias') }
	session.discard_connect_candidate()
	assert session.interrupt == none
	assert C.fcntl(i32(old), C.F_GETFD, 0) < 0
	native.close() or { panic(err) }
	mut replacement := session.dial_tcp(address.str()) or { panic(err) }
	defer { replacement.close() or {} }
	mut next_peer := listener.accept() or { panic(err) }
	defer { next_peer.close() or {} }
	session.request_stop()
	session.release()
	next_peer.set_read_timeout(time.second)
	mut buffer := []u8{len: 1}
	count := next_peer.read(mut buffer) or { 0 }
	assert count == 0
}
