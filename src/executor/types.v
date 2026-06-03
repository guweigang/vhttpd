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

pub struct AdminHttpStats {
pub:
	requests_total i64
	errors_total   i64
	timeouts_total i64
	streams_total  i64
}

pub struct AdminWorkerQueueStats {
pub:
	waits_total    i64
	rejected_total i64
	timeouts_total i64
}

pub struct AdminUpstreamStats {
pub:
	plans_total       i64
	plan_errors_total i64
}

pub struct AdminMcpStats {
pub:
	sessions_expired_total             i64
	sessions_evicted_total             i64
	pending_dropped_total              i64
	sampling_capability_warnings_total i64
	sampling_capability_dropped_total  i64
	sampling_capability_errors_total   i64
}

pub struct AdminFeishuStats {
pub:
	connect_attempts  i64
	connect_successes i64
	received_frames   i64
	acked_events      i64
	messages_sent     i64
	send_errors       i64
}

pub struct AdminRuntimeStats {
pub:
	started_at_unix i64
	uptime_seconds  i64
	http            AdminHttpStats
	worker          AdminWorkerQueueStats
	upstream        AdminUpstreamStats
	mcp             AdminMcpStats
	feishu          AdminFeishuStats
	admin_actions_total i64
}

pub struct AdminWorkerPoolSummary {
pub:
	pool_size        int
	backend_mode     string
	queue_capacity   int
	queue_timeout_ms int
	queue_depth      int
}

pub struct AdminLogicExecutorSummary {
pub:
	kind      string
	lifecycle string
	model     string
	provider  string
	details   LogicExecutorAdminDetails
}

pub struct AdminActiveCounts {
pub:
	websockets    int
	upstreams     int
	mcp_sessions  int
	gateways      int
}

pub struct AdminRuntimeSummary {
pub:
	started_at_unix  i64
	uptime_seconds   i64
	worker_pool      AdminWorkerPoolSummary
	logic_executor   AdminLogicExecutorSummary
	capabilities     map[string]bool
	active           AdminActiveCounts
	stats            AdminRuntimeStats
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

// ── Plugin Call types ──

pub struct PluginCallRequest {
pub:
	plugin     string
	capability string
	op         string
	request_id string @[json: 'request_id']
	trace_id   string @[json: 'trace_id']
	payload    string
	metadata   map[string]string
}

pub struct PluginCallResponse {
pub:
	ok     bool
	result string
	error  string
}

pub type PluginStreamFrameFn = fn (string) !bool

pub struct PluginStreamCallResponse {
pub:
	streamed bool
	response PluginCallResponse
}

// ── Kernel dispatch types ──

pub enum KernelDispatchKind {
	stream
	mcp
	websocket_upstream
	websocket_dispatch
}

pub struct KernelDispatchEnvelope {
pub:
	kind    KernelDispatchKind
	context DispatchContext
}

pub struct KernelDispatchTransportFailure {
pub:
	status      int
	error_class string
}

pub struct KernelWebSocketUpstreamDispatchOutcome {
pub:
	response          transport.WorkerWebSocketUpstreamDispatchResponse
	command_snapshots []WebSocketUpstreamCommandActivity
	command_error     string
}

pub struct KernelMcpDispatchOutcome {
pub:
	response          transport.WorkerMcpDispatchResponse
	command_snapshots []WebSocketUpstreamCommandActivity
	command_error     string
}

pub struct KernelStreamDispatchFailure {
pub:
	error       string
	error_class string
}

pub fn KernelDispatchEnvelope.from_stream_dispatch(req transport.StreamDispatchRequest) KernelDispatchEnvelope {
	return KernelDispatchEnvelope{
		kind:    .stream
		context: DispatchContext.from_stream_dispatch(req)
	}
}

pub fn KernelDispatchEnvelope.from_mcp_dispatch(req transport.WorkerMcpDispatchRequest) KernelDispatchEnvelope {
	return KernelDispatchEnvelope{
		kind:    .mcp
		context: DispatchContext.from_mcp_dispatch(req)
	}
}

pub fn KernelDispatchEnvelope.from_websocket_upstream(req transport.WorkerWebSocketUpstreamDispatchRequest) KernelDispatchEnvelope {
	return KernelDispatchEnvelope{
		kind:    .websocket_upstream
		context: DispatchContext.from_websocket_upstream(req)
	}
}

pub fn KernelDispatchEnvelope.from_websocket_dispatch(frame transport.WorkerWebSocketFrame) KernelDispatchEnvelope {
	return KernelDispatchEnvelope{
		kind:    .websocket_dispatch
		context: DispatchContext.from_websocket_dispatch(frame)
	}
}
