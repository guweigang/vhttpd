module main

import executor
import worker
import upstream.transport
import net.unix
import os
import time

fn snapshot_worker_pool(path string, id int, inflight i64) &worker.WorkerState {
	return &worker.WorkerState{
		worker_backend: worker.WorkerBackendRuntime{
			autostart:       true
			sockets:         [path]
			read_timeout_ms: 1000
			managed_workers: [transport.ManagedWorker{
				id:                id
				socket_path:       path
				next_retry_ts:     time.now().unix_milli() + 60000
				inflight_requests: inflight
			}]
		}
	}
}

fn snapshot_exchange_primary(mut app App, state &worker.WorkerState) {
	app.mu.@lock()
	app.engines = EngineRuntime{ primary: state }
	app.mu.unlock()
}

fn test_rpc_context_finishes_the_original_generation_with_reused_socket_name() {
	path := os.join_path(os.temp_dir(), 'vhttpd-snapshot-finish-${os.getpid()}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	mut old := snapshot_worker_pool(path, 1, 0)
	mut next := snapshot_worker_pool(path, 2, 1)
	mut app := &App{ engines: EngineRuntime{ primary: old } }
	ctx := app.build_worker_backend_dispatch_context()
	mut conn := ctx.open() or { panic(err) }
	mut peer := listener.accept() or { panic(err) }
	defer { peer.close() or {} }
	snapshot_exchange_primary(mut app, next)
	conn.close()
	ctx.finished(path)
	assert old.worker_backend.managed_workers[0].inflight_requests == 0
	assert old.worker_backend.managed_workers[0].served_requests == 1
	assert next.worker_backend.managed_workers[0].inflight_requests == 1
	assert next.worker_backend.managed_workers[0].served_requests == 0
}

fn test_connector_context_selects_and_releases_one_generation() {
	mut old := snapshot_worker_pool('old.sock', 1, 0)
	mut next := snapshot_worker_pool('new.sock', 2, 0)
	mut app := &App{ engines: EngineRuntime{ primary: old } }
	ctx := app.build_worker_backend_connector_context()
	snapshot_exchange_primary(mut app, next)
	socket := ctx.select_socket() or { panic(err) }
	ctx.release(socket)
	assert socket == 'old.sock'
	assert old.worker_backend.managed_workers[0].inflight_requests == 0
	assert old.worker_backend.managed_workers[0].served_requests == 0
	assert next.worker_backend.managed_workers[0].inflight_requests == 0
}

fn test_connector_release_cannot_decrement_replacement_pool() {
	mut old := snapshot_worker_pool('shared.sock', 1, 0)
	mut next := snapshot_worker_pool('shared.sock', 2, 1)
	mut app := &App{ engines: EngineRuntime{ primary: old } }
	ctx := app.build_worker_backend_connector_context()
	socket := ctx.select_socket() or { panic(err) }
	snapshot_exchange_primary(mut app, next)
	ctx.release(socket)
	assert old.worker_backend.managed_workers[0].inflight_requests == 0
	assert next.worker_backend.managed_workers[0].inflight_requests == 1
	assert next.worker_backend.managed_workers[0].served_requests == 0
}

fn snapshot_rpc_peer(mut listener unix.StreamListener, entered chan bool, release chan bool, done chan bool) {
	mut peer := listener.accept() or { panic(err) }
	defer {
		peer.close() or {}
		done <- true
	}
	request := worker.WorkerBackendFrameCodec.read(mut peer) or { panic(err) }
	assert request.contains('snapshot-rpc')
	entered <- true
	_ := <-release
	worker.WorkerBackendFrameCodec.write(mut peer, '{"id":"snapshot-rpc","body":"old-response","handled":true}') or { panic(err) }
}

fn snapshot_rpc_call(mut app App, done chan string) {
	response := app.worker_backend_dispatch_mcp(transport.WorkerMcpDispatchRequest{ id: 'snapshot-rpc' }) or {
		done <- err.msg()
		return
	}
	done <- response.body
}

fn snapshot_wait(done chan bool) {
	select {
		_ := <-done {
		}
		3 * time.second {
			assert false, 'snapshot fixture timed out'
		}
	}
}

fn test_inflight_rpc_completes_on_its_original_pool_after_publication() {
	path := os.join_path(os.temp_dir(), 'vhttpd-snapshot-${os.getpid()}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	mut old := snapshot_worker_pool(path, 1, 0)
	mut next := snapshot_worker_pool(path, 2, 1)
	mut app := &App{ engines: EngineRuntime{ primary: old } }
	entered := chan bool{cap: 1}
	release := chan bool{cap: 1}
	peer_done := chan bool{cap: 1}
	client_done := chan string{cap: 1}
	spawn snapshot_rpc_peer(mut listener, entered, release, peer_done)
	spawn snapshot_rpc_call(mut app, client_done)
	snapshot_wait(entered)
	snapshot_exchange_primary(mut app, next)
	release <- true
	mut body := ''
	select {
		result := <-client_done {
			body = result
		}
		3 * time.second {
			assert false, 'snapshot RPC did not finish'
		}
	}
	snapshot_wait(peer_done)
	assert body == 'old-response'
	assert old.worker_backend.managed_workers[0].inflight_requests == 0
	assert old.worker_backend.managed_workers[0].served_requests == 1
	assert next.worker_backend.managed_workers[0].inflight_requests == 1
	assert next.worker_backend.managed_workers[0].served_requests == 0
}

fn test_rpc_open_uses_the_generation_that_supplied_its_timeout() {
	path := os.join_path(os.temp_dir(), 'vhttpd-snapshot-open-${os.getpid()}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	mut old := snapshot_worker_pool(path, 1, 0)
	mut next := snapshot_worker_pool('/tmp/' + 'x'.repeat(200), 2, 0)
	next.worker_backend.read_timeout_ms = 9000
	mut app := &App{ engines: EngineRuntime{ primary: old } }
	ctx := app.build_worker_backend_dispatch_context()
	snapshot_exchange_primary(mut app, next)
	mut conn := ctx.open() or { panic(err) }
	defer { conn.close() }
	mut peer := listener.accept() or { panic(err) }
	defer { peer.close() or {} }
	assert ctx.timeout_ms == 1000
	assert conn.socket_path == path
	conn.close()
	ctx.finished(conn.socket_path)
	assert old.worker_backend.managed_workers[0].served_requests == 1
	assert next.worker_backend.managed_workers[0].served_requests == 0
}

fn test_rpc_snapshot_rejects_a_retired_generation_without_falling_forward() {
	mut old := snapshot_worker_pool('/tmp/' + 'x'.repeat(200), 1, 0)
	mut next := snapshot_worker_pool('/tmp/' + 'y'.repeat(200), 2, 0)
	mut app := &App{ engines: EngineRuntime{ primary: old } }
	ctx := app.build_worker_backend_dispatch_context()
	old.stop_backend(executor.disabled_executor_lifecycle(), worker.LifecyclePort{})
	snapshot_exchange_primary(mut app, next)
	if _ := ctx.open() {
		assert false
	} else {
		assert err.msg() == 'worker_backend_stopping'
	}
	assert next.worker_backend.managed_workers[0].inflight_requests == 0
	assert next.worker_backend.managed_workers[0].served_requests == 0
}

fn test_dial_failure_returns_leases_to_the_captured_pool() {
	path := '/tmp/' + 'x'.repeat(200)
	mut old := snapshot_worker_pool(path, 1, 0)
	mut next := snapshot_worker_pool(path, 2, 1)
	mut app := &App{ engines: EngineRuntime{ primary: old } }
	ctx := app.build_worker_backend_connector_context()
	snapshot_exchange_primary(mut app, next)
	if _, _ := worker.ConnectorRuntime.connect_selected(ctx) {
		assert false
	}
	assert old.worker_backend.managed_workers[0].inflight_requests == 0
	assert old.worker_backend.managed_workers[0].served_requests == 0
	assert next.worker_backend.managed_workers[0].inflight_requests == 1
	assert next.worker_backend.managed_workers[0].served_requests == 0
}

fn test_independent_rpc_snapshots_keep_distinct_same_socket_accounting() {
	path := os.join_path(os.temp_dir(), 'vhttpd-snapshot-two-${os.getpid()}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	mut old := snapshot_worker_pool(path, 1, 0)
	mut next := snapshot_worker_pool(path, 2, 0)
	mut app := &App{ engines: EngineRuntime{ primary: old } }
	first := app.build_worker_backend_dispatch_context()
	mut first_conn := first.open() or { panic(err) }
	mut first_peer := listener.accept() or { panic(err) }
	defer { first_peer.close() or {} }
	snapshot_exchange_primary(mut app, next)
	second := app.build_worker_backend_dispatch_context()
	mut second_conn := second.open() or { panic(err) }
	mut second_peer := listener.accept() or { panic(err) }
	defer { second_peer.close() or {} }
	first_conn.close()
	first.finished(path)
	assert old.worker_backend.managed_workers[0].inflight_requests == 0
	assert old.worker_backend.managed_workers[0].served_requests == 1
	assert next.worker_backend.managed_workers[0].inflight_requests == 1
	second_conn.close()
	second.finished(path)
	assert next.worker_backend.managed_workers[0].inflight_requests == 0
	assert next.worker_backend.managed_workers[0].served_requests == 1
}

fn snapshot_validate_ready(state &worker.WorkerState, entered chan bool, done chan string) {
	entered <- true
	validate_replacement_worker_state_ready('main', state) or {
		done <- err.msg()
		return
	}
	done <- 'ready'
}

fn test_readiness_snapshot_waits_on_the_original_worker_mutex() {
	mut state := snapshot_worker_pool('busy.sock', 1, 1)
	entered := chan bool{cap: 1}
	done := chan string{cap: 1}
	state.mu.@lock()
	spawn snapshot_validate_ready(state, entered, done)
	snapshot_wait(entered)
	mut returned_early := false
	select {
		_ := <-done {
			returned_early = true
		}
		40 * time.millisecond {
		}
	}
	state.mu.unlock()
	assert !returned_early
	mut result := ''
	select {
		value := <-done {
			result = value
		}
		3 * time.second {
			assert false, 'readiness copied a locked mutex instead of borrowing state'
		}
	}
	assert result == 'runtime_plan_replacement_engine_not_ready:main'
}
