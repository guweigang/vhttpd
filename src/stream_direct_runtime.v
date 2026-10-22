module main

import upstream.transport
import encoding.base64
import json2 as json
import net.unix
import time
import veb
import worker

fn HttpStreamRuntime.direct_sse(rt StreamRuntimeContext, mut ctx Context, mut conn unix.StreamConn, start transport.WorkerStreamFrame, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	delivery := worker_stream_start_delivery_outcome(start, 'sse')
	ctx.takeover_conn()
	// Worker socket ownership remains with HttpResponseRuntime.stream.
	defer { ctx.conn.close() or {} }
	status := if delivery.status > 0 { delivery.status } else { 200 }
	mut headers := delivery.headers.clone()
	headers['x-request-id'] = req_id
	headers['x-vhttpd-trace-id'] = trace_id
	headers['x-accel-buffering'] = 'no'
	headers['x-vhttpd-stream-mode'] = 'direct'
	ctype := delivery.headers['content-type'] or { 'text/event-stream' }
	worker.WorkerHttpStreamWriter.write_headers_conn(mut ctx.conn, status, ctype, headers, false) or {
		return veb.no_result()
	}
	// HEAD returns to the outer worker owner after writing headers.
	for method.to_upper() != 'HEAD' {
		raw := worker.WorkerBackendFrameCodec.read(mut conn) or { break }
		frame := json.decode[transport.WorkerStreamFrame](raw) or { continue }
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

fn HttpStreamRuntime.direct_passthrough(rt StreamRuntimeContext, mut ctx Context, mut conn unix.StreamConn, start transport.WorkerStreamFrame, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	delivery := worker_stream_start_delivery_outcome(start, 'passthrough')
	ctx.takeover_conn()
	// Worker socket ownership remains with HttpResponseRuntime.stream.
	defer { ctx.conn.close() or {} }
	status := if delivery.status > 0 { delivery.status } else { 200 }
	mut headers := delivery.headers.clone()
	headers['x-request-id'] = req_id
	headers['x-vhttpd-trace-id'] = trace_id
	headers['x-vhttpd-stream-mode'] = 'direct'
	ctype := delivery.headers['content-type'] or { 'text/plain; charset=utf-8' }
	worker.WorkerHttpStreamWriter.write_headers_conn(mut ctx.conn, status, ctype, headers, true) or {
		return veb.no_result()
	}
	// HEAD returns to the outer worker owner after writing headers.
	for method.to_upper() != 'HEAD' {
		raw := worker.WorkerBackendFrameCodec.read(mut conn) or { break }
		frame := json.decode[transport.WorkerStreamFrame](raw) or { continue }
		if frame.mode != 'stream' {
			continue
		}
		if frame.event == 'chunk' {
			if method.to_upper() != 'HEAD' {
				data := if frame.data_base64 != '' {
					base64.decode_str(frame.data_base64)
				} else {
					frame.data
				}
				worker.WorkerHttpStreamWriter.write_chunk(mut ctx.conn, data) or { break }
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
	if method.to_upper() != 'HEAD' { ctx.conn.write_string('0\r\n\r\n') or {} }
	rt.emit('http.request', {
		'method':          method.to_upper()
		'path':            transport.WorkerHttpRequestCodec.normalize_path(path)
		'status':          '${status}'
		'request_id':      req_id
		'trace_id':        trace_id
		'duration_ms':     '${time.now().unix_milli() - start_ms}'
		'response_mode':   'stream'
		'stream_strategy': 'direct'
		'stream_type':     delivery.metadata['stream_type'] or { 'passthrough' }
	})
	return veb.no_result()
}
