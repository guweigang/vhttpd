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
	done_probe       string
	final_written    bool
}

fn (mut state OpenAIStreamProxyState) finish() ! {
	if state.headers_written && !state.final_written {
		worker.WorkerHttpStreamWriter.write_final_chunk(mut state.conn)!
		state.final_written = true
	}
}

fn (mut state OpenAIStreamProxyState) has_done_chunk(decoded string) bool {
	if decoded == '' {
		return false
	}
	combined := state.done_probe + decoded
	if combined.contains('data: [DONE]') {
		state.done = true
		return true
	}
	state.done_probe = if combined.len > 64 { combined[combined.len - 64..] } else { combined }
	return false
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
	mut state := &OpenAIStreamProxyState(unsafe { nil })
	pstate := unsafe { &voidptr(&state) }
	unsafe {
		*pstate = request.user_ptr
	}
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
	state.ensure_headers_written()!
	if state.method.to_upper() != 'HEAD' && decoded.len > 0 {
		worker.WorkerHttpStreamWriter.write_chunk(mut state.conn, decoded)!
	}
	if state.has_done_chunk(decoded) {
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
	) or { return err.msg() }
	return ''
}

fn (mut state OpenAIStreamProxyState) reset_for_plan(plan openai.OpenAIResolvedPlan) {
	state.status_code = 200
	state.error_body = ''
	state.chunk_decoder = openai.ChunkDecodeState{}
	state.done = false
	state.done_probe = ''
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
	fetch_method := openai.OpenAIHttp.method(plan.method, method)
	mut fetch_err_msg := ''
	_ := http.fetch(
		url:                openai.OpenAIBackendAccess.upstream_url(plan.backend.base_url,
			plan.path)
		method:             fetch_method
		header:             OpenAIRequestHeaders.build(mut ctx, plan.backend, req_id, true,
			plan.headers)
		data:               plan.body
		on_progress_body:   openai_progress_body_cb
		user_ptr:           state
		stop_copying_limit: 65536
	) or {
		if err.msg() == openai_stream_done_fetch_error {
			fetch_err_msg = ''
		} else {
			fetch_err_msg = err.msg()
		}
		http.Response{}
	}
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
		client_conn.close() or {}
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
			client_conn.close() or {}
			return veb.no_result()
		}
		err_headers := {
			'x-request-id':         req_id
			'x-vhttpd-trace-id':    trace_id
			'x-vhttpd-error-class': 'openai_upstream_error'
		}
		OpenAIErrorResponseWriter.write_conn(mut client_conn, state.status_code, err_headers, code,
			message, typ)
		client_conn.close() or {}
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
