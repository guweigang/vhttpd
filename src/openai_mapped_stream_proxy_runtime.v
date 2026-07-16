module main

import api.openai
import net.http
import time
import upstream.transport
import veb
import worker

// C callback trampoline for `http.fetch(on_progress_body)`.
// Keep as a free function: static-method callbacks can pass syntax checks and
// fail later during C generation, as seen with websocket callback symbols.
fn openai_mapped_progress_body_cb(request &http.Request, chunk []u8, _body_read_so_far u64, _body_expected_size u64, status_code int) ! {
	mut state := &OpenAIMappedStreamProxyState(unsafe { nil })
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
	if state.method.to_upper() == 'HEAD' || decoded.len == 0 {
		return
	}
	state.line_buffer += decoded
	for state.line_buffer.contains('\n') {
		line := state.line_buffer.all_before('\n')
		state.line_buffer = state.line_buffer.all_after('\n')
		state.write_mapped_line(line)!
	}
	if state.done {
		return error(openai_stream_done_fetch_error)
	}
}

fn (mut state OpenAIMappedStreamProxyState) fetch(mut ctx Context, plan openai.OpenAIResolvedPlan, method string, req_id string) string {
	_ := http.fetch(
		url:                openai.OpenAIBackendAccess.upstream_url(plan.backend.base_url,
			plan.path)
		method:             openai.OpenAIHttp.method(plan.method, method)
		header:             OpenAIRequestHeaders.build(mut ctx, plan.backend, req_id, true,
			plan.headers)
		data:               plan.body
		on_progress_body:   openai_mapped_progress_body_cb
		user_ptr:           state
		stop_copying_limit: 65536
	) or {
		if err.msg() == openai_stream_done_fetch_error {
			return ''
		}
		return err.msg()
	}
	return ''
}

fn OpenAIProxyRuntime.mapped_stream(mut app App, mut ctx Context, plan openai.OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	if plan.response_codec != 'ndjson' || plan.output_protocol != 'openai.chat.completion' {
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, 502, path, method, req_id,
			trace_id, start_ms, 'openai_plugin_plan_unsupported_mapper',
			'unsupported mapper ${plan.response_codec} -> ${plan.output_protocol}')
	}
	if plan.backend.kind.trim_space() !in ['', 'openai_http', 'http'] {
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
	mut state := &OpenAIMappedStreamProxyState{
		app:              unsafe { &app }
		conn:             client_conn
		method:           method
		status_code:      200
		response_headers: headers
		model:            plan.model
		request_id:       req_id
		trace_id:         trace_id
		mapper:           plan.mapper
		response_codec:   plan.response_codec
		output_protocol:  plan.output_protocol
		created:          int(time.now().unix())
	}
	mut fetch_err_msg := state.fetch(mut ctx, plan, method, req_id)
	if fetch_err_msg != '' && !state.headers_written {
		fallback := app.openai_plugin_fallback_plan(plan.model, plan.body, method, path, plan, 502,
			'upstream_fetch_failed', fetch_err_msg, req_id, trace_id) or {
			openai.OpenAIPluginPlanResult{}
		}
		if fallback.handled && fallback.plan.stream_mode == 'mapped' {
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
		code, message, _ := openai.OpenAIErrorParser.upstream_error_from_body(state.error_body,
			'upstream_error', 'upstream returned HTTP ${state.status_code}')
		fallback := app.openai_plugin_fallback_plan(plan.model, plan.body, method, path, plan,
			state.status_code, code, message, req_id, trace_id) or {
			openai.OpenAIPluginPlanResult{}
		}
		if fallback.handled && fallback.plan.stream_mode == 'mapped' {
			state.reset_for_plan(fallback.plan)
			fallback_err_msg := state.fetch(mut ctx, fallback.plan, method, req_id)
			if fallback_err_msg != '' && !state.headers_written {
				err_headers := {
					'x-request-id':         req_id
					'x-vhttpd-trace-id':    trace_id
					'x-vhttpd-error-class': 'openai_upstream_fetch_failed'
				}
				OpenAIErrorResponseWriter.write_conn(mut client_conn, 502, err_headers,
					'upstream_fetch_failed', fallback_err_msg, 'server_error')
				client_conn.close() or {}
				return veb.no_result()
			}
		}
	}
	if state.status_code >= 400 && !state.headers_written {
		code, message, typ := openai.OpenAIErrorParser.upstream_error_from_body(state.error_body,
			'upstream_error', 'upstream returned HTTP ${state.status_code}')
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
	if state.line_buffer.trim_space() != '' {
		state.write_mapped_line(state.line_buffer) or {}
		state.line_buffer = ''
	}
	if state.mapper_error != '' && !state.final_written {
		state.ensure_headers_written() or {}
		OpenAIErrorResponseWriter.write_sse(mut client_conn, 'mapper_error', state.mapper_error,
			'server_error')
		state.done = true
		state.finish() or {}
	}
	if !state.done {
		state.ensure_headers_written() or {}
		state.write_usage_chunk() or {}
		worker.WorkerHttpStreamWriter.write_chunk(mut client_conn, 'data: [DONE]\n\n') or {}
		state.done = true
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
		'mapper':      '${plan.response_codec}->${plan.output_protocol}'
	})
	return veb.no_result()
}
