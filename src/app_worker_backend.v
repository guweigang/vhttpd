module main

import admin
import upstream.transport
import worker

// Application boundary: supply callbacks and route requests to the worker subsystem.

fn (mut app App) on_worker_request_started(socket_path string) {
	app.engines.request_started(socket_path)
}

fn (mut app App) on_worker_request_finished(socket_path string) {
	port := app.build_engine_lifecycle_port()
	app.engines.request_finished(port, socket_path)
}

fn (mut app App) on_worker_request_released(socket_path string) {
	app.engines.request_released(socket_path)
}

fn (mut app App) worker_backend_select_socket_queued() !string {
	port := app.build_engine_lifecycle_port()
	return app.engines.select_socket_for_kind(port, '')
}

fn (mut app App) drain_engine(kind string) !worker.DrainStatus {
	status := app.engines.drain_engine(kind)!
	app.emit('admin.worker.drain', {
		'engine':            status.engine
		'worker_count':      '${status.worker_count}'
		'draining_count':    '${status.draining_count}'
		'inflight_requests': '${status.inflight_requests}'
		'ready_count':       '${status.ready_count}'
		'changed':           '${status.changed}'
	})
	return status
}

fn (mut app App) engine_drain_status(kind string) !worker.DrainStatus {
	return app.engines.engine_drain_status(kind)
}

fn (mut app App) resume_engine(kind string) !worker.DrainStatus {
	status := app.engines.resume_engine(kind)!
	app.emit('admin.worker.resume', {
		'engine':            status.engine
		'worker_count':      '${status.worker_count}'
		'draining_count':    '${status.draining_count}'
		'inflight_requests': '${status.inflight_requests}'
		'ready_count':       '${status.ready_count}'
		'changed':           '${status.changed}'
	})
	return status
}

// One RPC snapshot retains the selected generation through selection, dialing
// and completion. Socket names may be reused by a later published runtime.
struct WorkerBackendRequestSnapshot {
	state        &worker.WorkerState @[required]
	port         worker.LifecyclePort
	kind         string
	timeout_ms   int
	env          map[string]string
	socket_count int
}

fn (mut app App) build_worker_backend_request_snapshot() WorkerBackendRequestSnapshot {
	app.mu.@lock()
	state := app.engines.primary
	app.mu.unlock()
	return new_worker_backend_request_snapshot(state, app.build_engine_lifecycle_port())
}

fn new_worker_backend_request_snapshot(state &worker.WorkerState, port worker.LifecyclePort) WorkerBackendRequestSnapshot {
	state.mu.@lock()
	timeout_ms := state.worker_backend.read_timeout_ms
	env := state.worker_backend.env.clone()
	socket_count := state.worker_backend.sockets.len
	state.mu.unlock()
	return WorkerBackendRequestSnapshot{
		state:        state
		port:         port
		kind:         state.logic_executor.kind()
		timeout_ms:   timeout_ms
		env:          env
		socket_count: socket_count
	}
}

fn (snapshot WorkerBackendRequestSnapshot) connector_context() worker.ConnectorContext {
	mut host := &WorkerRequestLeaseHost{ snapshot: snapshot }
	return host.connector_context()
}

fn (snapshot WorkerBackendRequestSnapshot) dispatch_context() worker.DispatchContext {
	mut host := &WorkerRequestLeaseHost{ snapshot: snapshot }
	return worker.DispatchContext{
		open_fn:    fn [mut host] () !worker.WorkerBackendConnection { return host.open() }
		finish_fn:  fn [mut host] (path string) { host.finish(path) }
		timeout_ms: snapshot.timeout_ms
	}
}

fn (mut app App) build_worker_backend_connector_context() worker.ConnectorContext {
	return app.build_worker_backend_request_snapshot().connector_context()
}

fn (mut app App) build_worker_backend_dispatch_context() worker.DispatchContext {
	return app.build_worker_backend_request_snapshot().dispatch_context()
}

fn (mut app App) worker_backend_dispatch_stream(req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	ctx := app.build_worker_backend_dispatch_context()
	return worker.DispatchRuntime.stream(ctx, req)
}

fn (mut app App) worker_backend_dispatch_mcp(req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	ctx := app.build_worker_backend_dispatch_context()
	return worker.DispatchRuntime.mcp(ctx, req)
}

fn (mut app App) worker_backend_dispatch_websocket_upstream(req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	ctx := app.build_worker_backend_dispatch_context()
	return worker.DispatchRuntime.websocket_upstream(ctx, req)
}

fn (mut app App) worker_backend_dispatch_websocket_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	ctx := app.build_worker_backend_dispatch_context()
	return worker.DispatchRuntime.websocket_event(ctx, frame)
}

fn (mut app App) restart_worker_by_id(worker_id int) !admin.WorkerAdminStatus {
	port := app.build_engine_lifecycle_port()
	return app.engines.restart_worker_by_id(port, worker_id)
}

fn (mut app App) restart_all_workers() int {
	port := app.build_engine_lifecycle_port()
	return app.engines.restart_all_workers(port)
}

fn (mut app App) worker_admin_snapshot() admin.WorkerPoolAdminStatus {
	return app.engines.admin_snapshot()
}

fn (mut app App) build_engine_lifecycle_port() worker.LifecyclePort {
	return worker.LifecyclePort{
		emit_fn: fn [mut app] (kind string, fields map[string]string) {
			app.emit(kind, fields)
		}
	}
}
