module main

import api.openai
import veb

fn (mut app App) openai_handle_chat(mut ctx Context, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	if method.to_upper() !in ['POST', 'HEAD'] {
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, 405, path, method, req_id,
			trace_id, start_ms, 'method_not_allowed', 'method ${method} is not allowed for ${path}')
	}
	model := openai.OpenAIResolvedPlan.request_model(ctx.req.data)
	plan := app.openai_resolve_plan(model, ctx.req.data, method, path, req_id, trace_id) or {
		err_msg := err.msg()
		status := if err_msg.starts_with('openai_plugin_') { 502 } else { 400 }
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, status, path, method, req_id,
			trace_id, start_ms, openai.OpenAIResolvedPlan.plan_error_code(err_msg),
			openai.OpenAIResolvedPlan.plan_error_message(err_msg))
	}
	if openai.OpenAIResolvedPlan.is_stream_request(ctx.req.data) {
		if plan.backend.kind.trim_space() == 'executor' {
			return OpenAIProxyRuntime.executor_stream(mut app, mut ctx, plan, method, path, req_id,
				trace_id, start_ms)
		}
		if plan.stream_mode == 'mapped' {
			return OpenAIProxyRuntime.mapped_stream(mut app, mut ctx, plan, method, path, req_id,
				trace_id, start_ms)
		}
		return OpenAIProxyRuntime.stream(mut app, mut ctx, plan, method, path, req_id, trace_id,
			start_ms)
	}
	return OpenAIProxyRuntime.once(mut app, mut ctx, plan, method, path, req_id, trace_id, start_ms)
}
