module main

import executor
import worker
import log
import upstream.transport

fn (mut runtime EngineRuntime) start(primary_lifecycle executor.LogicExecutorLifecycle, port worker.LifecyclePort, mut facade executor.AppFacade) {
	runtime.primary.start_backend(primary_lifecycle, port)
	runtime.primary.logic_executor.warmup(mut facade) or {
		runtime.startup_failed = true
		err_msg := executor.InProcVjsxError.normalize_message(err.msg(),
			'logic_executor_warmup_failed')
		log.error('[vhttpd] logic executor warmup failed: ${err_msg}')
	}
	for name, mut state in runtime.additional {
		kind := state.logic_executor.kind()
		spec := executor.builtin_executor_spec_find(kind) or { continue }
		state.start_backend(spec.lifecycle, port)
		state.logic_executor.warmup(mut facade) or {
			runtime.startup_failed = true
			log.error('[vhttpd] additional logic executor warmup failed pool=${name} kind=${kind}: ${err.msg()}')
		}
	}
}

fn (mut runtime EngineRuntime) stop(primary_lifecycle executor.LogicExecutorLifecycle, port worker.LifecyclePort) {
	runtime.primary.stop_backend(primary_lifecycle, port)
	runtime.primary.logic_executor.close()
	for _, mut state in runtime.additional {
		kind := state.logic_executor.kind()
		if spec := executor.builtin_executor_spec_find(kind) {
			state.stop_backend(spec.lifecycle, port)
		}
		state.logic_executor.close()
	}
}

fn (mut runtime EngineRuntime) apply_scheme(scheme string) {
	normalized := if scheme.trim_space() == 'https' { 'https' } else { 'http' }
	runtime.primary.apply_scheme(normalized)
	for _, mut state in runtime.additional {
		state.apply_scheme(normalized)
	}
}

struct EngineDispatchSelection {
	state &worker.WorkerState @[required]
mut:
	http_port executor.LogicExecutorHttpPort = executor.logic_executor_http_port(executor.SocketWorkerExecutor{})
pub:
	pool            string
	stream_dispatch bool
}

fn (selection EngineDispatchSelection) should_try_primary_stream_dispatch() bool {
	return selection.stream_dispatch && selection.pool == 'main'
}

fn (selection EngineDispatchSelection) executor_kind() string {
	return selection.http_port.kind()
}

fn (selection EngineDispatchSelection) dispatch_http(mut facade executor.AppFacade, req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
	mut host := worker_request_host(selection.state, mut facade)
	return selection.http_port.dispatch_http_with_worker_ports(mut facade, mut host, host, req)
}

fn (runtime &EngineRuntime) primary_kind() string {
	return runtime.primary.logic_executor.kind()
}

fn (runtime &EngineRuntime) read_timeout_ms(kind string) int {
	selected := runtime.lookup_engine(kind, .worker_config) or { return 0 }
	return selected.state.worker_backend.read_timeout_ms
}

fn (runtime &EngineRuntime) worker_env(kind string) map[string]string {
	selected := runtime.lookup_engine(kind, .worker_config) or { return map[string]string{} }
	return selected.state.env_snapshot()
}

fn (runtime &EngineRuntime) primary_socket_count() int {
	return runtime.primary.worker_backend.sockets.len
}

fn (runtime &EngineRuntime) dispatch_selection(name string) EngineDispatchSelection {
	selected := runtime.lookup_engine(name, .dispatch_pool) or { panic('dispatch pool lookup must resolve') }
	return EngineDispatchSelection{
		state:           selected.state
		http_port:       executor.logic_executor_http_port(selected.state.logic_executor)
		pool:            selected.pool
		stream_dispatch: selected.state.stream_dispatch
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

// The App lock protects publication only. Dispatch retains its own registry view
// and releases that lock before any executor callback or native IO.
fn (mut app App) engine_runtime_snapshot() EngineRuntime {
	app.mu.@lock()
	defer { app.mu.unlock() }
	return EngineRuntime{ primary: app.engines.primary, additional: app.engines.additional.clone() }
}

fn (runtime &EngineRuntime) dispatch_host(mut facade executor.AppFacade) SessionDispatchHost {
	mut retained := facade
	port := worker.LifecyclePort{
		emit_fn: fn [mut retained] (kind string, fields map[string]string) {
			retained.emit(kind, fields)
		}
	}
	return SessionDispatchHost{ snapshot: new_worker_backend_request_snapshot(runtime.primary, port) }
}

fn (mut runtime EngineRuntime) dispatch_stream(mut facade executor.AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	mut host := runtime.dispatch_host(mut facade)
	return executor.logic_executor_stream_port(host.snapshot.state.logic_executor).dispatch_stream_with_worker_port(mut facade, mut host, req)
}

fn (mut runtime EngineRuntime) dispatch_mcp(mut facade executor.AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	mut host := runtime.dispatch_host(mut facade)
	return executor.logic_executor_mcp_port(host.snapshot.state.logic_executor).dispatch_mcp_with_worker_port(mut facade, mut host, req)
}

fn (mut runtime EngineRuntime) dispatch_websocket_upstream(mut facade executor.AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	mut host := runtime.dispatch_host(mut facade)
	return executor.logic_executor_websocket_upstream_port(host.snapshot.state.logic_executor).dispatch_upstream_with_worker_port(mut facade, mut host, req)
}

fn (mut runtime EngineRuntime) dispatch_websocket_event(mut facade executor.AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	mut host := runtime.dispatch_host(mut facade)
	return executor.logic_executor_websocket_event_port(host.snapshot.state.logic_executor).dispatch_event_with_worker_port(mut facade, mut host, frame)
}

fn (mut runtime EngineRuntime) open_websocket_session(mut facade executor.AppFacade, req executor.WebSocketSessionOpenRequest) !executor.WebSocketSessionOpenOutcome {
	state := runtime.primary
	mut host := worker_request_host(state, mut facade)
	return executor.logic_executor_websocket_session_port(state.logic_executor).open_with_worker_ports(mut facade, mut host, host, req)
}

fn (mut runtime EngineRuntime) dispatch_http_for_kind(kind string, mut facade executor.AppFacade, req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
	selected := runtime.lookup_engine(kind, .executor_kind) or { return error('${kind}_executor_unavailable') }
	mut state := selected.state
	mut host := worker_request_host(state, mut facade)
	return executor.logic_executor_http_port(state.logic_executor).dispatch_http_with_worker_ports(mut facade, mut host, host, req)
}

fn (mut runtime EngineRuntime) set_primary_env(key string, value string) {
	if key != '' {
		runtime.primary.set_env(key, value)
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

fn (mut runtime EngineRuntime) metrics() worker.MetricsSnapshot {
	return runtime.primary.metrics()
}

fn (mut runtime EngineRuntime) request_started(socket_path string) {
	if runtime.primary.request_started(socket_path) {
		return
	}
	for _, mut state in runtime.additional {
		if state.request_started(socket_path) {
			return
		}
	}
}

fn (mut runtime EngineRuntime) request_finished(port worker.LifecyclePort, socket_path string) {
	if runtime.primary.request_finished(port, socket_path) {
		return
	}
	for _, mut state in runtime.additional {
		if state.request_finished(port, socket_path) {
			return
		}
	}
}

fn (mut runtime EngineRuntime) request_released(socket_path string) {
	if runtime.primary.request_released(socket_path) {
		return
	}
	for _, mut state in runtime.additional {
		if state.request_released(socket_path) {
			return
		}
	}
}

fn (mut runtime EngineRuntime) select_socket_for_kind(port worker.LifecyclePort, kind string) !string {
	selected := runtime.lookup_engine(kind, .worker_config) or { return error('unknown_executor_kind:${kind}') }
	mut state := selected.state
	resolved_kind := if selected.is_primary { runtime.primary_kind() } else { kind }
	return state.select_socket_queued(port, resolved_kind)
}
