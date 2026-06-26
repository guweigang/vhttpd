module executor

import net.http
import net.unix
import upstream.transport

pub interface RuntimeConfigFacade {
	get_runtime_config_json() string
	get_runtime_plan_json() string
}

pub interface WorkerBackendConfigFacade {
	worker_backend_read_timeout_ms() int
	worker_backend_sockets_len() int
	worker_env() map[string]string
	worker_env_for_kind(kind string) map[string]string
	worker_backend_read_timeout_ms_for_kind(kind string) int
}

pub interface WorkerSocketFacade {
mut:
	worker_backend_select_socket_queued() !string
	worker_backend_select_socket_for_kind(kind string) !string
	on_worker_request_started(socket_path string)
	on_worker_request_finished(socket_path string)
	worker_websocket_open(mut conn unix.StreamConn, req http.Request, remote_addr string, path string, req_id string, trace_id string) !(bool, int, string)
}

pub interface WorkerStreamDispatchFacade {
mut:
	worker_backend_dispatch_stream(req transport.StreamDispatchRequest) !transport.StreamDispatchResponse
}

pub interface WorkerMcpDispatchFacade {
mut:
	worker_backend_dispatch_mcp(req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse
}

pub interface WorkerWebSocketDispatchFacade {
mut:
	worker_backend_dispatch_websocket_upstream(req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse
	worker_backend_dispatch_websocket_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse
	execute_websocket_dispatch_commands_result(commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult
}

pub interface PlatformFacade {
mut:
	emit(kind string, fields map[string]string)
	admin_runtime_snapshot() AdminRuntimeSummary
}

pub interface ProviderBridgeFacade {
mut:
	provider_bridge_dispatch_callback(provider string, app_name string, trace_id string, summary FeishuRuntimeEventSummary, payload string) !FeishuCardBridgeResult
}

pub interface CommandDispatchFacade {
mut:
	run_command_envelopes(request_id string, dispatch_ctx DispatchContext, commands []transport.WorkerWebSocketUpstreamCommand) string
}

pub struct WorkerStreamDispatchPort {
mut:
	inner AppFacade
}

pub fn worker_stream_dispatch_port(inner AppFacade) WorkerStreamDispatchPort {
	return WorkerStreamDispatchPort{
		inner: inner
	}
}

pub fn (mut port WorkerStreamDispatchPort) worker_backend_dispatch_stream(req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	return port.inner.worker_backend_dispatch_stream(req)
}

pub struct WorkerMcpDispatchPort {
mut:
	inner AppFacade
}

pub fn worker_mcp_dispatch_port(inner AppFacade) WorkerMcpDispatchPort {
	return WorkerMcpDispatchPort{
		inner: inner
	}
}

pub fn (mut port WorkerMcpDispatchPort) worker_backend_dispatch_mcp(req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	return port.inner.worker_backend_dispatch_mcp(req)
}

pub struct WorkerWebSocketDispatchPort {
mut:
	inner AppFacade
}

pub fn worker_websocket_dispatch_port(inner AppFacade) WorkerWebSocketDispatchPort {
	return WorkerWebSocketDispatchPort{
		inner: inner
	}
}

pub fn (mut port WorkerWebSocketDispatchPort) worker_backend_dispatch_websocket_upstream(req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	return port.inner.worker_backend_dispatch_websocket_upstream(req)
}

pub fn (mut port WorkerWebSocketDispatchPort) worker_backend_dispatch_websocket_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	return port.inner.worker_backend_dispatch_websocket_event(frame)
}

pub fn (mut port WorkerWebSocketDispatchPort) execute_websocket_dispatch_commands_result(commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
	return port.inner.execute_websocket_dispatch_commands_result(commands)
}

pub struct WorkerBackendConfigPort {
	inner AppFacade
}

pub fn worker_backend_config_port(inner AppFacade) WorkerBackendConfigPort {
	return WorkerBackendConfigPort{
		inner: inner
	}
}

pub fn (port WorkerBackendConfigPort) worker_backend_read_timeout_ms() int {
	return port.inner.worker_backend_read_timeout_ms()
}

pub fn (port WorkerBackendConfigPort) worker_backend_sockets_len() int {
	return port.inner.worker_backend_sockets_len()
}

pub fn (port WorkerBackendConfigPort) worker_env() map[string]string {
	return port.inner.worker_env()
}

pub fn (port WorkerBackendConfigPort) worker_env_for_kind(kind string) map[string]string {
	return port.inner.worker_env_for_kind(kind)
}

pub fn (port WorkerBackendConfigPort) worker_backend_read_timeout_ms_for_kind(kind string) int {
	return port.inner.worker_backend_read_timeout_ms_for_kind(kind)
}

pub struct WorkerSocketPort {
mut:
	inner AppFacade
}

pub fn worker_socket_port(inner AppFacade) WorkerSocketPort {
	return WorkerSocketPort{
		inner: inner
	}
}

pub fn (mut port WorkerSocketPort) worker_backend_select_socket_queued() !string {
	return port.inner.worker_backend_select_socket_queued()
}

pub fn (mut port WorkerSocketPort) worker_backend_select_socket_for_kind(kind string) !string {
	return port.inner.worker_backend_select_socket_for_kind(kind)
}

pub fn (mut port WorkerSocketPort) on_worker_request_started(socket_path string) {
	port.inner.on_worker_request_started(socket_path)
}

pub fn (mut port WorkerSocketPort) on_worker_request_finished(socket_path string) {
	port.inner.on_worker_request_finished(socket_path)
}

pub fn (mut port WorkerSocketPort) worker_websocket_open(mut conn unix.StreamConn, req http.Request, remote_addr string, path string, req_id string, trace_id string) !(bool, int, string) {
	return port.inner.worker_websocket_open(mut conn, req, remote_addr, path, req_id, trace_id)
}
