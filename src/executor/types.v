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
