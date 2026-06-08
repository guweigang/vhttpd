module main

import upstream
import transport
import ws
import net.http
import time
import veb
import worker

struct UpstreamIoBridge {}

struct UpstreamRuntimeRegistry {}

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
	sessions       []ws.UpstreamRuntimeSession
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

fn UpstreamRuntimeContext.execute_plan(rt UpstreamRuntimeContext, mut ctx Context, plan transport.WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	if error_class := upstream.ExecState.validate_plan(plan) {
		rt.note_error()
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', error_class) or {}
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text('Bad Gateway')
	}
	rt.register(plan, method, path, req_id, trace_id)
	defer {
		rt.unregister(req_id)
	}
	stream_type := if plan.output_stream_type == 'text' { 'text' } else { 'sse' }
	content_type := if plan.output_content_type != '' {
		plan.output_content_type
	} else if stream_type == 'sse' {
		'text/event-stream'
	} else {
		'text/plain; charset=utf-8'
	}
	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut client_conn := ctx.conn
	mut response_headers := plan.response_headers.clone()
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
				'path':        transport.normalize_path(path)
				'request_id':  req_id
				'trace_id':    trace_id
				'error_class': 'upstream_error'
				'error':       err.msg()
			})
			if !state.headers_written {
				state.status_code = 502
				mut err_headers := response_headers.clone()
				err_headers['x-vhttpd-error-class'] = 'upstream_error'
				if stream_type == 'sse' {
					worker.WorkerHttpStreamWriter.write_headers_conn(mut client_conn, 502, content_type,
						err_headers, false) or {}
					state.write_error_notice(err.msg()) or {}
					state.write_done() or {}
				} else {
					worker.WorkerHttpStreamWriter.write_headers_conn(mut client_conn, 502,
						'text/plain; charset=utf-8', err_headers, true) or {}
					state.write_error_notice(err.msg()) or {}
				}
				state.headers_written = true
			} else {
				state.write_error_notice(err.msg()) or {}
				if stream_type == 'sse' {
					state.write_done() or {}
				}
			}
		}
	} else {
		state.execute_http(plan) or {
			rt.note_error()
			rt.emit('http.stream.error', {
				'method':      method.to_upper()
				'path':        transport.normalize_path(path)
				'request_id':  req_id
				'trace_id':    trace_id
				'error_class': 'upstream_error'
				'error':       err.msg()
			})
			if !state.headers_written {
				state.status_code = 502
				mut err_headers := response_headers.clone()
				err_headers['x-vhttpd-error-class'] = 'upstream_error'
				if stream_type == 'sse' {
					worker.WorkerHttpStreamWriter.write_headers_conn(mut client_conn, 502, content_type,
						err_headers, false) or {}
					state.write_error_notice(err.msg()) or {}
					state.write_done() or {}
				} else {
					worker.WorkerHttpStreamWriter.write_headers_conn(mut client_conn, 502,
						'text/plain; charset=utf-8', err_headers, true) or {}
					state.write_error_notice(err.msg()) or {}
				}
				state.headers_written = true
			} else {
				state.write_error_notice(err.msg()) or {}
				if stream_type == 'sse' {
					state.write_done() or {}
				}
			}
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
		'path':            transport.normalize_path(path)
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

fn (mut app App) build_upstream_runtime_context() UpstreamRuntimeContext {
	return UpstreamRuntimeContext{
		register_fn:   fn [mut app] (plan transport.WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string) {
			UpstreamRuntimeRegistry.register(mut app, plan, method, path, req_id, trace_id)
		}
		unregister_fn: fn [mut app] (req_id string) {
			UpstreamRuntimeRegistry.unregister(mut app, req_id)
		}
		note_error_fn: fn [mut app] () {
			UpstreamRuntimeRegistry.note_error(mut app)
		}
		emit_fn:       fn [mut app] (kind string, fields map[string]string) {
			app.emit(kind, fields)
		}
		snapshot_fn:   fn [mut app] (details bool, limit int, offset int, role_filter string, provider_filter string) AdminUpstreamRuntimeSnapshot {
			return UpstreamRuntimeRegistry.snapshot(mut app, details, limit, offset, role_filter,
				provider_filter)
		}
	}
}

fn (mut app App) upstream_runtime_register(plan transport.WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string) {
	runtime := app.build_upstream_runtime_context()
	runtime.register(plan, method, path, req_id, trace_id)
}

fn UpstreamRuntimeRegistry.register(mut app App, plan transport.WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string) {
	if req_id == '' {
		return
	}
	normalized_path, _ := transport.normalize_request_target(path)
	app.ws_hub.upstream_mu.@lock()
	app.ws_hub.upstream_sessions[req_id] = ws.UpstreamRuntimeSession{
		id:              req_id
		request_id:      req_id
		trace_id:        trace_id
		role:            'external_upstream'
		provider:        plan.name
		method:          method.to_upper()
		path:            normalized_path
		name:            plan.name
		transport:       plan.transport
		codec:           plan.codec
		mapper:          plan.mapper
		stream_type:     if plan.output_stream_type == '' { 'sse' } else { plan.output_stream_type }
		source:          if plan.fixture_path != '' { 'fixture' } else { 'http' }
		started_at_unix: time.now().unix()
	}
	app.ws_hub.upstream_mu.unlock()
	app.mu.@lock()
	app.ws_hub.stat_upstream_plans_total++
	app.mu.unlock()
}

fn (mut app App) upstream_runtime_unregister(req_id string) {
	runtime := app.build_upstream_runtime_context()
	runtime.unregister(req_id)
}

fn UpstreamRuntimeRegistry.unregister(mut app App, req_id string) {
	if req_id == '' {
		return
	}
	app.ws_hub.upstream_mu.@lock()
	app.ws_hub.upstream_sessions.delete(req_id)
	app.ws_hub.upstream_mu.unlock()
}

fn (mut app App) upstream_runtime_note_error() {
	runtime := app.build_upstream_runtime_context()
	runtime.note_error()
}

fn UpstreamRuntimeRegistry.note_error(mut app App) {
	app.mu.@lock()
	app.ws_hub.stat_upstream_plan_errors_total++
	app.mu.unlock()
}

fn (mut app App) admin_upstreams_snapshot(details bool, limit int, offset int, role_filter string, provider_filter string) AdminUpstreamRuntimeSnapshot {
	runtime := app.build_upstream_runtime_context()
	return runtime.snapshot(details, limit, offset, role_filter, provider_filter)
}

fn UpstreamRuntimeRegistry.snapshot(mut app App, details bool, limit int, offset int, role_filter string, provider_filter string) AdminUpstreamRuntimeSnapshot {
	app.ws_hub.upstream_mu.@lock()
	defer {
		app.ws_hub.upstream_mu.unlock()
	}
	mut sessions := []ws.UpstreamRuntimeSession{}
	for _, session in app.ws_hub.upstream_sessions {
		if role_filter != '' && session.role != role_filter {
			continue
		}
		if provider_filter != '' && session.provider != provider_filter {
			continue
		}
		sessions << session
	}
	mut ordered := []ws.UpstreamRuntimeSession{}
	mut sort_keys := []string{}
	mut session_by_key := map[string]ws.UpstreamRuntimeSession{}
	for session in sessions {
		key := '${session.started_at_unix}_${session.id}'
		sort_keys << key
		session_by_key[key] = session
	}
	sort_keys.sort()
	for key in sort_keys {
		ordered << session_by_key[key]
	}
	if !details {
		return AdminUpstreamRuntimeSnapshot{
			active_count:   ordered.len
			returned_count: 0
			details:        false
			limit:          limit
			offset:         offset
			sessions:       []ws.UpstreamRuntimeSession{}
		}
	}
	mut sliced := []ws.UpstreamRuntimeSession{}
	if offset < ordered.len {
		end := if offset + limit < ordered.len { offset + limit } else { ordered.len }
		for i in offset .. end {
			sliced << ordered[i]
		}
	}
	return AdminUpstreamRuntimeSnapshot{
		active_count:   ordered.len
		returned_count: sliced.len
		details:        true
		limit:          limit
		offset:         offset
		sessions:       sliced
	}
}
