module executor

import net.http
import net.unix
import transport

// ── HTTP dispatch types ──

pub enum HttpLogicDispatchKind {
	response
	stream
	upstream_plan
}

pub struct HttpLogicDispatchRequest {
pub:
	method      string
	path        string
	req         http.Request
	remote_addr string
	trace_id    string
	request_id  string
}

pub struct HttpLogicDispatchOutcome {
pub:
	kind          HttpLogicDispatchKind
	socket_path   string
	response      transport.WorkerResponse
	stream_start  transport.WorkerStreamFrame
	upstream_plan transport.WorkerUpstreamPlanFrame
pub mut:
	conn &unix.StreamConn = unsafe { nil }
}

pub fn (mut outcome HttpLogicDispatchOutcome) close_live_conn() {
	if isnil(outcome.conn) {
		return
	}
	outcome.conn.close() or {}
}

// ── WebSocket session types ──

pub struct WebSocketSessionOpenRequest {
pub:
	req         http.Request
	remote_addr string
	path        string
	request_id  string
	trace_id    string
}

pub struct WebSocketSessionOpenOutcome {
pub:
	accepted    bool
	status      int
	body        string
	socket_path string
pub mut:
	conn &unix.StreamConn = unsafe { nil }
}

// ── Executor model types ──

pub enum LogicExecutorModel {
	worker
	embedded
}

pub enum WorkerBackendMode {
	required
	disabled
}

pub struct LogicExecutorAdminDetails {
pub:
	kind            string
	provider        string
	model           string
	runtime_profile string
	lane_count      int
	module_root     string
	build_root      string
	signature_root  string
	max_requests    int
	enable_fs       bool
	enable_process  bool
	enable_network  bool
}

// ── Admin runtime types ──

pub struct AdminRuntimeStats {
pub:
	started_at_unix                        i64
	uptime_seconds                         i64
	http_requests_total                    i64
	http_errors_total                      i64
	http_timeouts_total                    i64
	http_streams_total                     i64
	admin_actions_total                    i64
	worker_queue_waits_total               i64
	worker_queue_rejected_total            i64
	worker_queue_timeouts_total            i64
	upstream_plans_total                   i64
	upstream_plan_errors_total             i64
	mcp_sessions_expired_total             i64
	mcp_sessions_evicted_total             i64
	mcp_pending_dropped_total              i64
	mcp_sampling_capability_warnings_total i64
	mcp_sampling_capability_dropped_total  i64
	mcp_sampling_capability_errors_total   i64
	feishu_connect_attempts                i64
	feishu_connect_successes               i64
	feishu_received_frames                 i64
	feishu_acked_events                    i64
	feishu_messages_sent                   i64
	feishu_send_errors                     i64
}

pub struct AdminRuntimeSummary {
pub:
	started_at_unix          i64
	uptime_seconds           i64
	worker_pool_size         int
	worker_backend_mode      string
	worker_queue_capacity    int
	worker_queue_timeout_ms  int
	worker_queue_depth       int
	logic_executor           string
	logic_executor_lifecycle string
	logic_executor_model     string
	logic_provider           string
	logic_executor_details   LogicExecutorAdminDetails
	capabilities             map[string]bool
	active_websockets        int
	active_upstreams         int
	active_mcp_sessions      int
	active_gateways          int
	stats                    AdminRuntimeStats
}

// ── Dispatch context ──

pub struct DispatchContext {
pub:
	session  transport.SessionHandle
	payload  string
	metadata map[string]string
	event    string
}

pub fn DispatchContext.from_websocket_upstream(req transport.WorkerWebSocketUpstreamDispatchRequest) DispatchContext {
	return DispatchContext{
		session:  transport.SessionHandle.from_websocket_upstream(req)
		payload:  req.payload
		metadata: req.metadata.clone()
		event:    req.event_type
	}
}

pub fn DispatchContext.from_stream_dispatch(req transport.StreamDispatchRequest) DispatchContext {
	return DispatchContext.from_stream_dispatch_provider(req, 'php-worker')
}

pub fn DispatchContext.from_stream_dispatch_provider(req transport.StreamDispatchRequest, provider string) DispatchContext {
	return DispatchContext{
		session: transport.SessionHandle.from_stream_dispatch_provider(req, provider)
	}
}

pub fn DispatchContext.from_mcp_dispatch(req transport.WorkerMcpDispatchRequest) DispatchContext {
	return DispatchContext.from_mcp_dispatch_provider(req, 'mcp')
}

pub fn DispatchContext.from_mcp_dispatch_provider(req transport.WorkerMcpDispatchRequest, provider string) DispatchContext {
	return DispatchContext{
		session: transport.SessionHandle.from_mcp_dispatch_provider(req, provider)
	}
}

pub fn DispatchContext.from_websocket_dispatch(frame transport.WorkerWebSocketFrame) DispatchContext {
	return DispatchContext.from_websocket_dispatch_provider(frame, 'php-worker')
}

pub fn DispatchContext.from_websocket_dispatch_provider(frame transport.WorkerWebSocketFrame, provider string) DispatchContext {
	return DispatchContext{
		session: transport.SessionHandle.from_websocket_dispatch_provider(frame, provider)
	}
}

// ── Feishu card bridge ──

pub struct FeishuCardBridgeResult {
pub:
	status  int
	headers map[string]string
	body    string
	error   string
}

// ── WebSocket upstream ──

pub struct WebSocketUpstreamCommandActivity {
pub mut:
	event          string
	provider       string
	instance       string
	target_type    string @[json: 'target_type']
	target         string
	message_type   string @[json: 'message_type']
	content        string
	content_fields map[string]string @[json: 'content_fields']
	text           string
	uuid           string
	metadata       map[string]string
	type_                string @[json: 'type']
	stream_id            string @[json: 'stream_id']
	session_key          string @[json: 'session_key']
	task_type            string @[json: 'task_type']
	prompt               string
	source_activity_id   string @[json: 'source_activity_id']
	source_command_index int    @[json: 'source_command_index']
	status               string
	error                string
	message_id           string @[json: 'message_id']
	executed_at          i64    @[json: 'executed_at']
}
