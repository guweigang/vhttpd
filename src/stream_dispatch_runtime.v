module main

import dispatch
import upstream.transport
import net
import time
import veb
import worker

struct HttpStreamChunkWriter {}

struct DispatchStreamSession {}

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

fn HttpStreamRuntime.via_dispatch(mut app App, mut ctx Context, method string, path string, req_id string, trace_id string, remote_addr string) ?veb.Result {
	stream_runtime := app.build_stream_runtime_context()
	return HttpStreamRuntime.dispatch(mut app, stream_runtime, mut ctx, method, path, req_id,
		trace_id, remote_addr)
}

fn HttpStreamRuntime.dispatch(mut app App, rt StreamRuntimeContext, mut ctx Context, method string, path string, req_id string, trace_id string, remote_addr string) ?veb.Result {
	normalized_path, query_string := transport.WorkerHttpRequestCodec.normalize_request_target(path)
	query := transport.WorkerHttpRequestCodec.parse_query_map(query_string)
	headers := transport.WorkerHttpRequestCodec.header_map_from_request(ctx.req)
	start_ms := time.now().unix_milli()
	open_resp := rt.dispatch_open(method, normalized_path, ctx.req.data, remote_addr, req_id,
		trace_id, query, headers) or { return none }
	if failure := KernelDispatchFailureMapper.from_stream_response(open_resp) {
		return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request(method,
			path, path, '', remote_addr, req_id, trace_id, start_ms), dispatch.outcome_with_metadata(dispatch.response_outcome(500, {
			'content-type':          'text/plain; charset=utf-8'
			'x-vhttpd-error-class':  failure.error_class
			'x-vhttpd-stream-mode':  'dispatch'
			'x-vhttpd-stream-stage': 'open'
		}, 'Internal Server Error'), {
			'error_class':  failure.error_class
			'error':        failure.error
			'stream_mode':  'dispatch'
			'stream_stage': 'open'
		}), none)
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
		worker.WorkerHttpStreamWriter.write_headers_conn(mut ctx.conn, status, content_type,
			response_headers, false) or {
			DispatchStreamSession.best_effort_close(rt, req_id, trace_id, open_resp.state,
				'client_write_error')
			return veb.no_result()
		}
	} else {
		worker.WorkerHttpStreamWriter.write_headers_conn(mut ctx.conn, status, content_type,
			response_headers, true) or {
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
				'path':        transport.WorkerHttpRequestCodec.normalize_path(path)
				'request_id':  req_id
				'trace_id':    trace_id
				'error_class': 'transport_error'
				'error':       err.msg()
			})
			break
		}
		if failure := KernelDispatchFailureMapper.from_stream_response(next_resp) {
			rt.emit('http.stream.error', {
				'method':      method.to_upper()
				'path':        transport.WorkerHttpRequestCodec.normalize_path(path)
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
		'path':            transport.WorkerHttpRequestCodec.normalize_path(path)
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
