module main

import executor
import worker
import log
import upstream.transport

struct EngineLifecyclePort {
	emit_fn fn (string, map[string]string) = unsafe { nil }
}

fn (mut app App) build_engine_lifecycle_port() EngineLifecyclePort {
	return EngineLifecyclePort{
		emit_fn: fn [mut app] (kind string, fields map[string]string) {
			app.emit(kind, fields)
		}
	}
}

fn engine_lifecycle_context(state &worker.WorkerState, port EngineLifecyclePort) executor.LifecycleRuntimeContext {
	return executor.LifecycleRuntimeContext{
		worker_backend_autostart:       state.worker_backend.autostart
		worker_backend_cmd:             state.worker_backend.cmd
		worker_backend_env:             state.worker_backend.env.clone()
		worker_backend_sockets:         state.worker_backend.sockets.clone()
		worker_backend_workdir:         state.worker_backend.workdir
		worker_backend_managed_workers: state.worker_backend.managed_workers.clone()
		emit:                           port.emit_fn
	}
}

fn (mut runtime EngineRuntime) start(primary_lifecycle executor.LogicExecutorLifecycle, port EngineLifecyclePort, mut facade executor.AppFacade) {
	mut primary_ctx := engine_lifecycle_context(runtime.primary, port)
	primary_lifecycle.start(mut primary_ctx)
	runtime.primary.worker_backend.managed_workers = primary_ctx.worker_backend_managed_workers
	runtime.primary.logic_executor.warmup(mut facade) or {
		err_msg := executor.InProcVjsxError.normalize_message(err.msg(),
			'logic_executor_warmup_failed')
		log.error('[vhttpd] logic executor warmup failed: ${err_msg}')
	}
	for name, mut state in runtime.additional {
		spec := executor.builtin_executor_spec_find(name) or { continue }
		mut ctx := engine_lifecycle_context(state, port)
		spec.lifecycle.start(mut ctx)
		state.worker_backend.managed_workers = ctx.worker_backend_managed_workers
		state.logic_executor.warmup(mut facade) or {
			log.error('[vhttpd] additional logic executor warmup failed kind=${name}: ${err.msg()}')
		}
	}
}

fn (mut runtime EngineRuntime) stop(primary_lifecycle executor.LogicExecutorLifecycle, port EngineLifecyclePort) {
	mut primary_ctx := engine_lifecycle_context(runtime.primary, port)
	primary_lifecycle.stop(mut primary_ctx)
	runtime.primary.worker_backend.managed_workers = primary_ctx.worker_backend_managed_workers
	runtime.primary.logic_executor.close()
	for name, mut state in runtime.additional {
		spec := executor.builtin_executor_spec_find(name) or { continue }
		mut ctx := engine_lifecycle_context(state, port)
		spec.lifecycle.stop(mut ctx)
		state.worker_backend.managed_workers = ctx.worker_backend_managed_workers
		state.logic_executor.close()
	}
}

fn (mut runtime EngineRuntime) apply_scheme(scheme string) {
	normalized := if scheme.trim_space() == 'https' { 'https' } else { 'http' }
	runtime.primary.worker_backend.env['VHTTPD_SCHEME'] = normalized
	runtime.primary.worker_backend.env['VHTTPD_REQUEST_SCHEME'] = normalized
	for _, mut state in runtime.additional {
		state.worker_backend.env['VHTTPD_SCHEME'] = normalized
		state.worker_backend.env['VHTTPD_REQUEST_SCHEME'] = normalized
	}
}

struct EngineDispatchSelection {
mut:
	logic_executor executor.LogicExecutor = executor.SocketWorkerExecutor{}
pub:
	pool            string
	stream_dispatch bool
}

fn (selection EngineDispatchSelection) should_try_primary_stream_dispatch() bool {
	return selection.stream_dispatch && selection.pool == 'main'
}

struct EngineRuntimeMetrics {
pub:
	queue_waits_total    i64
	queue_rejected_total i64
	queue_timeouts_total i64
	queue_depth          int
	pool_size            i64
	backend_mode         string
	queue_capacity       int
	queue_timeout_ms     int
	stream_dispatch      bool
	lifecycle            string
}

fn (runtime &EngineRuntime) primary_kind() string {
	return runtime.primary.logic_executor.kind()
}

fn (runtime &EngineRuntime) read_timeout_ms(kind string) int {
	if kind == '' || kind == runtime.primary_kind() {
		return runtime.primary.worker_backend.read_timeout_ms
	}
	if state := runtime.additional[kind] {
		return state.worker_backend.read_timeout_ms
	}
	return 0
}

fn (runtime &EngineRuntime) worker_env(kind string) map[string]string {
	if kind == '' || kind == runtime.primary_kind() {
		return runtime.primary.worker_backend.env.clone()
	}
	if state := runtime.additional[kind] {
		return state.worker_backend.env.clone()
	}
	return map[string]string{}
}

fn (runtime &EngineRuntime) primary_socket_count() int {
	return runtime.primary.worker_backend.sockets.len
}

fn (runtime &EngineRuntime) dispatch_selection(name string) EngineDispatchSelection {
	if name != '' {
		if state := runtime.additional[name] {
			return EngineDispatchSelection{
				logic_executor:  state.logic_executor
				pool:            name
				stream_dispatch: state.stream_dispatch
			}
		}
	}
	return EngineDispatchSelection{
		logic_executor:  runtime.primary.logic_executor
		pool:            'main'
		stream_dispatch: runtime.primary.stream_dispatch
	}
}

fn (runtime &EngineRuntime) logic_executor_model() executor.LogicExecutorModel {
	return runtime.primary.logic_executor.model()
}

fn (runtime &EngineRuntime) logic_executor_provider() string {
	return runtime.primary.logic_executor.provider()
}

fn (runtime &EngineRuntime) logic_executor_admin_details() executor.LogicExecutorAdminDetails {
	return runtime.primary.logic_executor.admin_details()
}

fn (runtime &EngineRuntime) has_http_logic_executor() bool {
	return runtime.primary_socket_count() > 0 || runtime.logic_executor_model() == .embedded
}

fn (runtime &EngineRuntime) has_socket_workers() bool {
	return runtime.primary_socket_count() > 0
}

fn (mut runtime EngineRuntime) dispatch_stream(mut facade executor.AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	return runtime.primary.logic_executor.dispatch_stream(mut facade, req)
}

fn (mut runtime EngineRuntime) dispatch_mcp(mut facade executor.AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	return runtime.primary.logic_executor.dispatch_mcp(mut facade, req)
}

fn (mut runtime EngineRuntime) dispatch_websocket_upstream(mut facade executor.AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	return runtime.primary.logic_executor.dispatch_websocket_upstream(mut facade, req)
}

fn (mut runtime EngineRuntime) dispatch_websocket_event(mut facade executor.AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	return runtime.primary.logic_executor.dispatch_websocket_event(mut facade, frame)
}

fn (mut runtime EngineRuntime) open_websocket_session(mut facade executor.AppFacade, req executor.WebSocketSessionOpenRequest) !executor.WebSocketSessionOpenOutcome {
	return runtime.primary.logic_executor.open_websocket_session(mut facade, req)
}

fn (mut runtime EngineRuntime) dispatch_http_for_kind(kind string, mut facade executor.AppFacade, req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
	if runtime.primary_kind() == kind {
		return runtime.primary.logic_executor.dispatch_http(mut facade, req)
	}
	mut state := runtime.additional[kind] or { return error('${kind}_executor_unavailable') }
	return state.logic_executor.dispatch_http(mut facade, req)
}

fn (mut runtime EngineRuntime) set_primary_env(key string, value string) {
	if key != '' {
		runtime.primary.worker_backend.env[key] = value
	}
}

fn (mut runtime EngineRuntime) startup_fields() map[string]string {
	metrics := runtime.metrics()
	return {
		'worker_backend':           runtime.primary.worker_backend.kind()
		'worker_backend_mode':      metrics.backend_mode
		'logic_executor':           runtime.primary_kind()
		'logic_executor_lifecycle': metrics.lifecycle
		'logic_executor_model':     '${runtime.logic_executor_model()}'
		'logic_provider':           runtime.logic_executor_provider()
		'worker_autostart':         if runtime.primary.worker_backend.autostart {
			'true'
		} else {
			'false'
		}
		'worker_pool_size':         '${metrics.pool_size}'
	}
}

fn (mut runtime EngineRuntime) metrics() EngineRuntimeMetrics {
	runtime.primary.mu.@lock()
	defer { runtime.primary.mu.unlock() }
	return EngineRuntimeMetrics{
		queue_waits_total:    runtime.primary.stat_queue_waits_total
		queue_rejected_total: runtime.primary.stat_queue_rejected_total
		queue_timeouts_total: runtime.primary.stat_queue_timeouts_total
		queue_depth:          runtime.primary.worker_backend.queue_waiting_requests
		pool_size:            i64(runtime.primary.worker_backend.sockets.len)
		backend_mode:         '${runtime.primary.worker_backend_mode}'
		queue_capacity:       runtime.primary.worker_backend.queue_capacity
		queue_timeout_ms:     runtime.primary.worker_backend.queue_timeout_ms
		stream_dispatch:      runtime.primary.stream_dispatch
		lifecycle:            runtime.primary.lifecycle
	}
}

fn (mut runtime EngineRuntime) request_started(socket_path string) {
	if engine_worker_request_started(mut runtime.primary, socket_path) {
		return
	}
	for _, mut state in runtime.additional {
		if engine_worker_request_started(mut *state, socket_path) {
			return
		}
	}
}

fn (mut runtime EngineRuntime) request_finished(port EngineLifecyclePort, socket_path string) {
	if runtime.worker_request_finished(port, mut runtime.primary, socket_path) {
		return
	}
	for _, mut state in runtime.additional {
		if runtime.worker_request_finished(port, mut *state, socket_path) {
			return
		}
	}
}

fn (mut runtime EngineRuntime) select_socket_for_kind(port EngineLifecyclePort, kind string) !string {
	if kind == '' || kind == runtime.primary_kind() {
		primary_kind := runtime.primary_kind()
		return runtime.select_socket_queued_for_state(port, primary_kind, mut runtime.primary)
	}
	mut state := runtime.additional[kind] or { return error('unknown_executor_kind:${kind}') }
	return runtime.select_socket_queued_for_state(port, kind, mut *state)
}

fn engine_worker_request_started(mut state worker.WorkerState, socket_path string) bool {
	state.mu.@lock()
	defer { state.mu.unlock() }
	idx := worker_index_by_socket_in_state_unlocked(state, socket_path)
	if idx < 0 || idx >= state.worker_backend.managed_workers.len {
		return false
	}
	mut managed := state.worker_backend.managed_workers[idx]
	managed.inflight_requests++
	state.worker_backend.managed_workers[idx] = managed
	return true
}

fn (mut runtime EngineRuntime) worker_request_finished(port EngineLifecyclePort, mut state worker.WorkerState, socket_path string) bool {
	mut should_restart := false
	mut restart_idx := -1
	mut max_request_fields := map[string]string{}
	state.mu.@lock()
	idx := worker_index_by_socket_in_state_unlocked(state, socket_path)
	if idx < 0 || idx >= state.worker_backend.managed_workers.len {
		state.mu.unlock()
		return false
	}
	mut managed := state.worker_backend.managed_workers[idx]
	if managed.inflight_requests > 0 {
		managed.inflight_requests--
	}
	managed.served_requests++
	if state.worker_backend.max_requests > 0 && !managed.draining
		&& managed.served_requests >= state.worker_backend.max_requests {
		managed.draining = true
		max_request_fields = {
			'worker_id':       '${managed.id}'
			'socket':          managed.socket_path
			'served_requests': '${managed.served_requests}'
			'max_requests':    '${state.worker_backend.max_requests}'
		}
	}
	state.worker_backend.managed_workers[idx] = managed
	should_restart = managed.draining && managed.inflight_requests == 0
	restart_idx = idx
	state.mu.unlock()
	if max_request_fields.len > 0 {
		port.emit_fn('worker.max_requests_reached', max_request_fields)
	}
	if should_restart {
		runtime.restart_worker_slot_now_for_state(port, mut state, restart_idx,
			'max_requests_reached')
	}
	return true
}
