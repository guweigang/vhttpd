module main

import json
import net
import net.http
import net.unix
import time
import veb

fn stream_via_sse(mut app App, mut ctx Context, mut conn unix.StreamConn, start WorkerStreamFrame, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	ctx.takeover_conn()
	mut status := start.status
	if status <= 0 {
		status = 200
	}
	mut headers := start.headers.clone()
	headers['x-request-id'] = req_id
	headers['x-vhttpd-trace-id'] = trace_id
	headers['x-accel-buffering'] = 'no'
	headers['x-vhttpd-stream-mode'] = 'direct'
	ctype := if start.content_type != '' { start.content_type } else { 'text/event-stream' }
	write_http_stream_headers(mut ctx, status, ctype, headers, false) or { return veb.no_result() }
	for {
		raw := read_frame(mut conn) or { break }
		frame := json.decode(WorkerStreamFrame, raw) or { continue }
		if frame.mode != 'stream' {
			continue
		}
		if frame.event == 'chunk' {
			if method.to_upper() != 'HEAD' {
				write_sse_message(mut ctx.conn, frame) or { break }
			}
			continue
		}
		if frame.event == 'error' {
			app.emit('http.stream.error', {
				'method': method.to_upper()
				'path': normalize_path(path)
				'request_id': req_id
				'trace_id': trace_id
				'error_class': frame.error_class
				'error': frame.error
			})
			break
		}
		if frame.event == 'end' {
			break
		}
	}
	ctx.conn.close() or {}
	app.emit('http.request', {
		'method': method.to_upper()
		'path': normalize_path(path)
		'status': '${status}'
		'request_id': req_id
		'trace_id': trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'response_mode': 'stream'
		'stream_strategy': 'direct'
		'stream_type': 'sse'
	})
	return veb.no_result()
}

fn stream_via_passthrough(mut app App, mut ctx Context, mut conn unix.StreamConn, start WorkerStreamFrame, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	ctx.takeover_conn()
	mut status := start.status
	if status <= 0 {
		status = 200
	}
	mut headers := start.headers.clone()
	headers['x-request-id'] = req_id
	headers['x-vhttpd-trace-id'] = trace_id
	headers['x-vhttpd-stream-mode'] = 'direct'
	ctype := if start.content_type != '' { start.content_type } else { 'text/plain; charset=utf-8' }
	write_http_stream_headers(mut ctx, status, ctype, headers, true) or { return veb.no_result() }
	for {
		raw := read_frame(mut conn) or { break }
		frame := json.decode(WorkerStreamFrame, raw) or { continue }
		if frame.mode != 'stream' {
			continue
		}
		if frame.event == 'chunk' {
			if method.to_upper() != 'HEAD' {
				write_chunk(mut ctx.conn, frame.data) or { break }
			}
			continue
		}
		if frame.event == 'error' {
			app.emit('http.stream.error', {
				'method': method.to_upper()
				'path': normalize_path(path)
				'request_id': req_id
				'trace_id': trace_id
				'error_class': frame.error_class
				'error': frame.error
			})
			break
		}
		if frame.event == 'end' {
			break
		}
	}
	ctx.conn.write_string('0\r\n\r\n') or {}
	ctx.conn.close() or {}
	app.emit('http.request', {
		'method': method.to_upper()
		'path': normalize_path(path)
		'status': '${status}'
		'request_id': req_id
		'trace_id': trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'response_mode': 'stream'
		'stream_strategy': 'direct'
		'stream_type': if start.stream_type != '' { start.stream_type } else { 'passthrough' }
	})
	return veb.no_result()
}

fn write_stream_chunks(mut conn net.TcpConn, stream_type string, chunks []StreamDispatchChunk) ! {
	for chunk in chunks {
		if stream_type == 'sse' {
			write_sse_message(mut conn, WorkerStreamFrame{
				sse_id: chunk.id
				sse_event: chunk.event
				sse_retry: chunk.retry
				data: chunk.data
			})!
			continue
		}
		write_chunk(mut conn, chunk.data)!
	}
}

fn best_effort_stream_close(mut app App, req_id string, trace_id string, state map[string]string, reason string) {
	app.kernel_stream_dispatch_close(req_id, trace_id, state, reason) or {
		return
	}
}

fn stream_via_dispatch(mut app App, mut ctx Context, method string, path string, req_id string, trace_id string, remote_addr string) ?veb.Result {
	normalized_path, query_string := normalize_request_target(path)
	query := parse_query_map(query_string)
	headers := header_map_from_request(ctx.req)
	start_ms := time.now().unix_milli()
	open_resp := app.kernel_stream_dispatch_open(method, normalized_path, ctx.req.data,
		remote_addr, req_id, trace_id, query, headers) or {
		return none
	}
	if failure := kernel_stream_dispatch_failure(open_resp) {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', failure.error_class) or {}
		ctx.res.set_status(http.status_from_int(500))
		return ctx.text('Internal Server Error')
	}
	if !open_resp.handled {
		return none
	}
	ctx.takeover_conn()
	status := 200
	stream_type := if open_resp.stream_type == 'text' { 'text' } else { 'sse' }
	content_type := if open_resp.content_type != '' {
		open_resp.content_type
	} else if stream_type == 'sse' {
		'text/event-stream'
	} else {
		'text/plain; charset=utf-8'
	}
	mut response_headers := open_resp.headers.clone()
	response_headers['x-request-id'] = req_id
	response_headers['x-vhttpd-trace-id'] = trace_id
	response_headers['x-vhttpd-stream-mode'] = 'dispatch'
	if stream_type == 'sse' {
		response_headers['x-accel-buffering'] = 'no'
		write_http_stream_headers(mut ctx, status, content_type, response_headers, false) or {
			best_effort_stream_close(mut app, req_id, trace_id, open_resp.state, 'client_write_error')
			return veb.no_result()
		}
	} else {
		write_http_stream_headers(mut ctx, status, content_type, response_headers, true) or {
			best_effort_stream_close(mut app, req_id, trace_id, open_resp.state, 'client_write_error')
			return veb.no_result()
		}
	}
	if method.to_upper() != 'HEAD' {
		write_stream_chunks(mut ctx.conn, stream_type, open_resp.chunks) or {
			best_effort_stream_close(mut app, req_id, trace_id, open_resp.state, 'client_write_error')
			return veb.no_result()
		}
	}
	mut state := open_resp.state.clone()
	mut done := open_resp.done
	for !done {
		next_resp := app.kernel_stream_dispatch_next(method, normalized_path, remote_addr, req_id,
			trace_id, query, headers, state) or {
			app.emit('http.stream.error', {
				'method': method.to_upper()
				'path': normalize_path(path)
				'request_id': req_id
				'trace_id': trace_id
				'error_class': 'transport_error'
				'error': err.msg()
			})
			break
		}
		if failure := kernel_stream_dispatch_failure(next_resp) {
			app.emit('http.stream.error', {
				'method': method.to_upper()
				'path': normalize_path(path)
				'request_id': req_id
				'trace_id': trace_id
				'error_class': failure.error_class
				'error': failure.error
			})
			break
		}
		state = next_resp.state.clone()
		done = next_resp.done
		if method.to_upper() != 'HEAD' {
			write_stream_chunks(mut ctx.conn, stream_type, next_resp.chunks) or {
				best_effort_stream_close(mut app, req_id, trace_id, state, 'client_write_error')
				return veb.no_result()
			}
		}
	}
	best_effort_stream_close(mut app, req_id, trace_id, state, 'completed')
	if stream_type != 'sse' {
		ctx.conn.write_string('0\r\n\r\n') or {}
	}
	ctx.conn.close() or {}
	app.emit('http.request', {
		'method': method.to_upper()
		'path': normalize_path(path)
		'status': '${status}'
		'request_id': req_id
		'trace_id': trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'response_mode': 'stream'
		'stream_strategy': 'dispatch'
		'stream_type': stream_type
	})
	return veb.no_result()
}
