module executor

import upstream.transport
import json
import net.unix
import time

pub interface LogicExecutorIdentity {
	model() LogicExecutorModel
	kind() string
	provider() string
	admin_details() LogicExecutorAdminDetails
}

pub interface LogicExecutorLifecycleOps {
	warmup(mut app AppFacade) !
	close()
}

pub interface HttpLogicExecutor {
	dispatch_http(mut app AppFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome
}

pub interface WebSocketSessionExecutor {
	open_websocket_session(mut app AppFacade, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome
}

pub interface StreamLogicExecutor {
	dispatch_stream(mut app AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse
}

pub interface McpLogicExecutor {
	dispatch_mcp(mut app AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse
}

pub interface WebSocketUpstreamExecutor {
	dispatch_websocket_upstream(mut app AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse
}

pub interface WebSocketEventExecutor {
	dispatch_websocket_event(mut app AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse
}

pub interface LogicExecutor {
	LogicExecutorIdentity
	LogicExecutorLifecycleOps
	HttpLogicExecutor
	WebSocketSessionExecutor
	StreamLogicExecutor
	McpLogicExecutor
	WebSocketUpstreamExecutor
	WebSocketEventExecutor
}

pub struct LogicExecutorHttpPort {
	inner LogicExecutor
}

pub fn logic_executor_http_port(inner LogicExecutor) LogicExecutorHttpPort {
	return LogicExecutorHttpPort{
		inner: inner
	}
}

pub fn (port LogicExecutorHttpPort) model() LogicExecutorModel {
	return port.inner.model()
}

pub fn (port LogicExecutorHttpPort) kind() string {
	return port.inner.kind()
}

pub fn (port LogicExecutorHttpPort) provider() string {
	return port.inner.provider()
}

pub fn (port LogicExecutorHttpPort) admin_details() LogicExecutorAdminDetails {
	return port.inner.admin_details()
}

pub fn (port LogicExecutorHttpPort) dispatch_http(mut app AppFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	return port.inner.dispatch_http(mut app, req)
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
	selected_socket := app.worker_backend_select_socket_for_kind(e.kind())!
	mut conn := unix.connect_stream(selected_socket)!
	app.on_worker_request_started(selected_socket)
	read_timeout := app.worker_backend_read_timeout_ms_for_kind(e.kind())
	if read_timeout > 0 {
		conn.set_read_timeout(time.millisecond * read_timeout)
	}
	payload := transport.WorkerHttpRequestCodec.encode_request(req.method, req.path, req.req,
		req.remote_addr, req.trace_id, req.request_id)
	transport.WorkerFrameCodec.write(mut conn, payload) or {
		conn.close() or {}
		app.on_worker_request_finished(selected_socket)
		return error(err.msg())
	}
	first_raw := transport.WorkerFrameCodec.read(mut conn) or {
		conn.close() or {}
		app.on_worker_request_finished(selected_socket)
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
	accepted, status, body := app.worker_websocket_open(mut worker_conn, req.req, req.remote_addr,
		req.path, req.request_id, req.trace_id) or {
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
	selected_socket := app.worker_backend_select_socket_for_kind(e.kind())!
	mut conn := unix.connect_stream(selected_socket)!
	app.on_worker_request_started(selected_socket)
	read_timeout := app.worker_backend_read_timeout_ms_for_kind(e.kind())
	if read_timeout > 0 {
		conn.set_read_timeout(time.millisecond * read_timeout)
	}

	// FastCGI executors can run in an additional pool with its own env.
	env_overrides := app.worker_env_for_kind(e.kind())

	original_path := if req.original_path != '' { req.original_path } else { req.path }
	payload := transport.FastCgiCodec.encode_request(req.method, req.path, original_path, req.req,
		req.remote_addr, req.trace_id, req.request_id, env_overrides)

	conn.write_ptr(&payload[0], payload.len) or {
		conn.close() or {}
		app.on_worker_request_finished(selected_socket)
		return error(err.msg())
	}

	resp := transport.FastCgiCodec.decode_response(mut conn) or {
		conn.close() or {}
		app.on_worker_request_finished(selected_socket)
		return error('transport_error: decode fastcgi response failed: ${err.msg()}')
	}

	conn.close() or {}
	app.on_worker_request_finished(selected_socket)

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
