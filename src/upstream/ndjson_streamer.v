module upstream

import transport

import json
import net.http
import os

// ── Row/field helpers ──

// field extracts a piece from an NDJSON row by path.
pub fn (row OllamaNdjsonRow) field(path string) string {
	return match path {
		'message.content' { row.message.content }
		'response' { row.response }
		else { '' }
	}
}

// ── Stream output methods ──

pub fn (mut state ExecState) write_output(piece string) ! {
	if state.method.to_upper() == 'HEAD' || piece == '' {
		return
	}
	if state.stream_type == 'sse' {
		state.io.write_sse_message(mut state.conn, transport.WorkerStreamFrame{
			sse_id:    if state.token_index > 0 { 'tok-${state.token_index}' } else { '' }
			sse_event: if state.mapper != '' { state.mapper } else { 'message' }
			data:      piece
		})!
		return
	}
	state.io.write_chunk(mut state.conn, piece)!
}

pub fn (mut state ExecState) write_done() ! {
	if state.method.to_upper() == 'HEAD' || state.stream_type != 'sse' {
		return
	}
	state.io.write_sse_message(mut state.conn, transport.WorkerStreamFrame{
		sse_id:    'done-${state.token_index + 1}'
		sse_event: 'done'
		data:      'done'
	})!
}

pub fn (mut state ExecState) write_error_notice(err_msg string) ! {
	if state.method.to_upper() == 'HEAD' || err_msg == '' {
		return
	}
	if state.stream_type == 'sse' {
		state.io.write_sse_message(mut state.conn, transport.WorkerStreamFrame{
			sse_event: 'error'
			data:      err_msg
		})!
		return
	}
	state.io.write_chunk(mut state.conn, err_msg + '\n')!
}

pub fn (mut state ExecState) ensure_headers_written() ! {
	if state.headers_written {
		return
	}
	mut headers := state.response_headers.clone()
	if state.stream_type == 'sse' {
		headers['x-accel-buffering'] = 'no'
		state.io.write_http_stream_headers_conn(mut state.conn, state.status_code, state.content_type, headers, false)!
	} else {
		state.io.write_http_stream_headers_conn(mut state.conn, state.status_code, state.content_type, headers, true)!
	}
	state.headers_written = true
}

// ── Line/chunk parsing ──

pub fn (mut state ExecState) write_line(line string) ! {
	trimmed := line.trim_space()
	if trimmed == '' {
		return
	}
	row := json.decode(OllamaNdjsonRow, trimmed) or { return }
	mut piece := row.field(state.field_path)
	if piece == '' {
		piece = row.field(state.fallback_field_path)
	}
	if piece != '' {
		state.ensure_headers_written()!
		state.token_index++
		state.write_output(piece)!
	}
	if row.done {
		state.ensure_headers_written()!
		state.write_done()!
	}
}

pub fn (mut state ExecState) flush_buffer() ! {
	if state.line_buf.trim_space() == '' {
		state.line_buf = ''
		return
	}
	state.write_line(state.line_buf)!
	state.line_buf = ''
}

pub fn (mut state ExecState) consume_chunk(chunk string) ! {
	if chunk == '' {
		return
	}
	state.line_buf += chunk
	for {
		idx := state.line_buf.index('\n') or { break }
		line := state.line_buf[..idx]
		state.line_buf = state.line_buf[idx + 1..]
		state.write_line(line)!
	}
}

// ── HTTP progress callback ──

const exec_nil = &ExecState(unsafe { nil })

pub fn progress_body_cb(request &http.Request, chunk []u8, _body_read_so_far u64, _body_expected_size u64, _status_code int) ! {
	mut state := unsafe { exec_nil }
	pstate := unsafe { &voidptr(&state) }
	unsafe {
		*pstate = request.user_ptr
	}
	state.consume_chunk(chunk.bytestr())!
}

// ── Plan validation & execution ──

pub fn ExecState.http_method(method string) http.Method {
	return match method.to_upper() {
		'POST' { .post }
		'PUT' { .put }
		'PATCH' { .patch }
		'DELETE' { .delete }
		'HEAD' { .head }
		else { .get }
	}
}

pub fn ExecState.validate_plan(plan transport.WorkerUpstreamPlanFrame) ?string {
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

pub fn (mut state ExecState) execute_fixture(plan transport.WorkerUpstreamPlanFrame) ! {
	lines := os.read_lines(plan.fixture_path)!
	for line in lines {
		state.consume_chunk(line + '\n')!
	}
	state.flush_buffer()!
}

pub fn (mut state ExecState) execute_http(plan transport.WorkerUpstreamPlanFrame) ! {
	mut header := http.new_header()
	for name, value in plan.request_headers {
		header.add_custom(name, value) or {}
	}
	_ := http.fetch(
		url:                plan.url
		method:             ExecState.http_method(plan.method)
		header:             header
		data:               plan.body
		on_progress_body:   progress_body_cb
		user_ptr:           state
		stop_copying_limit: 65536
	) or {
		return err
	}
	state.flush_buffer()!
}
