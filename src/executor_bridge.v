module main

import executor
import upstream.transport
import net.http
import net.unix

// ── AppFacade Wrapper ──
// Wraps App to implement executor.AppFacade without V compiler C codegen bugs
// that occur when App directly implements the interface.

pub struct AppFacadeWrapper {
mut:
	app_ptr voidptr
}

pub fn new_app_facade_wrapper(mut app App) executor.AppFacade {
	return AppFacadeWrapper{
		app_ptr: voidptr(&app)
	}
}

// ── AppFacade method implementations ──
// Each method casts the stored voidptr back to &App and delegates.

pub fn (w AppFacadeWrapper) get_runtime_config_json() string {
	app := unsafe { &App(w.app_ptr) }
	return app.protocols.runtime_config_json
}

pub fn (w AppFacadeWrapper) get_runtime_plan_json() string {
	app := unsafe { &App(w.app_ptr) }
	return app.protocols.runtime_plan_json
}

pub fn (w AppFacadeWrapper) worker_backend_read_timeout_ms() int {
	app := unsafe { &App(w.app_ptr) }
	return app.engines.read_timeout_ms('')
}

pub fn (w AppFacadeWrapper) worker_backend_read_timeout_ms_for_kind(kind string) int {
	app := unsafe { &App(w.app_ptr) }
	return app.engines.read_timeout_ms(kind)
}

pub fn (w AppFacadeWrapper) worker_backend_sockets_len() int {
	app := unsafe { &App(w.app_ptr) }
	return app.engines.primary_socket_count()
}

pub fn (w AppFacadeWrapper) worker_env() map[string]string {
	app := unsafe { &App(w.app_ptr) }
	return app.engines.worker_env('')
}

pub fn (w AppFacadeWrapper) worker_env_for_kind(kind string) map[string]string {
	app := unsafe { &App(w.app_ptr) }
	return app.engines.worker_env(kind)
}

pub fn (mut w AppFacadeWrapper) worker_backend_select_socket_queued() !string {
	mut app := unsafe { &App(w.app_ptr) }
	port := app.build_engine_lifecycle_port()
	return app.engines.select_socket_for_kind(port, '')
}

pub fn (mut w AppFacadeWrapper) worker_backend_select_socket_for_kind(kind string) !string {
	mut app := unsafe { &App(w.app_ptr) }
	port := app.build_engine_lifecycle_port()
	return app.engines.select_socket_for_kind(port, kind)
}

pub fn (mut w AppFacadeWrapper) on_worker_request_started(socket_path string) {
	mut app := unsafe { &App(w.app_ptr) }
	app.on_worker_request_started(socket_path)
}

pub fn (mut w AppFacadeWrapper) on_worker_request_finished(socket_path string) {
	mut app := unsafe { &App(w.app_ptr) }
	app.on_worker_request_finished(socket_path)
}

pub fn (mut w AppFacadeWrapper) on_worker_request_released(socket_path string) {
	mut app := unsafe { &App(w.app_ptr) }
	app.on_worker_request_released(socket_path)
}

pub fn (mut w AppFacadeWrapper) worker_websocket_open(mut conn unix.StreamConn, req http.Request, remote_addr string, path string, req_id string, trace_id string) !(bool, int, string) {
	mut app := unsafe { &App(w.app_ptr) }
	return app.worker_websocket_open(mut conn, req, remote_addr, path, req_id, trace_id)
}

pub fn (mut w AppFacadeWrapper) worker_backend_dispatch_stream(req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	mut app := unsafe { &App(w.app_ptr) }
	return app.worker_backend_dispatch_stream(req)
}

pub fn (mut w AppFacadeWrapper) worker_backend_dispatch_mcp(req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	mut app := unsafe { &App(w.app_ptr) }
	return app.worker_backend_dispatch_mcp(req)
}

pub fn (mut w AppFacadeWrapper) worker_backend_dispatch_websocket_upstream(req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	mut app := unsafe { &App(w.app_ptr) }
	return app.worker_backend_dispatch_websocket_upstream(req)
}

pub fn (mut w AppFacadeWrapper) worker_backend_dispatch_websocket_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	mut app := unsafe { &App(w.app_ptr) }
	return app.worker_backend_dispatch_websocket_event(frame)
}

pub fn (mut w AppFacadeWrapper) emit(kind string, fields map[string]string) {
	mut app := unsafe { &App(w.app_ptr) }
	app.emit(kind, fields)
}

pub fn (mut w AppFacadeWrapper) admin_runtime_snapshot() executor.AdminRuntimeSummary {
	mut app := unsafe { &App(w.app_ptr) }
	return app.admin_runtime_snapshot()
}

pub fn (mut w AppFacadeWrapper) provider_bridge_dispatch_callback(provider string, app_name string, trace_id string, summary executor.FeishuRuntimeEventSummary, payload string) !executor.FeishuCardBridgeResult {
	mut app := unsafe { &App(w.app_ptr) }
	return match provider {
		websocket_upstream_provider_feishu {
			app.providers.feishu_card_bridge_dispatch_callback(app_name, trace_id, summary,
				payload)
		}
		else {
			error('provider_bridge_dispatch_unsupported:${provider}')
		}
	}
}

pub fn (mut w AppFacadeWrapper) execute_websocket_dispatch_commands_result(commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
	mut app := unsafe { &App(w.app_ptr) }
	return app.execute_websocket_dispatch_commands_result(commands)
}

pub fn (mut w AppFacadeWrapper) run_command_envelopes(request_id string, dispatch_ctx DispatchContext, commands []transport.WorkerWebSocketUpstreamCommand) string {
	mut app := unsafe { &App(w.app_ptr) }
	return app.execute_command_envelopes(request_id, dispatch_ctx, commands)
}

// ── App logic_executor proxy methods ──

pub fn (app &App) logic_executor_kind() string {
	return app.engines.primary_kind()
}

pub fn (app &App) logic_executor_model() executor.LogicExecutorModel {
	return app.engines.logic_executor_model()
}

pub fn (app &App) logic_executor_provider() string {
	return app.engines.logic_executor_provider()
}

pub fn (app &App) logic_executor_admin_details() executor.LogicExecutorAdminDetails {
	return app.engines.logic_executor_admin_details()
}

pub fn (app &App) has_http_logic_executor() bool {
	return app.engines.has_http_logic_executor()
}

pub fn (app &App) has_websocket_upstream_logic_executor() bool {
	return app.engines.has_http_logic_executor()
}

// ── Global Type Aliases ──

pub type PluginCallRequest = executor.PluginCallRequest
pub type PluginCallResponse = executor.PluginCallResponse
pub type PluginStreamCallResponse = executor.PluginStreamCallResponse
pub type PluginStreamFrameFn = fn (string) !bool

pub type VjsxRuntimeFacadeConfig = executor.VjsxRuntimeFacadeConfig
pub type InProcVjsxExecutor = executor.InProcVjsxExecutor

pub fn new_inproc_vjsx_executor(config executor.VjsxRuntimeFacadeConfig) executor.InProcVjsxExecutor {
	return executor.new_inproc_vjsx_executor(config)
}

// build_executor_factory delegates to executor module's default factory.
pub fn build_executor_factory() executor.ExecutorFactory {
	return executor.ExecutorFactory.new_default()
}

pub fn (mut app App) as_facade() executor.AppFacade {
	return new_app_facade_wrapper(mut app)
}
