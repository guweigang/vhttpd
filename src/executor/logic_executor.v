module executor
import transport

import json
import net.http
import net.unix
import time

pub interface LogicExecutor {
	model() LogicExecutorModel
	kind() string
	provider() string
	admin_details() LogicExecutorAdminDetails
	warmup(mut app AppFacade) !
	close()
	dispatch_http(mut app AppFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome
	open_websocket_session(mut app AppFacade, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome
	dispatch_stream(mut app AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse
	dispatch_mcp(mut app AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse
	dispatch_websocket_upstream(mut app AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse
	dispatch_websocket_event(mut app AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse
}

pub struct DisabledLogicExecutor {}

pub fn (e DisabledLogicExecutor) model() LogicExecutorModel {
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

pub fn (e DisabledLogicExecutor) admin_details() LogicExecutorAdminDetails {
	_ = e
	return LogicExecutorAdminDetails{
		kind:     'none'
		provider: 'none'
		model:    LogicExecutorModel.worker.str()
	}
}

pub fn (e DisabledLogicExecutor) warmup(mut app AppFacade) ! {
	_ = e
	_ = app
}

pub fn (e DisabledLogicExecutor) close() {
	_ = e
}

pub fn (e DisabledLogicExecutor) dispatch_http(mut app AppFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	_ = e
	_ = app
	_ = req
	return error('logic_executor_disabled')
}

pub fn (e DisabledLogicExecutor) open_websocket_session(mut app AppFacade, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	_ = e
	_ = app
	_ = req
	return error('logic_executor_disabled')
}

pub fn (e DisabledLogicExecutor) dispatch_stream(mut app AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('logic_executor_disabled')
}

pub fn (e DisabledLogicExecutor) dispatch_mcp(mut app AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('logic_executor_disabled')
}

pub fn (e DisabledLogicExecutor) dispatch_websocket_upstream(mut app AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('logic_executor_disabled')
}

pub fn (e DisabledLogicExecutor) dispatch_websocket_event(mut app AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = e
	_ = app
	_ = frame
	return error('logic_executor_disabled')
}

pub struct SocketWorkerExecutor {}

pub fn (e SocketWorkerExecutor) model() LogicExecutorModel {
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

pub fn (e SocketWorkerExecutor) admin_details() LogicExecutorAdminDetails {
	_ = e
	return LogicExecutorAdminDetails{
		kind:     'php'
		provider: 'php-worker'
		model:    LogicExecutorModel.worker.str()
	}
}

pub fn (e SocketWorkerExecutor) warmup(mut app AppFacade) ! {
	_ = e
	_ = app
}

pub fn (e SocketWorkerExecutor) close() {
	_ = e
}

pub fn (e SocketWorkerExecutor) dispatch_http(mut app AppFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	_ = e
	selected_socket := app.worker_backend_select_socket_queued()!
	mut conn := unix.connect_stream(selected_socket)!
	app.on_worker_request_started(selected_socket)
	read_timeout := app.worker_backend_read_timeout_ms()
	if read_timeout > 0 {
		conn.set_read_timeout(time.millisecond * read_timeout)
	}
	payload := transport.encode_worker_request(req.method, req.path, req.req, req.remote_addr, req.trace_id,
		req.request_id)
	transport.write_frame(mut conn, payload) or {
		conn.close() or {}
		app.on_worker_request_finished(selected_socket)
		return error(err.msg())
	}
	first_raw := transport.read_frame(mut conn) or {
		conn.close() or {}
		app.on_worker_request_finished(selected_socket)
		return error(err.msg())
	}
	if start := transport.try_decode_stream_start(first_raw) {
		return HttpLogicDispatchOutcome{
			kind:         .stream
			socket_path:  selected_socket
			stream_start: start
			conn:         conn
		}
	}
	if plan := transport.try_decode_upstream_plan(first_raw) {
		conn.close() or {}
		app.on_worker_request_finished(selected_socket)
		return HttpLogicDispatchOutcome{
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
	return HttpLogicDispatchOutcome{
		kind:     .response
		response: resp
	}
}

pub fn (e SocketWorkerExecutor) open_websocket_session(mut app AppFacade, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	_ = e
	selected_socket := app.worker_backend_select_socket_queued()!
	mut worker_conn := unix.connect_stream(selected_socket)!
	read_timeout := app.worker_backend_read_timeout_ms()
	if read_timeout > 0 {
		worker_conn.set_read_timeout(time.millisecond * read_timeout)
	}
	accepted, status, body := app.worker_websocket_open(mut worker_conn, req.req,
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

pub fn (e SocketWorkerExecutor) dispatch_stream(mut app AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	_ = e
	return app.worker_backend_dispatch_stream(req)
}

pub fn (e SocketWorkerExecutor) dispatch_mcp(mut app AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	_ = e
	return app.worker_backend_dispatch_mcp(req)
}

pub fn (e SocketWorkerExecutor) dispatch_websocket_upstream(mut app AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	_ = e
	return app.worker_backend_dispatch_websocket_upstream(req)
}

pub fn (e SocketWorkerExecutor) dispatch_websocket_event(mut app AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = e
	return app.worker_backend_dispatch_websocket_event(frame)
}

// Host bridge methods removed and moved to main module bridge.
