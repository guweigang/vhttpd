module main

import json
import log
import net
import net.http
import net.unix
import strings
import time

fn write_frame(mut conn unix.StreamConn, payload string) ! {
	size := payload.len
	header := [u8((size >> 24) & 0xff), u8((size >> 16) & 0xff), u8((size >> 8) & 0xff), u8(size & 0xff)]
	conn.write_ptr(&header[0], 4)!
	conn.write_string(payload)!
}

fn read_exact(mut conn unix.StreamConn, size int) ![]u8 {
	mut out := []u8{len: size}
	mut read := 0
	for read < size {
		n := conn.read(mut out[read..])!
		if n <= 0 {
			return error('unexpected EOF')
		}
		read += n
	}
	return out
}

fn read_frame(mut conn unix.StreamConn) !string {
	body := read_frame_bytes(mut conn)!
	return body.bytestr()
}

fn read_frame_bytes(mut conn unix.StreamConn) ![]u8 {
	header := read_exact(mut conn, 4)!
	size_u32 := (u32(header[0]) << 24) | (u32(header[1]) << 16) | (u32(header[2]) << 8) | u32(header[3])
	size := int(size_u32)
	if size <= 0 || size > 16 * 1024 * 1024 {
		return error('invalid frame size ${size}')
	}
	return read_exact(mut conn, size)!
}

fn dispatch_via_worker(socket_path string, method string, path string, req http.Request, remote_addr string, trace_id string, req_id string, read_timeout_ms int) !WorkerResponse {
	mut conn := unix.connect_stream(socket_path)!
	if read_timeout_ms > 0 {
		conn.set_read_timeout(time.millisecond * read_timeout_ms)
	}
	defer {
		conn.close() or {}
	}
	payload := encode_worker_request(method, path, req, remote_addr, trace_id, req_id)
	write_frame(mut conn, payload)!
	resp_raw := read_frame(mut conn)!
	resp := json.decode(WorkerResponse, resp_raw)!
	return resp
}

fn encode_worker_request(method string, path string, req http.Request, remote_addr string, trace_id string, req_id string) string {
	normalized_path, query_string := normalize_request_target(path)
	query := parse_query_map(query_string)
	mut headers := header_map_from_request(req)
	if headers['x-request-id'] == '' {
		headers['x-request-id'] = req_id
	}
	cookies := cookie_map_from_request(req)
	server := server_map_from_request(req, remote_addr)
	host := server['host'] or { req.host }
	port := server['port'] or { '' }
	scheme := req.header.get(.x_forwarded_proto) or { 'http' }
	return json.encode(WorkerRequestPayload{
		id:               trace_id
		method:           method.to_upper()
		path:             normalized_path
		body:             req.data
		scheme:           scheme
		host:             host
		port:             port
		protocol_version: req.version.str().trim_left('HTTP/')
		remote_addr:      remote_addr
		query:            query
		headers:          headers
		cookies:          cookies
		attributes:       map[string]string{}
		server:           server
		uploaded_files:   []string{}
	})
}

fn try_decode_stream_start(raw string) ?WorkerStreamFrame {
	frame := json.decode(WorkerStreamFrame, raw) or { return none }
	if frame.mode == 'stream' && frame.event == 'start' {
		return frame
	}
	return none
}

fn try_decode_upstream_plan(raw string) ?WorkerUpstreamPlanFrame {
	frame := json.decode(WorkerUpstreamPlanFrame, raw) or { return none }
	if ((frame.mode == 'stream' && frame.strategy == 'upstream_plan') || frame.mode == 'upstream_plan') && frame.event == 'start' {
		return frame
	}
	return none
}

fn read_stream_response(mut conn unix.StreamConn) !StreamDispatchResponse {
	raw := read_frame(mut conn)!
	return json.decode(StreamDispatchResponse, raw)!
}

fn (mut app App) worker_backend_connect_socket_with_retry() !string {
	mut last_err := 'worker unavailable'
	for attempt in 0 .. 10 {
		socket_path := app.worker_backend_select_socket_queued() or {
			last_err = err.msg()
			if last_err.contains('worker queue full') || last_err.contains('worker queue timeout') {
				return error(last_err)
			}
			if attempt < 9 {
				time.sleep(10 * time.millisecond)
				continue
			}
			return error(last_err)
		}
		return socket_path
	}
	return error(last_err)
}

fn (mut app App) worker_backend_connect_selected() !(string, unix.StreamConn) {
	mut last_err := 'worker connect failed'
	for attempt in 0 .. 10 {
		socket_path := app.worker_backend_connect_socket_with_retry() or {
			last_err = err.msg()
			if attempt < 9 {
				time.sleep(10 * time.millisecond)
				continue
			}
			return error(last_err)
		}
		mut conn := unix.connect_stream(socket_path) or {
			last_err = err.msg()
			app.emit('worker.connect.failed', {
				'socket':  socket_path
				'attempt': '${attempt + 1}'
				'error':   last_err
			})
			if attempt < 9 {
				time.sleep(10 * time.millisecond)
				continue
			}
			return error(last_err)
		}
		return socket_path, *conn
	}
	return error(last_err)
}

fn (mut app App) worker_backend_dispatch_stream(req StreamDispatchRequest) !StreamDispatchResponse {
	selected_socket, mut conn := app.worker_backend_connect_selected()!
	app.on_worker_request_started(selected_socket)
	defer {
		app.on_worker_request_finished(selected_socket)
		conn.close() or {}
	}
	if app.worker_backend.read_timeout_ms > 0 {
		conn.set_read_timeout(time.millisecond * app.worker_backend.read_timeout_ms)
	}
	write_frame(mut conn, json.encode(req))!
	return read_stream_response(mut conn)!
}

fn read_mcp_response(mut conn unix.StreamConn) !WorkerMcpDispatchResponse {
	raw := read_frame(mut conn)!
	return json.decode(WorkerMcpDispatchResponse, raw)!
}

fn (mut app App) worker_backend_dispatch_mcp(req WorkerMcpDispatchRequest) !WorkerMcpDispatchResponse {
	selected_socket, mut conn := app.worker_backend_connect_selected()!
	app.on_worker_request_started(selected_socket)
	defer {
		app.on_worker_request_finished(selected_socket)
		conn.close() or {}
	}
	if app.worker_backend.read_timeout_ms > 0 {
		conn.set_read_timeout(time.millisecond * app.worker_backend.read_timeout_ms)
	}
	write_frame(mut conn, json.encode(req))!
	return read_mcp_response(mut conn)!
}

fn read_websocket_upstream_response(mut conn unix.StreamConn) !WorkerWebSocketUpstreamDispatchResponse {
	raw := read_frame(mut conn)!
	return json.decode(WorkerWebSocketUpstreamDispatchResponse, raw)!
}

fn (mut app App) worker_backend_dispatch_websocket_upstream(req WorkerWebSocketUpstreamDispatchRequest) !WorkerWebSocketUpstreamDispatchResponse {
	socket, mut conn := app.worker_backend_connect_selected()!
	
	app.on_worker_request_started(socket)
	defer {
		app.on_worker_request_finished(socket)
		conn.close() or {}
	}
	if app.worker_backend.read_timeout_ms > 0 {
		conn.set_read_timeout(time.millisecond * app.worker_backend.read_timeout_ms)
	}
	raw_req := json.encode(req)
	log.info('[worker-transport] 📤 dispatching websocket_upstream: ${raw_req}')
	write_frame(mut conn, raw_req)!
	return read_websocket_upstream_response(mut conn)!
}

fn status_reason_phrase(status int) string {
	return match status {
		200 { 'OK' }
		201 { 'Created' }
		202 { 'Accepted' }
		204 { 'No Content' }
		301 { 'Moved Permanently' }
		302 { 'Found' }
		304 { 'Not Modified' }
		400 { 'Bad Request' }
		401 { 'Unauthorized' }
		403 { 'Forbidden' }
		404 { 'Not Found' }
		405 { 'Method Not Allowed' }
		408 { 'Request Timeout' }
		409 { 'Conflict' }
		429 { 'Too Many Requests' }
		500 { 'Internal Server Error' }
		502 { 'Bad Gateway' }
		503 { 'Service Unavailable' }
		504 { 'Gateway Timeout' }
		else { 'OK' }
	}
}

fn write_http_stream_headers_conn(mut conn net.TcpConn, status int, content_type string, extra_headers map[string]string, chunked bool) ! {
	mut code := status
	if code <= 0 {
		code = 200
	}
	mut sb := strings.new_builder(512)
	sb.write_string('HTTP/1.1 ${code} ${status_reason_phrase(code)}\r\n')
	sb.write_string('Server: vhttpd\r\n')
	sb.write_string('Connection: close\r\n')
	if chunked {
		sb.write_string('Transfer-Encoding: chunked\r\n')
	}
	if content_type != '' {
		sb.write_string('Content-Type: ${content_type}\r\n')
	}
	for name, value in extra_headers {
		lower := name.to_lower()
		if lower == 'content-type' || lower == 'content-length' || lower == 'transfer-encoding'
			|| lower == 'connection' || lower == 'server' {
			continue
		}
		sb.write_string('${name}: ${value}\r\n')
	}
	sb.write_string('\r\n')
	conn.write_string(sb.str())!
}

fn write_http_stream_headers(mut ctx Context, status int, content_type string, extra_headers map[string]string, chunked bool) ! {
	write_http_stream_headers_conn(mut ctx.conn, status, content_type, extra_headers, chunked)!
}

fn write_chunk(mut conn net.TcpConn, data string) ! {
	if data.len == 0 {
		return
	}
	conn.write_string('${data.len:x}\r\n')!
	conn.write_string(data)!
	conn.write_string('\r\n')!
}

fn write_sse_message(mut conn net.TcpConn, frame WorkerStreamFrame) ! {
	mut sb := strings.new_builder(256)
	if frame.sse_id != '' {
		sb.write_string('id: ${frame.sse_id}\n')
	}
	if frame.sse_event != '' {
		sb.write_string('event: ${frame.sse_event}\n')
	}
	if frame.data != '' {
		sb.write_string('data: ${frame.data}\n')
	}
	if frame.sse_retry != 0 {
		sb.write_string('retry: ${frame.sse_retry}\n')
	}
	sb.write_string('\n')
	conn.write_string(sb.str())!
}

fn classify_worker_error(err_msg string) (int, string) {
	msg := err_msg.to_lower()
	if msg.contains('all workers busy') {
		return 503, 'worker_pool_exhausted'
	}
	if msg.contains('worker queue full') {
		return 503, 'worker_queue_full'
	}
	if msg.contains('worker queue timeout') {
		return 504, 'worker_queue_timeout'
	}
	if msg.contains('timed out') || msg.contains('timeout') {
		return 504, 'timeout'
	}
	return 502, 'transport_error'
}

fn read_worker_websocket_frame(mut conn unix.StreamConn) !WorkerWebSocketFrame {
	raw := read_frame(mut conn)!
	return json.decode(WorkerWebSocketFrame, raw)!
}

fn write_worker_websocket_frame(mut conn unix.StreamConn, frame WorkerWebSocketFrame) ! {
	write_frame(mut conn, json.encode(frame))!
}

fn read_worker_websocket_dispatch_response(mut conn unix.StreamConn) !WorkerWebSocketDispatchResponse {
	raw := read_frame(mut conn)!
	return json.decode(WorkerWebSocketDispatchResponse, raw)!
}

fn (mut app App) worker_backend_dispatch_websocket_event(frame WorkerWebSocketFrame) !WorkerWebSocketDispatchResponse {
	selected_socket, mut conn := app.worker_backend_connect_selected()!
	app.on_worker_request_started(selected_socket)
	defer {
		app.on_worker_request_finished(selected_socket)
		conn.close() or {}
	}
	if app.worker_backend.read_timeout_ms > 0 {
		conn.set_read_timeout(time.millisecond * app.worker_backend.read_timeout_ms)
	}
	write_worker_websocket_frame(mut conn, frame)!
	return read_worker_websocket_dispatch_response(mut conn)!
}

fn (mut app App) execute_websocket_dispatch_commands(commands []WorkerWebSocketFrame) ?WorkerWebSocketFrame {
	mut close_frame := WorkerWebSocketFrame{}
	mut has_close := false
	for cmd in commands {
		if cmd.event == 'close' {
			close_frame = cmd
			has_close = true
			continue
		}
		app.process_worker_websocket_hub_frame(cmd)
	}
	if has_close {
		return close_frame
	}
	return none
}
