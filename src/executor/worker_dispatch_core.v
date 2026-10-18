module executor

import connection_runtime
import json2 as json
import net.unix
import time
import upstream.transport

// Worker-backed HTTP and WebSocket algorithms depend only on their worker capabilities.

pub fn (e SocketWorkerExecutor) dispatch_http_with_worker_ports(mut socket_port WorkerSocketFacade, config_port WorkerBackendConfigFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	selected_socket := socket_port.worker_backend_select_socket_for_kind(e.kind())!
	mut conn := connect_worker_socket(mut socket_port, selected_socket) or {
		socket_port.on_worker_request_released(selected_socket)
		return error(err.msg())
	}
	mut lease := new_worker_request_lease(mut socket_port, selected_socket)
	mut transferred := false
	defer {
		if !transferred {
			conn.close() or {}
			lease.finish()
		}
	}
	read_timeout := config_port.worker_backend_read_timeout_ms_for_kind(e.kind())
	if read_timeout > 0 {
		conn.set_read_timeout(time.millisecond * read_timeout)
	}
	payload := transport.WorkerHttpRequestCodec.encode_request(req.method, req.path, req.req,
		req.remote_addr, req.trace_id, req.request_id)
	transport.WorkerFrameCodec.write(mut conn, payload) or {
		return error(err.msg())
	}
	first_raw := transport.WorkerFrameCodec.read(mut conn) or {
		return error(err.msg())
	}
	if start := transport.WorkerStreamFrame.try_decode_start(first_raw) {
		lease.retain_connection(conn)
		transferred = true
		return HttpLogicDispatchOutcome{
			kind:         .stream
			socket_path:  selected_socket
			stream_start: start
			conn:         conn
			lease:        lease
		}
	}
	if plan := transport.WorkerUpstreamPlanFrame.try_decode_start(first_raw) {
		return HttpLogicDispatchOutcome{
			kind:          .upstream_plan
			upstream_plan: plan
		}
	}
	resp := json.decode[transport.WorkerResponse](first_raw) or {
		return error('transport_error: decode worker response failed')
	}
	return HttpLogicDispatchOutcome{
		kind:     .response
		response: resp
	}
}

pub fn (e SocketWorkerExecutor) open_websocket_session_with_worker_ports(mut socket_port WorkerSocketFacade, config_port WorkerBackendConfigFacade, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	selected_socket := socket_port.worker_backend_select_socket_queued()!
	mut worker_conn := connect_worker_socket(mut socket_port, selected_socket) or {
		socket_port.on_worker_request_released(selected_socket)
		return error(err.msg())
	}
	if !req.register_conn_fn(worker_conn.sock.handle) {
		worker_conn.close() or {}
		socket_port.on_worker_request_released(selected_socket)
		return error('websocket_session_stopping')
	}
	mut lease := new_worker_request_lease(mut socket_port, selected_socket)
	mut transferred := false
	defer {
		if !transferred {
			worker_conn.close() or {}
			lease.finish()
		}
	}
	read_timeout := config_port.worker_backend_read_timeout_ms()
	if read_timeout > 0 {
		worker_conn.set_read_timeout(time.millisecond * read_timeout)
	}
	accepted, status, body := socket_port.worker_websocket_open(mut worker_conn, req.req,
		req.remote_addr, req.path, req.request_id, req.trace_id) or {
		return error(err.msg())
	}
	if !accepted {
		return WebSocketSessionOpenOutcome{
			accepted: false
			status:   status
			body:     body
		}
	}
	lease.retain_connection(worker_conn)
	transferred = true
	return WebSocketSessionOpenOutcome{
		lease:       lease
		accepted:    true
		status:      status
		body:        body
		socket_path: selected_socket
		conn:        worker_conn
	}
}

pub fn (e PhpCgiExecutor) dispatch_http_with_worker_ports(mut socket_port WorkerSocketFacade, config_port WorkerBackendConfigFacade, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	selected_socket := socket_port.worker_backend_select_socket_for_kind(e.kind())!
	mut conn := connect_worker_socket(mut socket_port, selected_socket) or {
		socket_port.on_worker_request_released(selected_socket)
		return error(err.msg())
	}
	mut lease := new_worker_request_lease(mut socket_port, selected_socket)
	defer {
		conn.close() or {}
		lease.finish()
	}
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
		return error(err.msg())
	}

	resp := transport.FastCgiCodec.decode_response(mut conn) or {
		return error('transport_error: decode fastcgi response failed: ${err.msg()}')
	}

	return HttpLogicDispatchOutcome{
		kind:     .response
		response: resp
	}
}

// Built-in request hosts fence dialing against slot retirement. Legacy custom
// socket-only hosts continue to use the native dial adapter.
pub interface WorkerConnectionFacade {
	WorkerSocketFacade
mut:
	worker_backend_connect_selected(path string) !&unix.StreamConn
}

fn connect_worker_socket(mut port WorkerSocketFacade, path string) !&unix.StreamConn {
	if mut port is WorkerConnectionFacade { return port.worker_backend_connect_selected(path) }
	return connection_runtime.dial_unix(path)
}
