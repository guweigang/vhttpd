module main

import api.openai
import time
import upstream.transport
import veb

const openai_response_registry_ttl = 24 * time.hour
const openai_stream_done_fetch_error = 'openai_stream_done'

struct OpenAIRuntime {}

// openai_path_context builds a PathContext that wraps module-main path helpers.
fn openai_path_context() openai.PathContext {
	return openai.PathContext{
		normalize_path:           transport.WorkerHttpRequestCodec.normalize_path
		normalize_request_target: transport.WorkerHttpRequestCodec.normalize_request_target
		parse_query_map:          transport.WorkerHttpRequestCodec.parse_query_map
	}
}

fn OpenAIRuntime.path_context() openai.PathContext {
	return openai_path_context()
}

fn (mut app App) openai_try_handle(mut ctx Context, method string, target string, req_id string, trace_id string, start_ms i64) ?veb.Result {
	if !app.protocols.openai.enabled {
		return none
	}
	path_ctx := openai_path_context()
	relative := path_ctx.relative_path(target, app.protocols.openai.base_path) or { return none }
	relative_target := path_ctx.relative_target(target, app.protocols.openai.base_path) or { return none }
	if relative == '/models' {
		if !app.protocols.openai.endpoints.models {
			return OpenAIErrorResponseWriter.write(mut app, mut ctx, 404, target, method, req_id,
				trace_id, start_ms, 'endpoint_disabled', 'OpenAI models endpoint is disabled')
		}
		return app.openai_handle_models(mut ctx, method, target, req_id, trace_id, start_ms)
	}
	if relative == '/chat/completions' {
		if !app.protocols.openai.endpoints.chat_completions {
			return OpenAIErrorResponseWriter.write(mut app, mut ctx, 404, target, method, req_id,
				trace_id, start_ms, 'endpoint_disabled',
				'OpenAI chat completions endpoint is disabled')
		}
		return app.openai_handle_chat(mut ctx, method, target, req_id, trace_id, start_ms)
	}
	if relative == '/responses' {
		if !app.protocols.openai.endpoints.responses {
			return OpenAIErrorResponseWriter.write(mut app, mut ctx, 404, target, method, req_id,
				trace_id, start_ms, 'endpoint_disabled', 'OpenAI responses endpoint is disabled')
		}
		return app.openai_handle_responses(mut ctx, method, target, req_id, trace_id, start_ms)
	}
	if relative.starts_with('/responses/') {
		if !app.protocols.openai.endpoints.responses {
			return OpenAIErrorResponseWriter.write(mut app, mut ctx, 404, target, method, req_id,
				trace_id, start_ms, 'endpoint_disabled', 'OpenAI responses endpoint is disabled')
		}
		return app.openai_handle_responses_passthrough(mut ctx, method, target, relative_target,
			req_id, trace_id, start_ms)
	}
	if relative == '/embeddings' {
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, 501, target, method, req_id,
			trace_id, start_ms, 'endpoint_not_implemented',
			'OpenAI endpoint ${relative} is not implemented yet')
	}
	return OpenAIErrorResponseWriter.write(mut app, mut ctx, 404, target, method, req_id,
		trace_id, start_ms, 'endpoint_not_found', 'OpenAI endpoint ${relative} was not found')
}
