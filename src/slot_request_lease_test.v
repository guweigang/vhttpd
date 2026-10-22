module main

import worker
import executor
import upstream.transport
import net.unix
import os
import time

fn request_slot_fixture(label string) (string, &worker.WorkerState, string) {
	root := os.join_path(os.temp_dir(), 'rq-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir_all(root) or { panic(err) }
	path := root + '/worker.sock'
	script := root + '/peer.py'
	os.write_file(script, 'import os,socket,sys\np=sys.argv[1]\nif os.path.exists(p): os.unlink(p)\ns=socket.socket(socket.AF_UNIX); s.bind(p); s.listen()\nconnections=[]\nwhile True: connections.append(s.accept()[0])\n') or { panic(err) }
	slot := transport.ManagedWorker.build_slot(1, 'python3 "${script}" "{socket}"', {}, path, 1) or { panic(err) }
	mut state := &worker.WorkerState{ worker_backend: worker.WorkerBackendRuntime{ autostart: true, sockets: [path], read_timeout_ms: 1000, managed_workers: [slot] } }
	state.ensure_slot(worker.LifecyclePort{}, 0)
	assert state.worker_backend.managed_workers[0].proc != none, label
	return path, state, root
}

fn request_slot_cleanup(mut state worker.WorkerState, root string) {
	state.stop_backend(executor.disabled_executor_lifecycle(), worker.LifecyclePort{})
	os.rmdir_all(root) or {}
}

fn test_bound_http_request_host_returns_completion_to_old_slot_generation() {
	path, mut state, root := request_slot_fixture('http')
	defer { request_slot_cleanup(mut state, root) }
	mut app := &App{ engines: EngineRuntime{ primary: state } }
	mut facade := app.as_facade()
	mut host := worker_request_host(state, mut facade)
	assert (host.worker_backend_select_socket_queued() or { panic(err) }) == path
	state.restart_slot(worker.LifecyclePort{}, 0, 'test')
	mut next := state.select_request_queued(worker.LifecyclePort{}, 'php') or { panic(err) }
	host.on_worker_request_finished(path)
	host.on_worker_request_finished(path)
	host.on_worker_request_released(path)
	assert state.worker_backend.managed_workers[0].inflight_requests == 1
	assert state.worker_backend.managed_workers[0].served_requests == 0
	next.finish(worker.LifecyclePort{})
	assert state.worker_backend.managed_workers[0].served_requests == 1
}

fn test_rpc_context_retains_original_slot_completion_after_connected_restart() {
	path, mut state, root := request_slot_fixture('rpc')
	defer { request_slot_cleanup(mut state, root) }
	mut app := &App{ engines: EngineRuntime{ primary: state } }
	ctx := app.build_worker_backend_dispatch_context()
	mut conn := ctx.open() or { panic(err) }
	state.restart_slot(worker.LifecyclePort{}, 0, 'test')
	mut next := state.select_request_queued(worker.LifecyclePort{}, 'php') or { panic(err) }
	conn.close()
	ctx.finished(path)
	ctx.finished(path)
	assert state.worker_backend.managed_workers[0].inflight_requests == 1
	assert state.worker_backend.managed_workers[0].served_requests == 0
	next.release(worker.LifecyclePort{})
}

fn test_connector_fenced_dial_failure_retries_with_fresh_slot_lease() {
	path, mut state, root := request_slot_fixture('retry')
	defer { request_slot_cleanup(mut state, root) }
	mut app := &App{ engines: EngineRuntime{ primary: state } }
	mut host := &WorkerRequestLeaseHost{ snapshot: app.build_worker_backend_request_snapshot() }
	base := host.connector_context()
	mut probe := &SlotRetryProbe{}
	ctx := worker.ConnectorContext{
		...base
		connect_fn: fn [base, mut state, mut probe] (path string) !&unix.StreamConn {
			probe.calls++
			if probe.calls == 1 {
				state.restart_slot(worker.LifecyclePort{}, 0, 'between_select_and_dial')
			}
			return base.connect_fn(path)
		}
	}
	socket, mut conn := worker.ConnectorRuntime.connect_selected(ctx) or { panic(err) }
	defer {
		conn.close() or {}
	}
	assert socket == path
	assert probe.calls == 2
	assert state.worker_backend.managed_workers[0].inflight_requests == 1
	host.finish(path)
	assert state.worker_backend.managed_workers[0].inflight_requests == 0
	assert state.worker_backend.managed_workers[0].served_requests == 1
}

@[heap]
struct SlotRetryProbe {
mut:
	calls int
}

fn test_slot_restart_error_is_classified_as_temporarily_unavailable() {
	status, kind := transport.classify_worker_backend_error('worker_slot_restarted')
	assert status == 503
	assert kind == 'worker_slot_restarted'
}

fn test_request_host_does_not_accept_unowned_or_wrong_socket_completion() {
	path, mut state, root := request_slot_fixture('unowned')
	defer { request_slot_cleanup(mut state, root) }
	mut app := &App{ engines: EngineRuntime{ primary: state } }
	mut facade := app.as_facade()
	mut other := state.select_request_queued(worker.LifecyclePort{}, 'php') or { panic(err) }
	mut empty := worker_request_host(state, mut facade)
	empty.on_worker_request_finished(path)
	empty.on_worker_request_released(path)
	assert state.worker_backend.managed_workers[0].inflight_requests == 1
	assert state.worker_backend.managed_workers[0].served_requests == 0
	other.release(worker.LifecyclePort{})
	mut selected := worker_request_host(state, mut facade)
	selected.worker_backend_select_socket_queued() or { panic(err) }
	selected.on_worker_request_finished(path + '-wrong')
	selected.on_worker_request_released(path + '-wrong')
	assert state.worker_backend.managed_workers[0].inflight_requests == 1
	selected.on_worker_request_finished(path)
	assert state.worker_backend.managed_workers[0].served_requests == 1
}
