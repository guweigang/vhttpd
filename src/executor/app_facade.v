module executor

import transport
import net.http
import net.unix

pub interface AppFacade {
	// Config & Backend details
	runtime_config_json() string
	worker_backend_read_timeout_ms() int
	worker_backend_sockets_len() int

	// Worker Backend routing/lifecycle methods
	worker_backend_select_socket_queued() !string
	on_worker_request_started(socket_path string)
	on_worker_request_finished(socket_path string)
	worker_websocket_open(mut conn unix.StreamConn, req http.Request, remote_addr string, path string, req_id string, trace_id string) !(bool, int, string)
	worker_backend_dispatch_stream(req transport.StreamDispatchRequest) !transport.StreamDispatchResponse
	worker_backend_dispatch_mcp(req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse
	worker_backend_dispatch_websocket_upstream(req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse
	worker_backend_dispatch_websocket_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse

	// Platform & Dispatcher methods
	emit(kind string, fields map[string]string)
	admin_runtime_snapshot() AdminRuntimeSummary
	feishu_card_bridge_dispatch_callback(app_name string, trace_id string, summary FeishuRuntimeEventSummary, payload string) !FeishuCardBridgeResult
	execute_websocket_dispatch_commands_result(commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult
	execute_command_envelopes(request_id string, dispatch_ctx DispatchContext, commands []transport.WorkerWebSocketUpstreamCommand) ([]WebSocketUpstreamCommandActivity, string)
}

pub struct FeishuRuntimeEventSummary {
pub mut:
	event_id          string
	event_kind        string
	event_type        string
	message_id        string
	message_type      string
	chat_id           string
	chat_type         string
	target_type       string
	target            string
	open_message_id   string
	root_id           string
	parent_id         string
	create_time       string
	sender_id         string
	sender_id_type    string
	sender_tenant_key string
	action_tag        string
	action_value      string
	token             string
}
