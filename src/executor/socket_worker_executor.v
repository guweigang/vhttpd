module executor

import json
import net.unix
import time
import upstream.transport

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
	mut conn := unix.connect_stream(selected_socket) or {
		socket_port.on_worker_request_released(selected_socket)
		return error(err.msg())
	}
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
	mut worker_conn := unix.connect_stream(selected_socket) or {
		socket_port.on_worker_request_released(selected_socket)
		return error(err.msg())
	}
	read_timeout := config_port.worker_backend_read_timeout_ms()
	if read_timeout > 0 {
		worker_conn.set_read_timeout(time.millisecond * read_timeout)
	}
	accepted, status, body := socket_port.worker_websocket_open(mut worker_conn, req.req,
		req.remote_addr, req.path, req.request_id, req.trace_id) or {
		worker_conn.close() or {}
		socket_port.on_worker_request_finished(selected_socket)
		return error(err.msg())
	}
	if !accepted {
		worker_conn.close() or {}
		socket_port.on_worker_request_finished(selected_socket)
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
