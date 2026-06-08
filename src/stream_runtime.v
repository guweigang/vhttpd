module main

import transport
import json
import net
import net.http
import net.unix
import time
import veb
import worker

struct HttpStreamRuntime {}

struct HttpStreamChunkWriter {}

struct DispatchStreamSession {}

struct StreamRuntimeContext {
	emit_fn           fn (string, map[string]string) = unsafe { nil }
	dispatch_open_fn  fn (string, string, string, string, string, string, map[string]string, map[string]string) !transport.StreamDispatchResponse            = unsafe { nil }
	dispatch_next_fn  fn (string, string, string, string, string, map[string]string, map[string]string, map[string]string) !transport.StreamDispatchResponse = unsafe { nil }
	dispatch_close_fn fn (string, string, map[string]string, string) !transport.StreamDispatchResponse = unsafe { nil }
}

fn (rt StreamRuntimeContext) emit(kind string, fields map[string]string) {
	rt.emit_fn(kind, fields)
}

fn (rt StreamRuntimeContext) dispatch_open(method string, path string, body string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string) !transport.StreamDispatchResponse {
	return rt.dispatch_open_fn(method, path, body, remote_addr, req_id, trace_id, query, headers)
}

fn (rt StreamRuntimeContext) dispatch_next(method string, path string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string, state map[string]string) !transport.StreamDispatchResponse {
	return rt.dispatch_next_fn(method, path, remote_addr, req_id, trace_id, query, headers, state)
}

fn (rt StreamRuntimeContext) dispatch_close(req_id string, trace_id string, state map[string]string, reason string) !transport.StreamDispatchResponse {
	return rt.dispatch_close_fn(req_id, trace_id, state, reason)
}

fn (mut app App) build_stream_runtime_context() StreamRuntimeContext {
	return StreamRuntimeContext{
		emit_fn:           fn [mut app] (kind string, fields map[string]string) {
			app.emit(kind, fields)
		}
		dispatch_open_fn:  fn [mut app] (method string, path string, body string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string) !transport.StreamDispatchResponse {
			return app.kernel_stream_dispatch_open(method, path, body, remote_addr, req_id,
				trace_id, query, headers)
		}
		dispatch_next_fn:  fn [mut app] (method string, path string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string, state map[string]string) !transport.StreamDispatchResponse {
			return app.kernel_stream_dispatch_next(method, path, remote_addr, req_id, trace_id,
				query, headers, state)
		}
		dispatch_close_fn: fn [mut app] (req_id string, trace_id string, state map[string]string, reason string) !transport.StreamDispatchResponse {
			return app.kernel_stream_dispatch_close(req_id, trace_id, state, reason)
		}
	}
}

fn stream_via_sse(mut app App, mut ctx Context, mut conn unix.StreamConn, start transport.WorkerStreamFrame, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	stream_runtime := app.build_stream_runtime_context()
	return HttpStreamRuntime.direct_sse(stream_runtime, mut ctx, mut conn, start, method, path,
		req_id, trace_id, start_ms)
}

fn HttpStreamRuntime.direct_sse(rt StreamRuntimeContext, mut ctx Context, mut conn unix.StreamConn, start transport.WorkerStreamFrame, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
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
	worker.WorkerHttpStreamWriter.write_headers_conn(mut ctx.conn, status, ctype, headers, false) or {
		return veb.no_result()
	}
	for {
		raw := worker.WorkerBackendFrameCodec.read(mut conn) or { break }
		frame := json.decode(transport.WorkerStreamFrame, raw) or { continue }
		if frame.mode != 'stream' {
			continue
		}
		if frame.event == 'chunk' {
			if method.to_upper() != 'HEAD' {
				worker.WorkerHttpStreamWriter.write_sse_message(mut ctx.conn, frame) or { break }
			}
			continue
		}
		if frame.event == 'error' {
			rt.emit('http.stream.error', {
				'method':      method.to_upper()
				'path':        transport.normalize_path(path)
				'request_id':  req_id
				'trace_id':    trace_id
				'error_class': frame.error_class
				'error':       frame.error
			})
			break
		}
		if frame.event == 'end' {
			break
		}
	}
	ctx.conn.close() or {}
	rt.emit('http.request', {
		'method':          method.to_upper()
		'path':            transport.normalize_path(path)
		'status':          '${status}'
		'request_id':      req_id
		'trace_id':        trace_id
		'duration_ms':     '${time.now().unix_milli() - start_ms}'
		'response_mode':   'stream'
		'stream_strategy': 'direct'
		'stream_type':     'sse'
	})
	return veb.no_result()
}

fn stream_via_passthrough(mut app App, mut ctx Context, mut conn unix.StreamConn, start transport.WorkerStreamFrame, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	stream_runtime := app.build_stream_runtime_context()
	return HttpStreamRuntime.direct_passthrough(stream_runtime, mut ctx, mut conn, start, method,
		path, req_id, trace_id, start_ms)
}

fn HttpStreamRuntime.direct_passthrough(rt StreamRuntimeContext, mut ctx Context, mut conn unix.StreamConn, start transport.WorkerStreamFrame, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
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
	worker.WorkerHttpStreamWriter.write_headers_conn(mut ctx.conn, status, ctype, headers, true) or {
		return veb.no_result()
	}
	for {
		raw := worker.WorkerBackendFrameCodec.read(mut conn) or { break }
		frame := json.decode(transport.WorkerStreamFrame, raw) or { continue }
		if frame.mode != 'stream' {
			continue
		}
		if frame.event == 'chunk' {
			if method.to_upper() != 'HEAD' {
				worker.WorkerHttpStreamWriter.write_chunk(mut ctx.conn, frame.data) or { break }
			}
			continue
		}
		if frame.event == 'error' {
			rt.emit('http.stream.error', {
				'method':      method.to_upper()
				'path':        transport.normalize_path(path)
				'request_id':  req_id
				'trace_id':    trace_id
				'error_class': frame.error_class
				'error':       frame.error
			})
			break
		}
		if frame.event == 'end' {
			break
		}
	}
	ctx.conn.write_string('0\r\n\r\n') or {}
	ctx.conn.close() or {}
	rt.emit('http.request', {
		'method':          method.to_upper()
		'path':            transport.normalize_path(path)
		'status':          '${status}'
		'request_id':      req_id
		'trace_id':        trace_id
		'duration_ms':     '${time.now().unix_milli() - start_ms}'
		'response_mode':   'stream'
		'stream_strategy': 'direct'
		'stream_type':     if start.stream_type != '' { start.stream_type } else { 'passthrough' }
	})
	return veb.no_result()
}

fn HttpStreamChunkWriter.write_dispatch_chunks(mut conn net.TcpConn, stream_type string, chunks []transport.StreamDispatchChunk) ! {
	for chunk in chunks {
		if stream_type == 'sse' {
			worker.WorkerHttpStreamWriter.write_sse_message(mut conn, transport.WorkerStreamFrame{
				sse_id:    chunk.id
				sse_event: chunk.event
				sse_retry: chunk.retry
				data:      chunk.data
			})!
			continue
		}
		worker.WorkerHttpStreamWriter.write_chunk(mut conn, chunk.data)!
	}
}

fn DispatchStreamSession.best_effort_close(rt StreamRuntimeContext, req_id string, trace_id string, state map[string]string, reason string) {
	rt.dispatch_close(req_id, trace_id, state, reason) or { return }
}

fn stream_via_dispatch(mut app App, mut ctx Context, method string, path string, req_id string, trace_id string, remote_addr string) ?veb.Result {
	stream_runtime := app.build_stream_runtime_context()
	return HttpStreamRuntime.dispatch(stream_runtime, mut ctx, method, path, req_id, trace_id,
		remote_addr)
}

fn HttpStreamRuntime.dispatch(rt StreamRuntimeContext, mut ctx Context, method string, path string, req_id string, trace_id string, remote_addr string) ?veb.Result {
	normalized_path, query_string := transport.normalize_request_target(path)
	query := transport.parse_query_map(query_string)
	headers := transport.header_map_from_request(ctx.req)
	start_ms := time.now().unix_milli()
	open_resp := rt.dispatch_open(method, normalized_path, ctx.req.data, remote_addr, req_id,
		trace_id, query, headers) or { return none }
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
		worker.WorkerHttpStreamWriter.write_headers_conn(mut ctx.conn, status, content_type, response_headers, false) or {
			DispatchStreamSession.best_effort_close(rt, req_id, trace_id, open_resp.state,
				'client_write_error')
			return veb.no_result()
		}
	} else {
		worker.WorkerHttpStreamWriter.write_headers_conn(mut ctx.conn, status, content_type, response_headers, true) or {
			DispatchStreamSession.best_effort_close(rt, req_id, trace_id, open_resp.state,
				'client_write_error')
			return veb.no_result()
		}
	}
	if method.to_upper() != 'HEAD' {
		HttpStreamChunkWriter.write_dispatch_chunks(mut ctx.conn, stream_type, open_resp.chunks) or {
			DispatchStreamSession.best_effort_close(rt, req_id, trace_id, open_resp.state,
				'client_write_error')
			return veb.no_result()
		}
	}
	mut state := open_resp.state.clone()
	mut done := open_resp.done
	for !done {
		next_resp := rt.dispatch_next(method, normalized_path, remote_addr, req_id, trace_id,
			query, headers, state) or {
			rt.emit('http.stream.error', {
				'method':      method.to_upper()
				'path':        transport.normalize_path(path)
				'request_id':  req_id
				'trace_id':    trace_id
				'error_class': 'transport_error'
				'error':       err.msg()
			})
			break
		}
		if failure := kernel_stream_dispatch_failure(next_resp) {
			rt.emit('http.stream.error', {
				'method':      method.to_upper()
				'path':        transport.normalize_path(path)
				'request_id':  req_id
				'trace_id':    trace_id
				'error_class': failure.error_class
				'error':       failure.error
			})
			break
		}
		state = next_resp.state.clone()
		done = next_resp.done
		if method.to_upper() != 'HEAD' {
			HttpStreamChunkWriter.write_dispatch_chunks(mut ctx.conn, stream_type, next_resp.chunks) or {
				DispatchStreamSession.best_effort_close(rt, req_id, trace_id, state,
					'client_write_error')
				return veb.no_result()
			}
		}
	}
	DispatchStreamSession.best_effort_close(rt, req_id, trace_id, state, 'completed')
	if stream_type != 'sse' {
		ctx.conn.write_string('0\r\n\r\n') or {}
	}
	ctx.conn.close() or {}
	rt.emit('http.request', {
		'method':          method.to_upper()
		'path':            transport.normalize_path(path)
		'status':          '${status}'
		'request_id':      req_id
		'trace_id':        trace_id
		'duration_ms':     '${time.now().unix_milli() - start_ms}'
		'response_mode':   'stream'
		'stream_strategy': 'dispatch'
		'stream_type':     stream_type
	})
	return veb.no_result()
}
