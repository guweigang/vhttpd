module main

import dispatch
import net
import time
import upstream
import upstream.transport
import veb
import worker

struct UpstreamIoBridge {}

struct UpstreamRuntimeContext {
	register_fn   fn (transport.WorkerUpstreamPlanFrame, string, string, string, string) = unsafe { nil }
	unregister_fn fn (string)                    = unsafe { nil }
	note_error_fn fn ()                          = unsafe { nil }
	emit_fn       fn (string, map[string]string) = unsafe { nil }
	snapshot_fn   fn (bool, int, int, string, string) AdminUpstreamRuntimeSnapshot = unsafe { nil }
}

fn UpstreamIoBridge.build() upstream.Io {
	return upstream.Io{
		write_sse_message:              worker.WorkerHttpStreamWriter.write_sse_message
		write_chunk:                    worker.WorkerHttpStreamWriter.write_chunk
		write_http_stream_headers_conn: worker.WorkerHttpStreamWriter.write_headers_conn
	}
}

struct AdminUpstreamRuntimeSnapshot {
	active_count   int
	returned_count int
	details        bool
	limit          int
	offset         int
	sessions       []upstream.UpstreamRuntimeSession
}

fn (rt UpstreamRuntimeContext) register(plan transport.WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string) {
	rt.register_fn(plan, method, path, req_id, trace_id)
}

fn (rt UpstreamRuntimeContext) unregister(req_id string) {
	rt.unregister_fn(req_id)
}

fn (rt UpstreamRuntimeContext) note_error() {
	rt.note_error_fn()
}

fn (rt UpstreamRuntimeContext) emit(kind string, fields map[string]string) {
	rt.emit_fn(kind, fields)
}

fn (rt UpstreamRuntimeContext) snapshot(details bool, limit int, offset int, role_filter string, provider_filter string) AdminUpstreamRuntimeSnapshot {
	return rt.snapshot_fn(details, limit, offset, role_filter, provider_filter)
}

fn UpstreamRuntimeContext.execute_plan(rt UpstreamRuntimeContext, mut app App, mut ctx Context, plan transport.WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	if error_class := upstream.ExecState.validate_plan(plan) {
		rt.note_error()
		return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request(method,
			path, path, '', if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } },
			req_id, trace_id, start_ms), dispatch.outcome_with_metadata(dispatch.response_outcome(502, {
			'content-type':          'text/plain; charset=utf-8'
			'x-vhttpd-error-class':  error_class
			'x-vhttpd-stream-mode':  'upstream_plan'
			'x-vhttpd-stream-stage': 'validate'
		}, 'Bad Gateway'), {
			'error_class':  error_class
			'stream_mode':  'upstream_plan'
			'stream_stage': 'validate'
		}), none)
	}
	rt.register(plan, method, path, req_id, trace_id)
	defer {
		rt.unregister(req_id)
	}
	delivery := upstream_plan_delivery_outcome(plan)
	stream_type := delivery.metadata['stream_type'] or { 'sse' }
	content_type := delivery.headers['content-type'] or { 'text/event-stream' }
	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut client_conn := ctx.conn
	mut response_headers := delivery.headers.clone()
	response_headers['x-request-id'] = req_id
	response_headers['x-vhttpd-trace-id'] = trace_id
	response_headers['x-vhttpd-stream-mode'] = 'upstream_plan'
	mut state := &upstream.ExecState{
		io:                  UpstreamIoBridge.build()
		conn:                client_conn
		method:              method
		stream_type:         stream_type
		mapper:              plan.mapper
		field_path:          plan.meta['field_path'] or { 'message.content' }
		fallback_field_path: plan.meta['fallback_field_path'] or { 'response' }
		sse_event:           if stream_type == 'sse' {
			plan.meta['sse_event'] or { 'message' }
		} else {
			''
		}
		status_code:         200
		content_type:        content_type
		response_headers:    response_headers.clone()
		headers_written:     false
		line_buf:            ''
		token_index:         0
	}
	if plan.fixture_path != '' {
		state.execute_fixture(plan) or {
			rt.note_error()
			rt.emit('http.stream.error', {
				'method':      method.to_upper()
				'path':        transport.WorkerHttpRequestCodec.normalize_path(path)
				'request_id':  req_id
				'trace_id':    trace_id
				'error_class': 'upstream_error'
				'error':       err.msg()
			})
			UpstreamRuntimeContext.write_error(mut state, mut client_conn, response_headers,
				content_type, stream_type, err.msg())
		}
	} else {
		state.execute_http(plan) or {
			rt.note_error()
			rt.emit('http.stream.error', {
				'method':      method.to_upper()
				'path':        transport.WorkerHttpRequestCodec.normalize_path(path)
				'request_id':  req_id
				'trace_id':    trace_id
				'error_class': 'upstream_error'
				'error':       err.msg()
			})
			UpstreamRuntimeContext.write_error(mut state, mut client_conn, response_headers,
				content_type, stream_type, err.msg())
		}
	}
	if !state.headers_written {
		state.ensure_headers_written() or {}
	}
	if stream_type != 'sse' {
		client_conn.write_string('0\r\n\r\n') or {}
	}
	client_conn.close() or {}
	rt.emit('http.request', {
		'method':          method.to_upper()
		'path':            transport.WorkerHttpRequestCodec.normalize_path(path)
		'status':          if state.headers_written && state.status_code > 0 {
			'${state.status_code}'
		} else {
			'200'
		}
		'request_id':      req_id
		'trace_id':        trace_id
		'duration_ms':     '${time.now().unix_milli() - start_ms}'
		'response_mode':   'stream'
		'stream_strategy': 'upstream_plan'
		'stream_type':     stream_type
		'upstream_name':   plan.name
	})
	return veb.no_result()
}

fn UpstreamRuntimeContext.write_error(mut state upstream.ExecState, mut client_conn net.TcpConn, response_headers map[string]string, content_type string, stream_type string, message string) {
	if !state.headers_written {
		state.status_code = 502
		mut err_headers := response_headers.clone()
		err_headers['x-vhttpd-error-class'] = 'upstream_error'
		if stream_type == 'sse' {
			worker.WorkerHttpStreamWriter.write_headers_conn(mut client_conn, 502, content_type,
				err_headers, false) or {}
			state.write_error_notice(message) or {}
			state.write_done() or {}
		} else {
			worker.WorkerHttpStreamWriter.write_headers_conn(mut client_conn, 502,
				'text/plain; charset=utf-8', err_headers, true) or {}
			state.write_error_notice(message) or {}
		}
		state.headers_written = true
		return
	}
	state.write_error_notice(message) or {}
	if stream_type == 'sse' {
		state.write_done() or {}
	}
}
