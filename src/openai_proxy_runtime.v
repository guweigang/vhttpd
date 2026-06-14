module main

import api.openai
import net.http
import time
import upstream.transport
import veb

struct OpenAIProxyRuntime {}

fn OpenAIProxyRuntime.once(mut app App, mut ctx Context, plan openai.OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	return OpenAIProxyRuntime.once_attempt(mut app, mut ctx, plan, method, path, req_id, trace_id,
		start_ms, true)
}

fn OpenAIProxyRuntime.once_attempt(mut app App, mut ctx Context, plan openai.OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64, allow_fallback bool) veb.Result {
	if plan.backend.kind.trim_space() == 'executor' {
		return OpenAIProxyRuntime.executor_once(mut app, mut ctx, plan, method, path, req_id,
			trace_id, start_ms)
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
	resp := http.fetch(
		url:    openai.OpenAIBackendAccess.upstream_url(plan.backend.base_url, plan.path)
		method: openai.OpenAIHttp.method(plan.method, method)
		header: OpenAIRequestHeaders.build(mut ctx, plan.backend, req_id, false, plan.headers)
		data:   plan.body
	) or {
		if allow_fallback {
			fallback := app.openai_plugin_fallback_plan(plan.model, plan.body, method, path, plan,
				502, 'upstream_fetch_failed', err.msg(), req_id, trace_id) or {
				openai.OpenAIPluginPlanResult{}
			}
			if fallback.handled {
				return OpenAIProxyRuntime.once_attempt(mut app, mut ctx, fallback.plan, method,
					path, req_id, trace_id, start_ms, false)
			}
		}
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, 502, path, method, req_id,
			trace_id, start_ms, 'upstream_fetch_failed', err.msg())
	}
	if resp.status_code >= 400 {
		code, message, typ := openai.OpenAIErrorParser.upstream_error_from_body(resp.body,
			'upstream_error', 'upstream returned HTTP ${resp.status_code}')
		if allow_fallback {
			fallback := app.openai_plugin_fallback_plan(plan.model, plan.body, method, path, plan,
				resp.status_code, code, message, req_id, trace_id) or {
				openai.OpenAIPluginPlanResult{}
			}
			if fallback.handled {
				return OpenAIProxyRuntime.once_attempt(mut app, mut ctx, fallback.plan, method,
					path, req_id, trace_id, start_ms, false)
			}
		}
		return OpenAIErrorResponseWriter.write_typed(mut app, mut ctx, resp.status_code, path,
			method, req_id, trace_id, start_ms, code, message, typ)
	}
	ctx.res.set_status(http.status_from_int(resp.status_code))
	ctx.set_content_type(if plan.stream_mode == 'mapped' {
		'application/json; charset=utf-8'
	} else {
		openai.OpenAIHttp.response_content_type(resp.header, 'application/json; charset=utf-8')
	})
	ctx.set_custom_header('x-request-id', req_id) or {}
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_custom_header('x-vhttpd-openai-backend', plan.backend_name) or {}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        transport.WorkerHttpRequestCodec.normalize_path(path)
		'status':      '${resp.status_code}'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'provider':    'openai'
		'backend':     plan.backend_name
	})
	if plan.stream_mode == 'mapped' {
		mapped_body := openai.OpenAIResponseBuilder.map_once_response(plan, resp.body, req_id,
			int(time.now().unix())) or {
			return OpenAIErrorResponseWriter.write(mut app, mut ctx, 502, path, method, req_id,
				trace_id, start_ms, openai.OpenAIResolvedPlan.plan_error_code(err.msg()),
				openai.OpenAIResolvedPlan.plan_error_message(err.msg()))
		}
		return ctx.text(if method.to_upper() == 'HEAD' { '' } else { mapped_body })
	}
	return ctx.text(if method.to_upper() == 'HEAD' { '' } else { resp.body })
}
