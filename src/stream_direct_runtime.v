module main

import upstream.transport
import json
import net.unix
import time
import veb
import worker

fn HttpStreamRuntime.via_sse(mut app App, mut ctx Context, mut conn unix.StreamConn, start transport.WorkerStreamFrame, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
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
				'path':        transport.WorkerHttpRequestCodec.normalize_path(path)
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
		'path':            transport.WorkerHttpRequestCodec.normalize_path(path)
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

fn HttpStreamRuntime.via_passthrough(mut app App, mut ctx Context, mut conn unix.StreamConn, start transport.WorkerStreamFrame, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
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
				'path':        transport.WorkerHttpRequestCodec.normalize_path(path)
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
		'path':            transport.WorkerHttpRequestCodec.normalize_path(path)
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
