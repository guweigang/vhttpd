module main

import api.openai
import upstream.transport
import veb

fn (mut app App) openai_handle_responses(mut ctx Context, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	if method.to_upper() !in ['POST', 'HEAD'] {
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, 405, path, method, req_id,
			trace_id, start_ms, 'method_not_allowed', 'method ${method} is not allowed for ${path}')
	}
	model := openai.OpenAIResolvedPlan.request_model(ctx.req.data)
	plan := app.openai_resolve_responses_plan(model, ctx.req.data, method, path, req_id, trace_id) or {
		err_msg := err.msg()
		status := if err_msg.starts_with('openai_plugin_') { 502 } else { 400 }
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, status, path, method, req_id,
			trace_id, start_ms, openai.OpenAIResolvedPlan.plan_error_code(err_msg),
			openai.OpenAIResolvedPlan.plan_error_message(err_msg))
	}
	if openai.OpenAIResolvedPlan.is_stream_request(ctx.req.data) {
		if plan.backend.kind.trim_space() == 'executor' {
			return OpenAIProxyRuntime.responses_executor_stream(mut app, mut ctx, plan, method,
				path, req_id, trace_id, start_ms)
		}
		return OpenAIProxyRuntime.stream(mut app, mut ctx, plan, method, path, req_id, trace_id,
			start_ms)
	}
	if plan.backend.kind.trim_space() == 'executor' {
		return OpenAIProxyRuntime.responses_executor_once(mut app, mut ctx, plan, method, path,
			req_id, trace_id, start_ms)
	}
	return OpenAIProxyRuntime.once(mut app, mut ctx, plan, method, path, req_id, trace_id, start_ms)
}

fn (mut app App) openai_handle_responses_passthrough(mut ctx Context, method string, path string, relative_target string, req_id string, trace_id string, start_ms i64) veb.Result {
	if method.to_upper() !in ['GET', 'POST', 'DELETE', 'HEAD'] {
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, 405, path, method, req_id,
			trace_id, start_ms, 'method_not_allowed', 'method ${method} is not allowed for ${path}')
	}
	response_id := openai.OpenAIResponseRecord.id_from_relative(relative_target)
	relative_path :=
		transport.WorkerHttpRequestCodec.normalize_path(relative_target.all_before('?'))
	if method.to_upper() in ['GET', 'HEAD'] && response_id != ''
		&& !relative_path.contains('/input_items') {
		if record := app.protocols.openai.responses.get(response_id) {
			return OpenAIResponseWriter.write(mut app, mut ctx, 200, path, method, req_id,
				trace_id, start_ms, if method.to_upper() == 'HEAD' { '' } else { record.body },
				'application/json; charset=utf-8', {
				'x-vhttpd-openai-backend': record.backend_name
			}, {
				'backend':  record.backend_name
				'executor': record.executor
				'endpoint': 'responses.registry'
			})
		}
	}
	plan := app.openai_resolve_responses_passthrough_plan(relative_target, ctx.req.data, method) or {
		err_msg := err.msg()
		status := if err_msg.starts_with('openai_plugin_') { 502 } else { 400 }
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, status, path, method, req_id,
			trace_id, start_ms, openai.OpenAIResolvedPlan.plan_error_code(err_msg),
			openai.OpenAIResolvedPlan.plan_error_message(err_msg))
	}
	if plan.backend.kind.trim_space() == 'executor' {
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, 502, path, method, req_id,
			trace_id, start_ms, 'unsupported_backend',
			'Responses passthrough endpoint ${relative_target} requires an HTTP backend')
	}
	if openai.OpenAIResolvedPlan.is_stream_request(ctx.req.data)
		|| OpenAIRuntime.path_context().is_stream_target(path) {
		return OpenAIProxyRuntime.stream(mut app, mut ctx, plan, method, path, req_id, trace_id,
			start_ms)
	}
	return OpenAIProxyRuntime.once_attempt(mut app, mut ctx, plan, method, path, req_id, trace_id,
		start_ms, false)
}
