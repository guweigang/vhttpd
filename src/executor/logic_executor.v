module executor

import upstream.transport
import json
import net.unix
import time

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
	mut socket_port := worker_socket_port(app)
	config_port := worker_backend_config_port(app)
	selected_socket := socket_port.worker_backend_select_socket_for_kind(e.kind())!
	mut conn := unix.connect_stream(selected_socket)!
	socket_port.on_worker_request_started(selected_socket)
	read_timeout := config_port.worker_backend_read_timeout_ms_for_kind(e.kind())
	if read_timeout > 0 {
		conn.set_read_timeout(time.millisecond * read_timeout)
	}
	payload := transport.WorkerHttpRequestCodec.encode_request(req.method, req.path, req.req,
		req.remote_addr, req.trace_id, req.request_id)
	transport.WorkerFrameCodec.write(mut conn, payload) or {
		conn.close() or {}
		socket_port.on_worker_request_finished(selected_socket)
		return error(err.msg())
	}
	first_raw := transport.WorkerFrameCodec.read(mut conn) or {
		conn.close() or {}
		socket_port.on_worker_request_finished(selected_socket)
		return error(err.msg())
	}
	if start := transport.WorkerStreamFrame.try_decode_start(first_raw) {
		return HttpLogicDispatchOutcome{
			kind:         .stream
			socket_path:  selected_socket
			stream_start: start
			conn:         conn
		}
	}
	if plan := transport.WorkerUpstreamPlanFrame.try_decode_start(first_raw) {
		conn.close() or {}
		socket_port.on_worker_request_finished(selected_socket)
		return HttpLogicDispatchOutcome{
			kind:          .upstream_plan
			upstream_plan: plan
		}
	}
	resp := json.decode(transport.WorkerResponse, first_raw) or {
		conn.close() or {}
		socket_port.on_worker_request_finished(selected_socket)
		return error('transport_error: decode worker response failed')
	}
	conn.close() or {}
	socket_port.on_worker_request_finished(selected_socket)
	return HttpLogicDispatchOutcome{
		kind:     .response
		response: resp
	}
}

pub fn (e SocketWorkerExecutor) open_websocket_session(mut app AppFacade, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	_ = e
	mut socket_port := worker_socket_port(app)
	config_port := worker_backend_config_port(app)
	selected_socket := socket_port.worker_backend_select_socket_queued()!
	mut worker_conn := unix.connect_stream(selected_socket)!
	read_timeout := config_port.worker_backend_read_timeout_ms()
	if read_timeout > 0 {
		worker_conn.set_read_timeout(time.millisecond * read_timeout)
	}
	accepted, status, body := socket_port.worker_websocket_open(mut worker_conn, req.req,
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
	mut port := worker_stream_dispatch_port(app)
	return port.worker_backend_dispatch_stream(req)
}

pub fn (e SocketWorkerExecutor) dispatch_mcp(mut app AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	_ = e
	mut port := worker_mcp_dispatch_port(app)
	return port.worker_backend_dispatch_mcp(req)
}

pub fn (e SocketWorkerExecutor) dispatch_websocket_upstream(mut app AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	_ = e
	mut port := worker_websocket_dispatch_port(app)
	return port.worker_backend_dispatch_websocket_upstream(req)
}

pub fn (e SocketWorkerExecutor) dispatch_websocket_event(mut app AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = e
	mut port := worker_websocket_dispatch_port(app)
	return port.worker_backend_dispatch_websocket_event(frame)
}

// Host bridge methods removed and moved to main module bridge.

pub struct PhpCgiExecutor {}

pub fn (e PhpCgiExecutor) model() LogicExecutorModel {
	_ = e
	return .worker
}

pub fn (e PhpCgiExecutor) kind() string {
	_ = e
	return 'php-cgi'
}

pub fn (e PhpCgiExecutor) provider() string {
	_ = e
	return 'php-cgi'
}

pub fn (e PhpCgiExecutor) admin_details() LogicExecutorAdminDetails {
	_ = e
	return LogicExecutorAdminDetails{
		kind:     'php-cgi'
		provider: 'php-cgi'
		model:    LogicExecutorModel.worker.str()
	}
}

pub fn (e PhpCgiExecutor) warmup(mut app AppFacade) ! {
	_ = e
	_ = app
}

pub fn (e PhpCgiExecutor) close() {
	_ = e
}

pub fn (e PhpCgiExecutor) dispatch_http(mut app AppFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	_ = e
	mut socket_port := worker_socket_port(app)
	config_port := worker_backend_config_port(app)
	selected_socket := socket_port.worker_backend_select_socket_for_kind(e.kind())!
	mut conn := unix.connect_stream(selected_socket)!
	socket_port.on_worker_request_started(selected_socket)
	read_timeout := config_port.worker_backend_read_timeout_ms_for_kind(e.kind())
	if read_timeout > 0 {
		conn.set_read_timeout(time.millisecond * read_timeout)
	}

	// FastCGI executors can run in an additional pool with its own env.
	env_overrides := config_port.worker_env_for_kind(e.kind())

	original_path := if req.original_path != '' { req.original_path } else { req.path }
	payload := transport.FastCgiCodec.encode_request(req.method, req.path, original_path, req.req,
		req.remote_addr, req.trace_id, req.request_id, env_overrides)

	conn.write_ptr(&payload[0], payload.len) or {
		conn.close() or {}
		socket_port.on_worker_request_finished(selected_socket)
		return error(err.msg())
	}

	resp := transport.FastCgiCodec.decode_response(mut conn) or {
		conn.close() or {}
		socket_port.on_worker_request_finished(selected_socket)
		return error('transport_error: decode fastcgi response failed: ${err.msg()}')
	}

	conn.close() or {}
	socket_port.on_worker_request_finished(selected_socket)

	return HttpLogicDispatchOutcome{
		kind:     .response
		response: resp
	}
}

pub fn (e PhpCgiExecutor) open_websocket_session(mut app AppFacade, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	_ = e
	_ = app
	_ = req
	return error('php-cgi executor does not support websockets')
}

pub fn (e PhpCgiExecutor) dispatch_stream(mut app AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('php-cgi executor does not support stream dispatch')
}

pub fn (e PhpCgiExecutor) dispatch_mcp(mut app AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('php-cgi executor does not support MCP dispatch')
}

pub fn (e PhpCgiExecutor) dispatch_websocket_upstream(mut app AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('php-cgi executor does not support websocket upstream')
}

pub fn (e PhpCgiExecutor) dispatch_websocket_event(mut app AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = e
	_ = app
	_ = frame
	return error('php-cgi executor does not support websocket events')
}
