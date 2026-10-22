module main

import api.openai
import net
import net.http
import time
import upstream.transport
import veb
import worker

@[heap]
struct OpenAIStreamProxyState {
mut:
	conn             net.TcpConn
	method           string
	status_code      int
	content_type     string
	response_headers map[string]string
	headers_written  bool
	error_body       string
	chunk_decoder    openai.ChunkDecodeState
	done             bool
	terminal         OpenAIPassthroughTerminal
	final_written    bool
}

fn (mut state OpenAIStreamProxyState) finish() ! {
	if state.headers_written && !state.final_written {
		worker.WorkerHttpStreamWriter.write_final_chunk(mut state.conn)!
		state.final_written = true
	}
}

// Keep only enough of a line to recognize the exact data field. Large JSON
// events still pass through immediately without accumulating their bodies.
struct OpenAIPassthroughTerminal {
mut:
	line_prefix string
	first_line  bool = true
	data_lines  u8
	done_data   bool
	skip_lf     bool
}

fn (mut terminal OpenAIPassthroughTerminal) end_line() bool {
	line := if terminal.first_line && terminal.line_prefix.starts_with('\xef\xbb\xbf') {
		terminal.line_prefix[3..]
	} else {
		terminal.line_prefix
	}
	terminal.first_line = false
	terminal.line_prefix = ''
	if line == '' {
		done := terminal.data_lines == 1 && terminal.done_data
		terminal.data_lines = 0
		terminal.done_data = false
		return done
	}
	if line == 'data' || line.starts_with('data:') {
		if terminal.data_lines < 2 { terminal.data_lines++ }
		terminal.done_data = terminal.data_lines == 1 && line in ['data:[DONE]', 'data: [DONE]']
	}
	return false
}

// Claim completion before publishing bytes, and return only the prefix owned by
// this response. A network callback can contain multiple SSE records.
fn (mut state OpenAIStreamProxyState) terminal_prefix(decoded string) int {
	for i, byte in decoded.bytes() {
		if state.terminal.skip_lf {
			state.terminal.skip_lf = false
			if byte == `\n` { continue }
		}
		if byte == `\r` || byte == `\n` {
			state.terminal.skip_lf = byte == `\r`
			if state.terminal.end_line() {
				state.done = true
				if byte == `\r` && i + 1 < decoded.len && decoded[i + 1] == `\n` { return i + 2 }
				return i + 1
			}
		} else if state.terminal.line_prefix.len < 16 {
			state.terminal.line_prefix += byte.ascii_str()
		}
	}
	return decoded.len
}

fn (mut state OpenAIStreamProxyState) ensure_headers_written() ! {
	if state.headers_written {
		return
	}
	mut headers := state.response_headers.clone()
	headers['x-accel-buffering'] = 'no'
	worker.WorkerHttpStreamWriter.write_headers_conn_with_close(mut state.conn, state.status_code,
		state.content_type, headers, true, false)!
	state.headers_written = true
}

// C callback trampoline for `http.fetch(on_progress_body)`.
// Keep as a free function: static-method callbacks can pass syntax checks and
// fail later during C generation, as seen with websocket callback symbols.
fn openai_progress_body_cb(request &http.Request, chunk []u8, _body_read_so_far u64, _body_expected_size u64, status_code int) ! {
	mut state := unsafe { &OpenAIStreamProxyState(request.user_ptr) }
	if state.done { return error(openai_stream_done_fetch_error) }
	if status_code > 0 {
		state.status_code = status_code
	}
	decoded := state.chunk_decoder.decode(chunk)
	if state.status_code >= 400 {
		if decoded.len > 0 {
			state.error_body += decoded
		}
		return
	}
	// An empty progress call can precede validation of the upstream status line.
	// Commit headers with payload, or after fetch has completed successfully.
	if decoded.len == 0 { return }
	prefix := state.terminal_prefix(decoded)
	state.ensure_headers_written()!
	if state.method.to_upper() != 'HEAD' && prefix > 0 {
		worker.WorkerHttpStreamWriter.write_chunk(mut state.conn, decoded[..prefix])!
	}
	if state.done {
		state.finish()!
		return error(openai_stream_done_fetch_error)
	}
}

fn (mut state OpenAIStreamProxyState) fetch(mut ctx Context, plan openai.OpenAIResolvedPlan, method string, req_id string) string {
	_ := http.fetch(
		url:                openai.OpenAIBackendAccess.upstream_url(plan.backend.base_url,
			plan.path)
		method:             openai.OpenAIHttp.method(plan.method, method)
		header:             OpenAIRequestHeaders.build(mut ctx, plan.backend, req_id, true,
			plan.headers)
		data:               plan.body
		on_progress_body:   openai_progress_body_cb
		user_ptr:           state
		stop_copying_limit: 65536
	) or {
		if state.done && err.msg() == openai_stream_done_fetch_error { return '' }
		return err.msg()
	}
	// Short plain error bodies can remain undecided by auto-detection until EOF.
	if state.status_code >= 400 && state.chunk_decoder.mode == 'unknown' {
		state.error_body += state.chunk_decoder.buffer
		state.chunk_decoder.buffer = ''
	}
	return ''
}

fn (mut state OpenAIStreamProxyState) reset_for_plan(plan openai.OpenAIResolvedPlan) {
	state.status_code = 200
	state.error_body = ''
	state.chunk_decoder = openai.ChunkDecodeState{}
	state.done = false
	state.terminal = OpenAIPassthroughTerminal{}
	state.final_written = false
	state.response_headers['x-vhttpd-openai-backend'] = plan.backend_name
}

fn OpenAIProxyRuntime.stream(mut app App, mut ctx Context, plan openai.OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	if plan.backend.kind.trim_space() !in ['', 'openai_http'] {
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, 502, path, method, req_id,
			trace_id, start_ms, 'unsupported_backend',
			'unsupported OpenAI backend kind ${plan.backend.kind}')
	}
	if plan.backend.base_url.trim_space() == '' {
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, 502, path, method, req_id,
			trace_id, start_ms, 'missing_backend_base_url',
			'OpenAI backend ${plan.backend_name} has no base_url')
	}
	// veb retains socket ownership in reusable mode, including failure paths.
	ctx.takeover_conn_reusable()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut client_conn := ctx.conn
	mut headers := map[string]string{}
	headers['x-request-id'] = req_id
	headers['x-vhttpd-trace-id'] = trace_id
	headers['x-vhttpd-openai-backend'] = plan.backend_name
	mut state := &OpenAIStreamProxyState{
		conn:             client_conn
		method:           method
		status_code:      200
		content_type:     'text/event-stream'
		response_headers: headers
	}
	mut fetch_err_msg := state.fetch(mut ctx, plan, method, req_id)
	if fetch_err_msg != '' && !state.headers_written {
		fallback := app.openai_plugin_fallback_plan(plan.model, plan.body, method, path, plan, 502,
			'upstream_fetch_failed', fetch_err_msg, req_id, trace_id) or {
			openai.OpenAIPluginPlanResult{}
		}
		if fallback.handled && fallback.plan.stream_mode == 'passthrough' {
			state.reset_for_plan(fallback.plan)
			fallback_err_msg := state.fetch(mut ctx, fallback.plan, method, req_id)
			if fallback_err_msg == '' {
				fetch_err_msg = ''
			} else {
				fetch_err_msg = fallback_err_msg
			}
		}
	}
	if fetch_err_msg != '' && !state.headers_written {
		err_headers := {
			'x-request-id':         req_id
			'x-vhttpd-trace-id':    trace_id
			'x-vhttpd-error-class': 'openai_upstream_fetch_failed'
		}
		OpenAIErrorResponseWriter.write_conn(mut client_conn, 502, err_headers,
			'upstream_fetch_failed', fetch_err_msg, 'server_error')
		ctx.set_header(.connection, 'close')
		return veb.no_result()
	}
	if state.status_code >= 400 && !state.headers_written {
		code, message, typ := openai.OpenAIErrorParser.upstream_error_from_body(state.error_body,
			'upstream_error', 'upstream returned HTTP ${state.status_code}')
		fallback := app.openai_plugin_fallback_plan(plan.model, plan.body, method, path, plan,
			state.status_code, code, message, req_id, trace_id) or {
			openai.OpenAIPluginPlanResult{}
		}
		if fallback.handled && fallback.plan.stream_mode == 'passthrough' {
			state.reset_for_plan(fallback.plan)
			fallback_err_msg := state.fetch(mut ctx, fallback.plan, method, req_id)
			if fallback_err_msg != '' {
				if state.headers_written {
					state.finish() or {}
				} else {
					err_headers := {
						'x-request-id':         req_id
						'x-vhttpd-trace-id':    trace_id
						'x-vhttpd-error-class': 'openai_upstream_fetch_failed'
					}
					OpenAIErrorResponseWriter.write_conn(mut client_conn, 502, err_headers,
						'upstream_fetch_failed', fallback_err_msg, 'server_error')
				}
				ctx.set_header(.connection, 'close')
				return veb.no_result()
			}
			if fallback_err_msg == '' && state.status_code < 400 {
				if !state.headers_written {
					state.ensure_headers_written() or {}
				}
				if state.headers_written {
					state.finish() or {}
				}
				return veb.no_result()
			}
		}
		if state.status_code >= 400 {
			code2, message2, typ2 := openai.OpenAIErrorParser.upstream_error_from_body(state.error_body,
				'upstream_error', 'upstream returned HTTP ${state.status_code}')
			err_headers := {
				'x-request-id':         req_id
				'x-vhttpd-trace-id':    trace_id
				'x-vhttpd-error-class': 'openai_upstream_error'
			}
			OpenAIErrorResponseWriter.write_conn(mut client_conn, state.status_code, err_headers,
				code2, message2, typ2)
			ctx.set_header(.connection, 'close')
			return veb.no_result()
		}
		err_headers := {
			'x-request-id':         req_id
			'x-vhttpd-trace-id':    trace_id
			'x-vhttpd-error-class': 'openai_upstream_error'
		}
		OpenAIErrorResponseWriter.write_conn(mut client_conn, state.status_code, err_headers, code,
			message, typ)
		ctx.set_header(.connection, 'close')
		return veb.no_result()
	}
	if !state.headers_written {
		state.ensure_headers_written() or {}
	}
	if state.headers_written {
		state.finish() or {}
	}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        transport.WorkerHttpRequestCodec.normalize_path(path)
		'status':      '${state.status_code}'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'provider':    'openai'
		'backend':     plan.backend_name
	})
	return veb.no_result()
}
