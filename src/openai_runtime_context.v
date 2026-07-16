module main

import api.openai
import time
import upstream.transport

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
