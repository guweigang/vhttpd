module main

import json
import net
import net.http
import os
import time
import veb

@[heap]
struct UpstreamExecState {
mut:
	conn                net.TcpConn
	method              string
	stream_type         string
	mapper              string
	field_path          string
	fallback_field_path string
	sse_event           string
	status_code         int
	content_type        string
	response_headers    map[string]string
	headers_written     bool
	line_buf            string
	token_index         int
}

struct AdminUpstreamRuntimeSnapshot {
	active_count   int
	returned_count int
	details        bool
	limit          int
	offset         int
	sessions       []UpstreamRuntimeSession
}

fn write_upstream_output(mut conn net.TcpConn, method string, stream_type string, mapper string, piece string, token_index int) ! {
	if method.to_upper() == 'HEAD' || piece == '' {
		return
	}
	if stream_type == 'sse' {
		write_sse_message(mut conn, WorkerStreamFrame{
			sse_id:    if token_index > 0 { 'tok-${token_index}' } else { '' }
			sse_event: if mapper != '' { mapper } else { 'message' }
			data:      piece
		})!
		return
	}
	write_chunk(mut conn, piece)!
}

fn upstream_row_field(row OllamaNdjsonRow, path string) string {
	return match path {
		'message.content' { row.message.content }
		'response' { row.response }
		else { '' }
	}
}

fn write_upstream_done(mut conn net.TcpConn, method string, stream_type string, token_index int) ! {
	if method.to_upper() == 'HEAD' || stream_type != 'sse' {
		return
	}
	write_sse_message(mut conn, WorkerStreamFrame{
		sse_id:    'done-${token_index + 1}'
		sse_event: 'done'
		data:      'done'
	})!
}

fn write_upstream_error_notice(mut conn net.TcpConn, method string, stream_type string, err_msg string) ! {
	if method.to_upper() == 'HEAD' || err_msg == '' {
		return
	}
	if stream_type == 'sse' {
		write_sse_message(mut conn, WorkerStreamFrame{
			sse_event: 'error'
			data:      err_msg
		})!
		return
	}
	write_chunk(mut conn, err_msg + '\n')!
}

fn ensure_upstream_headers_written(mut state UpstreamExecState) ! {
	if state.headers_written {
		return
	}
	mut headers := state.response_headers.clone()
	if state.stream_type == 'sse' {
		headers['x-accel-buffering'] = 'no'
		write_http_stream_headers_conn(mut state.conn, state.status_code, state.content_type, headers, false)!
	} else {
		write_http_stream_headers_conn(mut state.conn, state.status_code, state.content_type, headers, true)!
	}
	state.headers_written = true
}

fn write_upstream_line(mut state UpstreamExecState, line string) ! {
	trimmed := line.trim_space()
	if trimmed == '' {
		return
	}
	row := json.decode(OllamaNdjsonRow, trimmed) or { return }
	mut piece := upstream_row_field(row, state.field_path)
	if piece == '' {
		piece = upstream_row_field(row, state.fallback_field_path)
	}
	if piece != '' {
		ensure_upstream_headers_written(mut state)!
		state.token_index++
		write_upstream_output(mut state.conn, state.method, state.stream_type, state.sse_event, piece, state.token_index)!
	}
	if row.done {
		ensure_upstream_headers_written(mut state)!
		write_upstream_done(mut state.conn, state.method, state.stream_type, state.token_index)!
	}
}

fn flush_upstream_buffer(mut state UpstreamExecState) ! {
	if state.line_buf.trim_space() == '' {
		state.line_buf = ''
		return
	}
	write_upstream_line(mut state, state.line_buf)!
	state.line_buf = ''
}

fn consume_upstream_chunk(mut state UpstreamExecState, chunk string) ! {
	if chunk == '' {
		return
	}
	state.line_buf += chunk
	for {
		idx := state.line_buf.index('\n') or { break }
		line := state.line_buf[..idx]
		state.line_buf = state.line_buf[idx + 1..]
		write_upstream_line(mut state, line)!
	}
}

const upstream_exec_nil = &UpstreamExecState(unsafe { nil })

fn upstream_progress_body_cb(request &http.Request, chunk []u8, _body_read_so_far u64, _body_expected_size u64, _status_code int) ! {
	mut state := unsafe { upstream_exec_nil }
	pstate := unsafe { &voidptr(&state) }
	unsafe {
		*pstate = request.user_ptr
	}
	consume_upstream_chunk(mut state, chunk.bytestr())!
}

fn upstream_http_method(method string) http.Method {
	return match method.to_upper() {
		'POST' { .post }
		'PUT' { .put }
		'PATCH' { .patch }
		'DELETE' { .delete }
		'HEAD' { .head }
		else { .get }
	}
}

fn validate_upstream_plan(plan WorkerUpstreamPlanFrame) ?string {
	if plan.transport != 'http' {
		return 'unsupported_transport'
	}
	if plan.codec != 'ndjson' {
		return 'unsupported_codec'
	}
	if plan.mapper !in ['ndjson_text_field', 'ndjson_sse_field'] {
		return 'unsupported_mapper'
	}
	return none
}

fn execute_upstream_plan_fixture(mut state UpstreamExecState, plan WorkerUpstreamPlanFrame) ! {
	lines := os.read_lines(plan.fixture_path)!
	for line in lines {
		consume_upstream_chunk(mut state, line + '\n')!
	}
	flush_upstream_buffer(mut state)!
}

fn execute_upstream_plan_http(mut state UpstreamExecState, plan WorkerUpstreamPlanFrame) ! {
	mut header := http.new_header()
	for name, value in plan.request_headers {
		header.add_custom(name, value) or {}
	}
	_ := http.fetch(
		url:                plan.url
		method:             upstream_http_method(plan.method)
		header:             header
		data:               plan.body
		on_progress_body:   upstream_progress_body_cb
		user_ptr:           state
		stop_copying_limit: 65536
	) or {
		return err
	}
	flush_upstream_buffer(mut state)!
}

fn execute_upstream_plan(mut app App, mut ctx Context, plan WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	if error_class := validate_upstream_plan(plan) {
		app.upstream_runtime_note_error()
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', error_class) or {}
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text('Bad Gateway')
	}
	app.upstream_runtime_register(plan, method, path, req_id, trace_id)
	defer {
		app.upstream_runtime_unregister(req_id)
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
	mut state := &UpstreamExecState{
		conn:                client_conn
		method:              method
		stream_type:         stream_type
		mapper:              plan.mapper
		field_path:          plan.meta['field_path'] or { 'message.content' }
		fallback_field_path: plan.meta['fallback_field_path'] or { 'response' }
		sse_event:           if stream_type == 'sse' { plan.meta['sse_event'] or { 'message' } } else { '' }
		status_code:         200
		content_type:        content_type
		response_headers:    response_headers.clone()
		headers_written:     false
		line_buf:            ''
		token_index:         0
	}
	if plan.fixture_path != '' {
		execute_upstream_plan_fixture(mut state, plan) or {
			app.upstream_runtime_note_error()
			app.emit('http.stream.error', {
				'method':      method.to_upper()
				'path':        normalize_path(path)
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
					write_http_stream_headers_conn(mut client_conn, 502, content_type, err_headers, false) or {}
					write_upstream_error_notice(mut client_conn, method, stream_type, err.msg()) or {}
					write_upstream_done(mut client_conn, method, stream_type, state.token_index) or {}
				} else {
					write_http_stream_headers_conn(mut client_conn, 502, 'text/plain; charset=utf-8', err_headers, true) or {}
					write_upstream_error_notice(mut client_conn, method, 'text', err.msg()) or {}
				}
				state.headers_written = true
			} else {
				write_upstream_error_notice(mut client_conn, method, stream_type, err.msg()) or {}
				if stream_type == 'sse' {
					write_upstream_done(mut client_conn, method, stream_type, state.token_index) or {}
				}
			}
		}
	} else {
		execute_upstream_plan_http(mut state, plan) or {
			app.upstream_runtime_note_error()
			app.emit('http.stream.error', {
				'method':      method.to_upper()
				'path':        normalize_path(path)
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
					write_http_stream_headers_conn(mut client_conn, 502, content_type, err_headers, false) or {}
					write_upstream_error_notice(mut client_conn, method, stream_type, err.msg()) or {}
					write_upstream_done(mut client_conn, method, stream_type, state.token_index) or {}
				} else {
					write_http_stream_headers_conn(mut client_conn, 502, 'text/plain; charset=utf-8', err_headers, true) or {}
					write_upstream_error_notice(mut client_conn, method, 'text', err.msg()) or {}
				}
				state.headers_written = true
			} else {
				write_upstream_error_notice(mut client_conn, method, stream_type, err.msg()) or {}
				if stream_type == 'sse' {
					write_upstream_done(mut client_conn, method, stream_type, state.token_index) or {}
				}
			}
		}
	}
	if !state.headers_written {
		ensure_upstream_headers_written(mut state) or {}
	}
	if stream_type != 'sse' {
		client_conn.write_string('0\r\n\r\n') or {}
	}
	client_conn.close() or {}
	app.emit('http.request', {
		'method':        method.to_upper()
		'path':          normalize_path(path)
		'status':        if state.headers_written && state.status_code > 0 { '${state.status_code}' } else { '200' }
		'request_id':    req_id
		'trace_id':      trace_id
		'duration_ms':   '${time.now().unix_milli() - start_ms}'
		'response_mode': 'stream'
		'stream_strategy': 'upstream_plan'
		'stream_type':   stream_type
		'upstream_name': plan.name
	})
	return veb.no_result()
}

fn (mut app App) upstream_runtime_register(plan WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string) {
	if req_id == '' {
		return
	}
	app.upstream_mu.@lock()
	app.upstream_sessions[req_id] = UpstreamRuntimeSession{
		id:              req_id
		request_id:      req_id
		trace_id:        trace_id
		role:            'external_upstream'
		provider:        plan.name
		method:          method.to_upper()
		path:            normalize_path(path)
		name:            plan.name
		transport:       plan.transport
		codec:           plan.codec
		mapper:          plan.mapper
		stream_type:     if plan.output_stream_type == '' { 'sse' } else { plan.output_stream_type }
		source:          if plan.fixture_path != '' { 'fixture' } else { 'http' }
		started_at_unix: time.now().unix()
	}
	app.upstream_mu.unlock()
	app.mu.@lock()
	app.stat_upstream_plans_total++
	app.mu.unlock()
}

fn (mut app App) upstream_runtime_unregister(req_id string) {
	if req_id == '' {
		return
	}
	app.upstream_mu.@lock()
	app.upstream_sessions.delete(req_id)
	app.upstream_mu.unlock()
}

fn (mut app App) upstream_runtime_note_error() {
	app.mu.@lock()
	app.stat_upstream_plan_errors_total++
	app.mu.unlock()
}

fn (mut app App) admin_upstreams_snapshot(details bool, limit int, offset int, role_filter string, provider_filter string) AdminUpstreamRuntimeSnapshot {
	app.upstream_mu.@lock()
	defer {
		app.upstream_mu.unlock()
	}
	mut sessions := []UpstreamRuntimeSession{}
	for _, session in app.upstream_sessions {
		if role_filter != '' && session.role != role_filter {
			continue
		}
		if provider_filter != '' && session.provider != provider_filter {
			continue
		}
		sessions << session
	}
	mut ordered := []UpstreamRuntimeSession{}
	mut sort_keys := []string{}
	mut session_by_key := map[string]UpstreamRuntimeSession{}
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
			sessions:       []UpstreamRuntimeSession{}
		}
	}
	mut sliced := []UpstreamRuntimeSession{}
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
