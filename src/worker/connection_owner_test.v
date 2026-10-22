module worker

import net.unix
import net
import os
import time
import upstream.transport

#include <fcntl.h>

fn C.fcntl(fd i32, cmd i32, arg ...voidptr) i32
fn C.dup2(int, int) int
fn C.close(int) int

struct ConnectionPair {
	client &unix.StreamConn @[required]
	peer   &unix.StreamConn @[required]
}

fn connection_pair(label string) ConnectionPair {
	path := os.join_path(os.temp_dir(), 'vhttpd-connection-${label}-${os.getpid()}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	client := unix.connect_stream(path) or { panic(err) }
	// V's Unix timeout polling is enabled on nonblocking sockets.
	net.set_blocking(client.sock.handle, false) or { panic(err) }
	peer := listener.accept() or { panic(err) }
	return ConnectionPair{ client: client, peer: peer }
}

fn test_repeated_close_cannot_close_a_reused_descriptor() {
	pair := connection_pair('repeat')
	mut peer := pair.peer
	defer { peer.close() or {} }
	fd := pair.client.sock.handle
	mut conn := WorkerBackendConnection.from_selected('test', *pair.client)
	conn.close()
	assert C.fcntl(fd, C.F_GETFD, 0) < 0
	assert C.dup2(peer.sock.handle, fd) == fd
	defer { C.close(fd) }
	conn.close()
	assert C.fcntl(fd, C.F_GETFD, 0) >= 0
}

fn test_copied_wrapper_shares_close_ownership() {
	pair := connection_pair('copy')
	mut peer := pair.peer
	defer { peer.close() or {} }
	fd := pair.client.sock.handle
	mut conn := WorkerBackendConnection.from_selected('test', *pair.client)
	mut copy := conn
	conn.close()
	assert C.dup2(peer.sock.handle, fd) == fd
	defer { C.close(fd) }
	copy.close()
	assert C.fcntl(fd, C.F_GETFD, 0) >= 0
}

@[heap]
struct ConnectionFinishProbe {
mut:
	finishes int
}

fn test_dispatch_closes_transport_before_finishing_worker_accounting() {
	pair := connection_pair('dispatch')
	mut peer := pair.peer
	defer { peer.close() or {} }
	fd := pair.client.sock.handle
	mut conn := WorkerBackendConnection.from_selected('test', *pair.client)
	defer { conn.close() }
	WorkerBackendFrameCodec.write(mut peer, '{"mode":"stream","event":"end"}') or { panic(err) }
	mut probe := &ConnectionFinishProbe{}
	ctx := DispatchContext{
		open_fn:   fn [conn] () !WorkerBackendConnection { return conn }
		finish_fn: fn [mut probe, fd] (socket string) {
			assert socket == 'test'
			probe.finishes++
			assert C.fcntl(fd, C.F_GETFD, 0) < 0
		}
	}
	result := DispatchRuntime.stream(ctx, transport.StreamDispatchRequest{}) or { panic(err) }
	assert result.event == 'end'
	assert probe.finishes == 1
}

fn test_empty_and_closed_connections_have_no_usable_handle() {
	mut conn := WorkerBackendConnection{}
	assert conn.owner.conn == none
	conn.close()
	conn.close()
	conn.apply_read_timeout(10)
	if _ := conn.write_payload('ignored') {
		assert false
	} else {
		assert err.msg() == 'worker_connection_closed'
	}
	if _ := conn.write_json(transport.StreamDispatchRequest{}) {
		assert false
	} else {
		assert err.msg() == 'worker_connection_closed'
	}
	if _ := conn.write_websocket_frame(transport.WorkerWebSocketFrame{}) {
		assert false
	} else {
		assert err.msg() == 'worker_connection_closed'
	}
	if _ := conn.read_stream_response() {
		assert false
	} else {
		assert err.msg() == 'worker_connection_closed'
	}
	if _ := conn.read_mcp_response() {
		assert false
	} else {
		assert err.msg() == 'worker_connection_closed'
	}
	if _ := conn.read_websocket_upstream_response() {
		assert false
	} else {
		assert err.msg() == 'worker_connection_closed'
	}
	if _ := conn.read_websocket_dispatch_response() {
		assert false
	} else {
		assert err.msg() == 'worker_connection_closed'
	}
}

fn test_separate_owners_preserve_live_connection_after_other_owner_closes() {
	first := connection_pair('isolated-first')
	second := connection_pair('isolated-second')
	mut first_peer := first.peer
	mut second_peer := second.peer
	defer {
		first_peer.close() or {}
		second_peer.close() or {}
	}
	mut a := WorkerBackendConnection.from_selected('first', *first.client)
	mut b := WorkerBackendConnection.from_selected('second', *second.client)
	defer { b.close() }
	a.close()
	if _ := a.write_payload('stale') {
		assert false
	} else {
		assert err.msg() == 'worker_connection_closed'
	}
	b.write_payload('live') or { panic(err) }
	assert WorkerBackendFrameCodec.read(mut second_peer) or { panic(err) } == 'live'
	assert C.fcntl(second.client.sock.handle, C.F_GETFD, 0) >= 0
}

fn test_concurrent_alias_closes_release_transport_once() {
	pair := connection_pair('concurrent')
	mut peer := pair.peer
	defer { peer.close() or {} }
	mut conn := WorkerBackendConnection.from_selected('test', *pair.client)
	mut joins := []thread{}
	for _ in 0 .. 8 {
		mut copy := conn
		joins << spawn fn [mut copy] () { copy.close() }()
	}
	joins.wait()
	fd := pair.client.sock.handle
	assert C.dup2(peer.sock.handle, fd) == fd
	defer { C.close(fd) }
	conn.close()
	if _ := conn.read_stream_response() {
		assert false
	} else {
		assert err.msg() == 'worker_connection_closed'
	}
	assert C.fcntl(fd, C.F_GETFD, 0) >= 0
}

fn test_dispatch_error_paths_close_before_finishing_exactly_once() {
	for mode in 0 .. 4 {
		for write_failure in [false, true] {
			pair := connection_pair('error-${mode}-${write_failure}')
			mut peer := pair.peer
			if write_failure {
				peer.close() or { panic(err) }
			} else {
				WorkerBackendFrameCodec.write(mut peer, '{') or { panic(err) }
			}
			fd := pair.client.sock.handle
			mut conn := WorkerBackendConnection.from_selected('error', *pair.client)
			mut probe := &ConnectionFinishProbe{}
			ctx := DispatchContext{
				open_fn:   fn [conn] () !WorkerBackendConnection { return conn }
				finish_fn: fn [mut probe, fd] (_ string) {
					probe.finishes++
					assert C.fcntl(fd, C.F_GETFD, 0) < 0
				}
			}
			mut failed := false
			match mode {
				0 {
					DispatchRuntime.stream(ctx, transport.StreamDispatchRequest{}) or { failed = true }
				}
				1 {
					DispatchRuntime.mcp(ctx, transport.WorkerMcpDispatchRequest{}) or { failed = true }
				}
				2 {
					DispatchRuntime.websocket_upstream(ctx, transport.WorkerWebSocketUpstreamDispatchRequest{}) or { failed = true }
				}
				else {
					DispatchRuntime.websocket_event(ctx, transport.WorkerWebSocketFrame{}) or { failed = true }
				}
			}
			assert failed
			assert probe.finishes == 1
			if _ := conn.write_payload('closed') {
				assert false
			} else {
				assert err.msg() == 'worker_connection_closed'
			}
			conn.close()
			if !write_failure { peer.close() or {} }
		}
	}
}

fn test_read_timeout_is_shared_by_connection_copies() {
	pair := connection_pair('timeout')
	mut peer := pair.peer
	defer { peer.close() or {} }
	mut conn := WorkerBackendConnection.from_selected('test', *pair.client)
	defer { conn.close() }
	mut copy := conn
	conn.apply_read_timeout(20)
	start := time.now()
	if _ := copy.read_stream_response() {
		assert false
	} else {
		assert err.msg() != 'worker_connection_closed'
	}
	assert time.now() - start < 2 * time.second
	copy.close()
	assert conn.owner.conn == none
}

fn test_close_interrupts_and_joins_inflight_frame_before_descriptor_release() {
	pair := connection_pair('blocked-read')
	mut peer := pair.peer
	defer { peer.close() or {} }
	mut conn := WorkerBackendConnection.from_selected('test', *pair.client)
	conn.apply_read_timeout(30000)
	mut copy := conn
	read_done := chan bool{cap: 1}
	spawn fn [mut copy, read_done] () {
		if _ := copy.read_stream_response() {
			assert false
		}
		read_done <- true
	}()
	mut owner := conn.owner
	deadline := time.now().add(3 * time.second)
	for owner.io_mu.try_lock() {
		owner.io_mu.unlock()
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	close_done := chan bool{cap: 1}
	spawn fn [mut conn, close_done] () {
		conn.close()
		close_done <- true
	}()
	select {
		_ := <-read_done {
		}
		3 * time.second {
			panic('close did not interrupt read')
		}
	}
	select {
		_ := <-close_done {
		}
		3 * time.second {
			panic('close did not join frame')
		}
	}
	assert C.fcntl(pair.client.sock.handle, C.F_GETFD, 0) < 0
	assert owner.conn == none
}
