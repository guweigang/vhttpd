module main

import executor
import net.http
import net.unix
import transport

// InProcTestApp is a no-op executor.AppFacade used by inproc test files.
// It satisfies the interface so tests can call dispatch_http / warmup / etc.
// without a fully initialized App.
struct InProcTestApp {
mut:
	reserved int
}

fn (a InProcTestApp) get_runtime_config_json() string {
	return '{}'
}

fn (a InProcTestApp) worker_backend_read_timeout_ms() int {
	return 0
}

fn (a InProcTestApp) worker_backend_sockets_len() int {
	return 0
}

fn (mut a InProcTestApp) worker_backend_select_socket_queued() !string {
	return error('inproc_test_app_no_backend')
}

fn (mut a InProcTestApp) on_worker_request_started(_socket_path string) {}

fn (mut a InProcTestApp) on_worker_request_finished(_socket_path string) {}

fn (mut a InProcTestApp) worker_websocket_open(mut _conn unix.StreamConn, _req http.Request, _remote_addr string, _path string, _req_id string, _trace_id string) !(bool, int, string) {
	return error('inproc_test_app_no_websocket')
}

fn (mut a InProcTestApp) worker_backend_dispatch_stream(_req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	return error('inproc_test_app_no_stream')
}

fn (mut a InProcTestApp) worker_backend_dispatch_mcp(_req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	return error('inproc_test_app_no_mcp')
}

fn (mut a InProcTestApp) worker_backend_dispatch_websocket_upstream(_req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	return error('inproc_test_app_no_ws_upstream')
}

fn (mut a InProcTestApp) worker_backend_dispatch_websocket_event(_frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	return error('inproc_test_app_no_ws_event')
}

fn (mut a InProcTestApp) emit(_kind string, _fields map[string]string) {}

fn (mut a InProcTestApp) admin_runtime_snapshot() executor.AdminRuntimeSummary {
	return executor.AdminRuntimeSummary{}
}

fn (mut a InProcTestApp) feishu_card_bridge_dispatch_callback(_app_name string, _trace_id string, _summary executor.FeishuRuntimeEventSummary, _payload string) !executor.FeishuCardBridgeResult {
	return error('inproc_test_app_no_feishu')
}

fn (mut a InProcTestApp) execute_websocket_dispatch_commands_result(_commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
	return transport.WorkerWebSocketDispatchCommandsResult{}
}

fn (mut a InProcTestApp) run_command_envelopes(_request_id string, _dispatch_ctx DispatchContext, _commands []transport.WorkerWebSocketUpstreamCommand) string {
	return ''
}
