module main
import transport
import executor

import json
import net.http
import net.unix
import time

pub interface LogicExecutor {
	model() executor.LogicExecutorModel
	kind() string
	provider() string
	admin_details() executor.LogicExecutorAdminDetails
	warmup(mut app App) !
	close()
	dispatch_http(mut app App, req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome
	open_websocket_session(mut app App, req executor.WebSocketSessionOpenRequest) !executor.WebSocketSessionOpenOutcome
	dispatch_stream(mut app App, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse
	dispatch_mcp(mut app App, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse
	dispatch_websocket_upstream(mut app App, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse
	dispatch_websocket_event(mut app App, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse
}

pub struct DisabledLogicExecutor {}

pub fn (e DisabledLogicExecutor) model() executor.LogicExecutorModel {
	_ = e
	return .worker
}

pub fn (e DisabledLogicExecutor) kind() string {
	_ = e
	return 'none'
}

pub fn (e DisabledLogicExecutor) provider() string {
	_ = e
	return 'none'
}

pub fn (e DisabledLogicExecutor) admin_details() executor.LogicExecutorAdminDetails {
	_ = e
	return executor.LogicExecutorAdminDetails{
		kind:     'none'
		provider: 'none'
		model:    executor.LogicExecutorModel.worker.str()
	}
}

pub fn (e DisabledLogicExecutor) warmup(mut app App) ! {
	_ = e
	_ = app
}

pub fn (e DisabledLogicExecutor) close() {
	_ = e
}

pub fn (e DisabledLogicExecutor) dispatch_http(mut app App, req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
	_ = e
	_ = app
	_ = req
	return error('logic_executor_disabled')
}

pub fn (e DisabledLogicExecutor) open_websocket_session(mut app App, req executor.WebSocketSessionOpenRequest) !executor.WebSocketSessionOpenOutcome {
	_ = e
	_ = app
	_ = req
	return error('logic_executor_disabled')
}

pub fn (e DisabledLogicExecutor) dispatch_stream(mut app App, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('logic_executor_disabled')
}

pub fn (e DisabledLogicExecutor) dispatch_mcp(mut app App, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('logic_executor_disabled')
}

pub fn (e DisabledLogicExecutor) dispatch_websocket_upstream(mut app App, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('logic_executor_disabled')
}

pub fn (e DisabledLogicExecutor) dispatch_websocket_event(mut app App, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = e
	_ = app
	_ = frame
	return error('logic_executor_disabled')
}

pub struct SocketWorkerExecutor {}

pub fn (e SocketWorkerExecutor) model() executor.LogicExecutorModel {
	_ = e
	return .worker
}

pub fn (e SocketWorkerExecutor) kind() string {
	_ = e
	return 'php'
}

pub fn (e SocketWorkerExecutor) provider() string {
	_ = e
	return 'php-worker'
}

pub fn (e SocketWorkerExecutor) admin_details() executor.LogicExecutorAdminDetails {
	_ = e
	return executor.LogicExecutorAdminDetails{
		kind:     'php'
		provider: 'php-worker'
		model:    executor.LogicExecutorModel.worker.str()
	}
}

pub fn (e SocketWorkerExecutor) warmup(mut app App) ! {
	_ = e
	_ = app
}

pub fn (e SocketWorkerExecutor) close() {
	_ = e
}

pub fn (e SocketWorkerExecutor) dispatch_http(mut app App, req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
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
		return executor.HttpLogicDispatchOutcome{
			kind:         .stream
			socket_path:  selected_socket
			stream_start: start
			conn:         conn
		}
	}
	if plan := try_decode_upstream_plan(first_raw) {
		conn.close() or {}
		app.on_worker_request_finished(selected_socket)
		return executor.HttpLogicDispatchOutcome{
			kind:          .upstream_plan
			upstream_plan: plan
		}
	}
	resp := json.decode(transport.WorkerResponse, first_raw) or {
		conn.close() or {}
		app.on_worker_request_finished(selected_socket)
		return error('transport_error: decode worker response failed')
	}
	conn.close() or {}
	app.on_worker_request_finished(selected_socket)
	return executor.HttpLogicDispatchOutcome{
		kind:     .response
		response: resp
	}
}

pub fn (e SocketWorkerExecutor) open_websocket_session(mut app App, req executor.WebSocketSessionOpenRequest) !executor.WebSocketSessionOpenOutcome {
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
		return executor.WebSocketSessionOpenOutcome{
			accepted: false
			status:   status
			body:     body
		}
	}
	return executor.WebSocketSessionOpenOutcome{
		accepted:    true
		status:      status
		body:        body
		socket_path: selected_socket
		conn:        worker_conn
	}
}

pub fn (e SocketWorkerExecutor) dispatch_stream(mut app App, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	_ = e
	return app.worker_backend_dispatch_stream(req)
}

pub fn (e SocketWorkerExecutor) dispatch_mcp(mut app App, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	_ = e
	return app.worker_backend_dispatch_mcp(req)
}

pub fn (e SocketWorkerExecutor) dispatch_websocket_upstream(mut app App, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	_ = e
	return app.worker_backend_dispatch_websocket_upstream(req)
}

pub fn (e SocketWorkerExecutor) dispatch_websocket_event(mut app App, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = e
	return app.worker_backend_dispatch_websocket_event(frame)
}

pub fn (app &App) logic_executor_kind() string {
	return app.logic_executor.kind()
}

pub fn (app &App) logic_executor_model() executor.LogicExecutorModel {
	return app.logic_executor.model()
}

pub fn (app &App) logic_executor_provider() string {
	return app.logic_executor.provider()
}

pub fn (app &App) logic_executor_admin_details() executor.LogicExecutorAdminDetails {
	return app.logic_executor.admin_details()
}

pub fn (app &App) has_http_logic_executor() bool {
	return app.worker_backend.sockets.len > 0 || app.logic_executor.model() == .embedded
}

pub fn (app &App) has_websocket_upstream_logic_executor() bool {
	return app.worker_backend.sockets.len > 0 || app.logic_executor.model() == .embedded
}
