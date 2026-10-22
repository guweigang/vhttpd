module main

import executor
import worker
import net
import net.http
import net.unix
import os
import time

#include <fcntl.h>

fn C.fcntl(int, int, ...voidptr) int
fn C.dup2(int, int) int
fn C.close(int) int

fn origin_tcp_pair() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	peer.set_read_timeout(time.second)
	return listener.accept() or { panic(err) }, peer
}

fn origin_stream(label string) (executor.HttpLogicDispatchOutcome, &worker.WorkerState) {
	path := os.join_path(os.temp_dir(), 'vhttpd-owner-${label}-${os.getpid()}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	state := origin_pool(path, false, 0)
	mut app := &App{ engines: EngineRuntime{ primary: state } }
	entered := chan bool{cap: 1}
	release := chan bool{cap: 1}
	done := chan bool{cap: 1}
	release <- true
	spawn origin_peer(mut listener, false, true, entered, release, done)
	mut facade := app.as_facade()
	outcome := app.engines.dispatch_selection('').dispatch_http(mut facade, executor.HttpLogicDispatchRequest{}) or { panic(err) }
	origin_wait(entered)
	origin_wait(done)
	return outcome, state
}

fn test_stream_outcome_copies_cannot_close_reused_descriptors() {
	mut outcome, state := origin_stream('copy')
	mut copy := outcome
	conn := outcome.conn or { panic('missing stream') }
	fd := conn.sock.handle
	mut server, mut peer := origin_tcp_pair()
	defer {
		server.close() or {}
		peer.close() or {}
	}
	outcome.close_live_conn()
	assert C.fcntl(fd, C.F_GETFD, 0) < 0
	assert C.dup2(peer.sock.handle, fd) == fd
	defer { C.close(fd) }
	copy.close_live_conn()
	copy.finish_worker()
	assert C.fcntl(fd, C.F_GETFD, 0) >= 0
	assert state.worker_backend.managed_workers[0].served_requests == 1
	assert state.worker_backend.managed_workers[0].inflight_requests == 0
}

fn test_stream_connection_transfers_once_without_early_accounting() {
	mut outcome, state := origin_stream('take')
	mut copy := outcome
	mut conn := outcome.take_live_conn() or { panic('missing stream') }
	assert copy.take_live_conn() == none
	copy.close_live_conn()
	assert C.fcntl(conn.sock.handle, C.F_GETFD, 0) >= 0
	assert state.worker_backend.managed_workers[0].inflight_requests == 1
	assert state.worker_backend.managed_workers[0].served_requests == 0
	conn.close() or {}
	outcome.finish_worker()
	copy.finish_worker()
	assert state.worker_backend.managed_workers[0].served_requests == 1
	assert state.worker_backend.managed_workers[0].inflight_requests == 0
}

fn origin_close_outcome(outcome executor.HttpLogicDispatchOutcome, done chan bool) {
	mut owned := outcome
	owned.close_live_conn()
	done <- true
}

fn test_concurrent_stream_outcome_copies_retire_one_connection_and_lease() {
	outcome, state := origin_stream('concurrent')
	done := chan bool{cap: 8}
	for _ in 0 .. 8 {
		copy := outcome
		spawn origin_close_outcome(copy, done)
	}
	for _ in 0 .. 8 { origin_wait(done) }
	assert state.worker_backend.managed_workers[0].served_requests == 1
	assert state.worker_backend.managed_workers[0].inflight_requests == 0
}

fn test_concurrent_lease_finish_waits_for_the_first_callback() {
	entered := chan bool{cap: 2}
	release := chan bool{cap: 1}
	done := chan bool{cap: 2}
	lease := &executor.WorkerRequestLease{
		finish_fn: fn [entered, release] (_socket string) {
			entered <- true
			_ := <-release
		}
	}
	for _ in 0 .. 2 {
		spawn fn [lease, done] () {
			mut owned := lease
			owned.finish()
			done <- true
		}()
	}
	origin_wait(entered)
	mut early := false
	select {
		_ := <-done {
			early = true
		}
		40 * time.millisecond {
		}
	}
	release <- true
	origin_wait(done)
	origin_wait(done)
	assert !early
	assert entered.len == 0
}

fn test_worker_host_retains_target_config_without_mutable_map_aliases() {
	mut old := origin_pool('old.sock', true, 0)
	old.worker_backend.read_timeout_ms = 123
	mut next := origin_pool('new.sock', true, 0)
	next.worker_backend.env['DOCUMENT_ROOT'] = 'new-root'
	mut app := &App{ engines: EngineRuntime{ primary: old } }
	mut facade := app.as_facade()
	mut host := worker_request_host(old, mut facade)
	app.engines = EngineRuntime{ primary: next }
	old.set_env('DOCUMENT_ROOT', 'later-root')
	assert host.worker_backend_read_timeout_ms_for_kind('php-cgi') == 123
	mut env := host.worker_env_for_kind('php-cgi')
	assert env['DOCUMENT_ROOT'] == 'original-root'
	env['DOCUMENT_ROOT'] = 'caller-change'
	assert host.worker_env()['DOCUMENT_ROOT'] == 'original-root'
	socket := host.worker_backend_select_socket_for_kind('php-cgi') or { panic(err) }
	assert socket == 'old.sock'
	host.on_worker_request_released(socket)
	assert next.worker_backend.managed_workers[0].inflight_requests == 0
}

fn origin_ws_peer(mut listener unix.StreamListener, active bool, blocked chan bool, release chan bool, done chan bool) {
	mut peer := listener.accept() or { panic(err) }
	defer {
		peer.close() or {}
		done <- true
	}
	_ := worker.WorkerBackendFrameCodec.read(mut peer) or { panic(err) }
	worker.WorkerBackendFrameCodec.write(mut peer, '{"mode":"websocket","event":"accept"}') or { panic(err) }
	worker.WorkerBackendFrameCodec.write(mut peer, '{"mode":"websocket","event":"done"}') or { panic(err) }
	if active {
		frame := worker.WorkerBackendFrameCodec.read(mut peer) or { panic(err) }
		assert frame.contains('message')
		blocked <- true
	}
	_ := <-release
}

fn test_long_worker_websocket_and_cancelled_activation_finish_the_original_pool() {
	for active in [false, true] {
		path := os.join_path(os.temp_dir(), 'vhttpd-ws-origin-${active}-${os.getpid()}.sock')
		mut listener := unix.listen_stream(path) or { panic(err) }
		defer {
			listener.close() or {}
			os.rm(path) or {}
		}
		mut old := origin_pool(path, false, 0)
		mut next := origin_pool(path, false, 1)
		mut app := &App{ engines: EngineRuntime{ primary: old } }
		mut server, mut peer := origin_tcp_pair()
		defer { peer.close() or {} }
		mut ctx := Context{}
		ctx.conn = server
		mut run := reserve_inbound_websocket(mut app, ctx) or { panic('no ingress run') }
		blocked := chan bool{cap: 1}
		release := chan bool{cap: 1}
		done := chan bool{cap: 1}
		spawn origin_ws_peer(mut listener, active, blocked, release, done)
		mut facade := app.as_facade()
		mut engines := app.engines
		mut opened := engines.open_websocket_session(mut facade, executor.WebSocketSessionOpenRequest{
			register_conn_fn: fn [mut run] (fd int) bool { return run.attach(fd) }
			req:              http.Request{}
			path:             '/ws'
			request_id:       'origin-session'
		}) or { panic(err) }
		assert opened.accepted
		mut worker_conn := opened.take_live_conn() or { panic('missing worker socket') }
		worker_fd := worker_conn.sock.handle
		app.engines = EngineRuntime{ primary: next }
		if !active { run.request_stop() }
		spawn run_worker_websocket_session(mut run, app.build_websocket_runtime_context_for_state(engines.primary), mut server, mut worker_conn, path, 'dGhlIHNhbXBsZSBub25jZQ==', 'GET', '/ws', 'origin-session', 'trace', 0, opened.lease)
		if active {
			mut bytes := []u8{len: 2048}
			n := peer.read(mut bytes) or { panic(err) }
			assert bytes[..n].bytestr().contains('101 Switching Protocols')
			peer.write([u8(0x81), 0x82, 1, 2, 3, 4, u8(104 ^ 1), u8(105 ^ 2)]) or { panic(err) }
			origin_wait(blocked)
			run.request_stop()
		}
		joined := chan bool{cap: 1}
		spawn fn [mut app, joined] () {
			app.websocket.state.ingress.wait()
			joined <- true
		}()
		origin_wait(joined)
		release <- true
		origin_wait(done)
		assert C.fcntl(worker_fd, C.F_GETFD, 0) < 0
		assert app.websocket.state.ingress.active() == 0
		assert old.worker_backend.managed_workers[0].inflight_requests == 0
		assert old.worker_backend.managed_workers[0].served_requests == 1
		assert next.worker_backend.managed_workers[0].inflight_requests == 1
		opened.finish_worker()
		assert old.worker_backend.managed_workers[0].served_requests == 1
	}
}

fn test_custom_worker_outcome_can_transfer_native_ownership_to_a_lease() {
	mut original, state := origin_stream('custom')
	conn := original.take_live_conn() or { panic('missing stream') }
	fd := conn.sock.handle
	mut lease := &executor.WorkerRequestLease{
		socket_path: original.socket_path
		finish_fn:   fn [original] (_socket string) { original.finish_worker() }
	}
	lease.retain_connection(conn)
	mut custom := executor.HttpLogicDispatchOutcome{ conn: conn, lease: lease }
	mut copy := custom
	custom.close_live_conn()
	copy.close_live_conn()
	assert C.fcntl(fd, C.F_GETFD, 0) < 0
	assert state.worker_backend.managed_workers[0].inflight_requests == 0
	assert state.worker_backend.managed_workers[0].served_requests == 1
}
