module main

import veb

struct OpenaiProtocolIngressPort {}

fn (port OpenaiProtocolIngressPort) try_route_http(mut app App, mut ctx Context, req ProtocolHttpRequest) ?veb.Result {
	if !app.protocols.openai.enabled {
		return none
	}
	path_ctx := openai_path_context()
	relative := path_ctx.relative_path(req.target, app.protocols.openai.base_path) or {
		return none
	}
	relative_target := path_ctx.relative_target(req.target, app.protocols.openai.base_path) or {
		return none
	}
	if relative == '/models' {
		if !app.protocols.openai.endpoints.models {
			return OpenAIErrorResponseWriter.write(mut app, mut ctx, 404, req.target, req.method,
				req.request_id, req.trace_id, req.start_ms, 'endpoint_disabled',
				'OpenAI models endpoint is disabled')
		}
		return app.openai_handle_models(mut ctx, req.method, req.target, req.request_id,
			req.trace_id, req.start_ms)
	}
	if relative == '/chat/completions' {
		if !app.protocols.openai.endpoints.chat_completions {
			return OpenAIErrorResponseWriter.write(mut app, mut ctx, 404, req.target, req.method,
				req.request_id, req.trace_id, req.start_ms, 'endpoint_disabled',
				'OpenAI chat completions endpoint is disabled')
		}
		return app.openai_handle_chat(mut ctx, req.method, req.target, req.request_id,
			req.trace_id, req.start_ms)
	}
	if relative == '/responses' {
		if !app.protocols.openai.endpoints.responses {
			return OpenAIErrorResponseWriter.write(mut app, mut ctx, 404, req.target, req.method,
				req.request_id, req.trace_id, req.start_ms, 'endpoint_disabled',
				'OpenAI responses endpoint is disabled')
		}
		return app.openai_handle_responses(mut ctx, req.method, req.target, req.request_id,
			req.trace_id, req.start_ms)
	}
	if relative.starts_with('/responses/') {
		if !app.protocols.openai.endpoints.responses {
			return OpenAIErrorResponseWriter.write(mut app, mut ctx, 404, req.target, req.method,
				req.request_id, req.trace_id, req.start_ms, 'endpoint_disabled',
				'OpenAI responses endpoint is disabled')
		}
		return app.openai_handle_responses_passthrough(mut ctx, req.method, req.target,
			relative_target, req.request_id, req.trace_id, req.start_ms)
	}
	if relative == '/embeddings' {
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, 501, req.target, req.method,
			req.request_id, req.trace_id, req.start_ms, 'endpoint_not_implemented',
			'OpenAI endpoint ${relative} is not implemented yet')
	}
	return OpenAIErrorResponseWriter.write(mut app, mut ctx, 404, req.target, req.method,
		req.request_id, req.trace_id, req.start_ms, 'endpoint_not_found',
		'OpenAI endpoint ${relative} was not found')
}
