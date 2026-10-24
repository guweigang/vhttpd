module main

import executor
import worker
import upstream.transport
import net.unix
import os
import time

fn dispatch_snapshot_pool(path string, id int, inflight i64) &worker.WorkerState {
	return &worker.WorkerState{
		worker_backend: worker.WorkerBackendRuntime{
			autostart:       true
			sockets:         [path]
			read_timeout_ms: 1000
			managed_workers: [transport.ManagedWorker{ id: id, socket_path: path, inflight_requests: inflight, next_retry_ts: time.now().unix_milli() + 60000 }]
		}
	}
}

fn dispatch_snapshot_call(mut engines EngineRuntime, mut facade executor.AppFacade, kind string) !bool {
	match kind {
		'stream' {
			return engines.dispatch_stream(mut facade, transport.StreamDispatchRequest{ request_id: 'snapshot' })!.handled
		}
		'mcp' {
			return engines.dispatch_mcp(mut facade, transport.WorkerMcpDispatchRequest{ id: 'snapshot' })!.handled
		}
		'upstream' {
			return engines.dispatch_websocket_upstream(mut facade, transport.WorkerWebSocketUpstreamDispatchRequest{ id: 'snapshot' })!.handled
		}
		else {
			return engines.dispatch_websocket_event(mut facade, transport.WorkerWebSocketFrame{ id: 'snapshot' })!.accepted
		}
	}
}

fn dispatch_snapshot_peer(mut listener unix.StreamListener, entered chan bool, release chan bool, done chan bool, fail bool) {
	mut conn := listener.accept() or { panic(err) }
	conn.set_read_timeout(time.second)
	raw := worker.WorkerBackendFrameCodec.read(mut conn) or { panic(err) }
	assert raw.contains('snapshot')
	entered <- true
	_ := <-release
	if !fail {
		worker.WorkerBackendFrameCodec.write(mut conn, '{"handled":true,"accepted":true}') or { panic(err) }
	}
	conn.close() or {}
	done <- true
}

fn dispatch_snapshot_wait(ch chan bool) {
	select {
		_ := <-ch {
		}
		3 * time.second {
			panic('dispatch snapshot fixture timeout')
		}
	}
}

fn dispatch_snapshot_case(kind string, inflight bool, fail bool) {
	path := os.join_path(os.temp_dir(), 'vhttpd-dispatch-snapshot-${os.getpid()}-${kind}-${inflight}-${fail}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	mut old := dispatch_snapshot_pool(path, 1, 0)
	mut next := dispatch_snapshot_pool(path, 2, 1)
	mut app := &App{ engines: EngineRuntime{ primary: old } }
	mut retained := app.engine_runtime_snapshot()
	if !inflight {
		app.mu.@lock()
		app.engines = EngineRuntime{ primary: next }
		app.mu.unlock()
	}
	mut facade := app.as_facade()
	entered := chan bool{cap: 1}
	release := chan bool{cap: 1}
	done := chan bool{cap: 1}
	result := chan string{cap: 1}
	spawn dispatch_snapshot_peer(mut listener, entered, release, done, fail)
	spawn fn [mut retained, mut facade, kind, result] () {
		handled := dispatch_snapshot_call(mut retained, mut facade, kind) or {
			result <- err.msg()
			return
		}
		result <- handled.str()
	}()
	dispatch_snapshot_wait(entered)
	assert old.worker_backend.managed_workers[0].inflight_requests == 1
	if inflight {
		app.mu.@lock()
		app.engines = EngineRuntime{ primary: next }
		app.mu.unlock()
	}
	release <- true
	select {
		value := <-result {
			if fail {
				assert value != 'true'
			} else {
				assert value == 'true'
			}
		}
		3 * time.second {
			panic('dispatch did not finish')
		}
	}
	dispatch_snapshot_wait(done)
	assert old.worker_backend.managed_workers[0].inflight_requests == 0
	assert old.worker_backend.managed_workers[0].served_requests == 1
	assert next.worker_backend.managed_workers[0].inflight_requests == 1
	assert next.worker_backend.managed_workers[0].served_requests == 0
}

fn test_retained_stream_dispatch_uses_original_backend() {
	dispatch_snapshot_case('stream', false, false)
}

fn test_retained_mcp_dispatch_uses_original_backend() {
	dispatch_snapshot_case('mcp', false, false)
}

fn test_retained_upstream_dispatch_uses_original_backend() {
	dispatch_snapshot_case('upstream', false, false)
}

fn test_retained_websocket_event_dispatch_uses_original_backend() {
	dispatch_snapshot_case('event', false, false)
}

fn test_inflight_dispatch_completion_stays_with_original_backend() {
	for kind in ['stream', 'mcp', 'upstream', 'event'] { dispatch_snapshot_case(kind, true, false) }
}

fn test_inflight_dispatch_failure_releases_original_backend() {
	for kind in ['stream', 'mcp', 'upstream', 'event'] { dispatch_snapshot_case(kind, true, true) }
}

fn test_runtime_registry_snapshot_owns_named_lookup_map() {
	old := dispatch_snapshot_pool('old', 1, 0)
	next := dispatch_snapshot_pool('next', 2, 0)
	mut app := &App{
		engines: EngineRuntime{
			primary:    old
			additional: {
				'vjsx': old
			}
		}
	}
	retained := app.engine_runtime_snapshot()
	app.mu.@lock()
	app.engines.additional['vjsx'] = next
	app.engines.additional['extra'] = next
	app.mu.unlock()
	assert retained.additional.len == 1
	assert voidptr(retained.additional['vjsx'] or { panic('missing pool') }) == voidptr(old)
	assert voidptr(retained.primary) == voidptr(old)
	assert retained.vjsx_event_dispatch_executor('extra') == 'vjsx'
	assert app.vjsx_event_dispatch_executor('extra') == 'extra'
}

struct SnapshotReentrantExecutor {
	executor.DisabledLogicExecutor
	owner       &App                @[required]
	replacement &worker.WorkerState @[required]
}

fn (e SnapshotReentrantExecutor) dispatch_websocket_upstream(mut facade executor.AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	mut app := e.owner
	_ := app.engine_runtime_snapshot()
	app.mu.@lock()
	app.engines = EngineRuntime{ primary: e.replacement }
	app.mu.unlock()
	return transport.WorkerWebSocketUpstreamDispatchResponse{ handled: true }
}

fn test_kernel_dispatch_releases_publication_lock_before_executor_callback() {
	mut app := &App{}
	next := &worker.WorkerState{ logic_executor: executor.DisabledLogicExecutor{} }
	app.engines = EngineRuntime{ primary: &worker.WorkerState{ logic_executor: SnapshotReentrantExecutor{ owner: app, replacement: next } } }
	done := chan bool{cap: 1}
	spawn fn [mut app, done] () {
		resp := app.kernel_dispatch_websocket_upstream(transport.WorkerWebSocketUpstreamDispatchRequest{}) or { panic(err) }
		done <- resp.handled
	}()
	dispatch_snapshot_wait(done)
	assert app.engine_runtime_snapshot().primary_kind() == 'none'
}

fn test_retired_dispatch_snapshot_does_not_fall_forward_to_live_pool() {
	mut old := dispatch_snapshot_pool('retired', 1, 0)
	next := dispatch_snapshot_pool('live', 2, 1)
	mut app := &App{ engines: EngineRuntime{ primary: old } }
	mut retained := app.engine_runtime_snapshot()
	old.stop_backend(executor.disabled_executor_lifecycle(), worker.LifecyclePort{})
	app.mu.@lock()
	app.engines = EngineRuntime{ primary: next }
	app.mu.unlock()
	mut facade := app.as_facade()
	for kind in ['stream', 'mcp', 'upstream', 'event'] {
		if _ := dispatch_snapshot_call(mut retained, mut facade, kind) {
			assert false, 'retired snapshot must reject admission'
		} else {
			assert err.msg().contains('worker_backend_stopping')
		}
	}
	assert next.worker_backend.managed_workers[0].inflight_requests == 1
	assert next.worker_backend.managed_workers[0].served_requests == 0
}
