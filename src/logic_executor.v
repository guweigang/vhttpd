module main

import json
import net.http
import net.unix
import time

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
	response      WorkerResponse
	stream_start  WorkerStreamFrame
	upstream_plan WorkerUpstreamPlanFrame
mut:
	conn &unix.StreamConn = unsafe { nil }
}

pub fn (mut outcome HttpLogicDispatchOutcome) close_live_conn() {
	if isnil(outcome.conn) {
		return
	}
	outcome.conn.close() or {}
}

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
mut:
	conn &unix.StreamConn = unsafe { nil }
}

pub interface LogicExecutor {
	kind() string
	provider() string
	dispatch_http(mut app App, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome
	open_websocket_session(mut app App, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome
	dispatch_stream(mut app App, req StreamDispatchRequest) !StreamDispatchResponse
	dispatch_mcp(mut app App, req WorkerMcpDispatchRequest) !WorkerMcpDispatchResponse
	dispatch_websocket_upstream(mut app App, req WorkerWebSocketUpstreamDispatchRequest) !WorkerWebSocketUpstreamDispatchResponse
	dispatch_websocket_event(mut app App, frame WorkerWebSocketFrame) !WorkerWebSocketDispatchResponse
}

pub struct SocketWorkerExecutor {}

pub fn (e SocketWorkerExecutor) kind() string {
	_ = e
	return 'php'
}

pub fn (e SocketWorkerExecutor) provider() string {
	_ = e
	return 'php-worker'
}

pub fn (e SocketWorkerExecutor) dispatch_http(mut app App, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	_ = e
	selected_socket := app.worker_backend_select_socket_queued()!
	mut conn := unix.connect_stream(selected_socket)!
	app.on_worker_request_started(selected_socket)
	if app.worker_backend.read_timeout_ms > 0 {
		conn.set_read_timeout(time.millisecond * app.worker_backend.read_timeout_ms)
	}
	payload := encode_worker_request(req.method, req.path, req.req, req.remote_addr, req.trace_id,
		req.request_id)
	write_frame(mut conn, payload) or {
		conn.close() or {}
		app.on_worker_request_finished(selected_socket)
		return error(err.msg())
	}
	first_raw := read_frame(mut conn) or {
		conn.close() or {}
		app.on_worker_request_finished(selected_socket)
		return error(err.msg())
	}
	if start := try_decode_stream_start(first_raw) {
		return HttpLogicDispatchOutcome{
			kind:         .stream
			socket_path:  selected_socket
			stream_start: start
			conn:         conn
		}
	}
	if plan := try_decode_upstream_plan(first_raw) {
		conn.close() or {}
		app.on_worker_request_finished(selected_socket)
		return HttpLogicDispatchOutcome{
			kind:          .upstream_plan
			upstream_plan: plan
		}
	}
	resp := json.decode(WorkerResponse, first_raw) or {
		conn.close() or {}
		app.on_worker_request_finished(selected_socket)
		return error('transport_error: decode worker response failed')
	}
	conn.close() or {}
	app.on_worker_request_finished(selected_socket)
	return HttpLogicDispatchOutcome{
		kind:     .response
		response: resp
	}
}

pub fn (e SocketWorkerExecutor) open_websocket_session(mut app App, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	_ = e
	selected_socket := app.worker_backend_select_socket_queued()!
	mut worker_conn := unix.connect_stream(selected_socket)!
	if app.worker_backend.read_timeout_ms > 0 {
		worker_conn.set_read_timeout(time.millisecond * app.worker_backend.read_timeout_ms)
	}
	accepted, status, body := worker_websocket_open(mut app, mut worker_conn, req.req,
		req.remote_addr, req.path, req.request_id, req.trace_id) or {
		worker_conn.close() or {}
		return error(err.msg())
	}
	if !accepted {
		worker_conn.close() or {}
		return WebSocketSessionOpenOutcome{
			accepted: false
			status:   status
			body:     body
		}
	}
	return WebSocketSessionOpenOutcome{
		accepted:    true
		status:      status
		body:        body
		socket_path: selected_socket
		conn:        worker_conn
	}
}

pub fn (e SocketWorkerExecutor) dispatch_stream(mut app App, req StreamDispatchRequest) !StreamDispatchResponse {
	_ = e
	return app.worker_backend_dispatch_stream(req)
}

pub fn (e SocketWorkerExecutor) dispatch_mcp(mut app App, req WorkerMcpDispatchRequest) !WorkerMcpDispatchResponse {
	_ = e
	return app.worker_backend_dispatch_mcp(req)
}

pub fn (e SocketWorkerExecutor) dispatch_websocket_upstream(mut app App, req WorkerWebSocketUpstreamDispatchRequest) !WorkerWebSocketUpstreamDispatchResponse {
	_ = e
	return app.worker_backend_dispatch_websocket_upstream(req)
}

pub fn (e SocketWorkerExecutor) dispatch_websocket_event(mut app App, frame WorkerWebSocketFrame) !WorkerWebSocketDispatchResponse {
	_ = e
	return app.worker_backend_dispatch_websocket_event(frame)
}

pub fn (app &App) logic_executor_kind() string {
	return app.logic_executor.kind()
}

pub fn (app &App) logic_executor_provider() string {
	return app.logic_executor.provider()
}

pub fn (app &App) has_http_logic_executor() bool {
	return app.worker_backend.sockets.len > 0 || app.logic_executor.kind() != 'php'
}

pub fn (app &App) has_websocket_upstream_logic_executor() bool {
	return app.worker_backend.sockets.len > 0 || app.logic_executor.kind() != 'php'
}
