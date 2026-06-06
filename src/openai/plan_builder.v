module openai

import config

import x.json2

// ── OpenAIResolvedRoute Static Methods ──

// route_models extracts the list of model names from a route config.
pub fn OpenAIResolvedRoute.models(route config.OpenAIRouteConfig, route_name string) []string {
	mut models := []string{}
	for raw in route.models {
		model := raw.trim_space()
		if model != '' && model !in models {
			models << model
		}
	}
	if route.model.trim_space() != '' && route.model !in models {
		models << route.model.trim_space()
	}
	if models.len == 0 && route_name.trim_space() != '' {
		models << route_name.trim_space()
	}
	return models
}

// ── OpenAIResolvedPlan Static Methods ──

// hex_chunk_size parses a hex chunk size from a raw string, used for transfer-encoding: chunked.
pub fn OpenAIResolvedPlan.hex_chunk_size(raw string) ?int {
	hex_part := raw.all_before(';').trim_space()
	if hex_part == '' {
		return none
	}
	mut size := 0
	for ch in hex_part {
		mut value := -1
		if ch >= `0` && ch <= `9` {
			value = int(ch - `0`)
		} else if ch >= `a` && ch <= `f` {
			value = 10 + int(ch - `a`)
		} else if ch >= `A` && ch <= `F` {
			value = 10 + int(ch - `A`)
		} else {
			return none
		}
		size = (size * 16) + value
	}
	return size
}

// is_stream_request checks whether a JSON request body has stream=true.
pub fn OpenAIResolvedPlan.is_stream_request(body string) bool {
	parsed := json2.decode[json2.Any](body) or { return false }
	root := parsed.as_map()
	stream_any := root['stream'] or { return false }
	return stream_any.bool()
}

// request_model extracts the model name from a JSON request body.
pub fn OpenAIResolvedPlan.request_model(body string) string {
	parsed := json2.decode[json2.Any](body) or { return '' }
	root := parsed.as_map()
	return (root['model'] or { json2.Any('') }).str()
}

// replace_model replaces the model field in a JSON request body.
pub fn OpenAIResolvedPlan.replace_model(body string, upstream_model string) string {
	if upstream_model.trim_space() == '' {
		return body
	}
	parsed := json2.decode[json2.Any](body) or { return body }
	mut root := parsed.as_map()
	root['model'] = json2.Any(upstream_model)
	return json2.Any(root).json_str()
}

// ── Plan Error Helpers ──

// plan_error creates a structured plan error.
pub fn OpenAIResolvedPlan.plan_error(code string, message string) IError {
	return error('${code}:${message}')
}

// plan_error_code extracts the error code from a plan error message.
pub fn OpenAIResolvedPlan.plan_error_code(err_msg string) string {
	if err_msg.starts_with('openai_plugin_plan_') && err_msg.contains(':') {
		return err_msg.all_before(':')
	}
	if err_msg.starts_with('openai_plugin_') && err_msg.contains(':') {
		return err_msg.all_before(':')
	}
	if err_msg.starts_with('unknown backend ') {
		return 'openai_plugin_plan_unknown_backend'
	}
	return 'model_not_found'
}

// plan_error_message extracts the human-readable message from a plan error.
pub fn OpenAIResolvedPlan.plan_error_message(err_msg string) string {
	if (err_msg.starts_with('openai_plugin_plan_') || err_msg.starts_with('openai_plugin_'))
		&& err_msg.contains(':') {
		return err_msg.all_after(':')
	}
	return err_msg
}

// ── Plan Validation ──

pub fn OpenAIResolvedPlan.validate_method(raw string) !string {
	method := raw.trim_space().to_upper()
	if method == '' {
		return 'POST'
	}
	if method in ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'] {
		return method
	}
	return OpenAIResolvedPlan.plan_error('openai_plugin_plan_invalid_method',
		'unsupported upstream method ${method}')
}

pub fn OpenAIResolvedPlan.validate_path(raw string) !string {
	path := raw.trim_space()
	if path == '' {
		return '/chat/completions'
	}
	if !path.starts_with('/') {
		return OpenAIResolvedPlan.plan_error('openai_plugin_plan_invalid_path',
			'upstream path must start with /')
	}
	if path.contains('\r') || path.contains('\n') {
		return OpenAIResolvedPlan.plan_error('openai_plugin_plan_invalid_path',
			'upstream path must not contain newlines')
	}
	return path
}

pub fn OpenAIResolvedPlan.validate_stream_mode(raw string) !string {
	mode := raw.trim_space()
	if mode == '' {
		return 'passthrough'
	}
	if mode in ['passthrough', 'mapped', 'executor'] {
		return mode
	}
	return OpenAIResolvedPlan.plan_error('openai_plugin_plan_unsupported_stream_mode',
		'unsupported stream_mode ${mode}')
}

pub fn OpenAIResolvedPlan.validate_response_codec(raw string, stream_mode string) !string {
	codec := raw.trim_space()
	if codec == '' {
		return if stream_mode == 'mapped' { 'ndjson' } else { 'sse' }
	}
	if codec in ['sse', 'json', 'ndjson', 'text'] {
		return codec
	}
	return OpenAIResolvedPlan.plan_error('openai_plugin_plan_unsupported_response_codec',
		'unsupported response_codec ${codec}')
}

pub fn OpenAIResolvedPlan.validate_output_protocol(raw string, stream_mode string) !string {
	protocol := raw.trim_space()
	if protocol == '' {
		return 'openai.chat.completion'
	}
	if stream_mode == 'mapped' && protocol != 'openai.chat.completion' {
		return OpenAIResolvedPlan.plan_error('openai_plugin_plan_unsupported_output_protocol',
			'unsupported output_protocol ${protocol}')
	}
	return protocol
}

pub fn OpenAIResolvedPlan.validate_mapper(raw string) !string {
	mapper := raw.trim_space()
	if mapper == '' {
		return 'builtin'
	}
	if mapper in ['builtin', 'plugin'] {
		return mapper
	}
	return OpenAIResolvedPlan.plan_error('openai_plugin_plan_unsupported_mapper',
		'unsupported mapper ${mapper}')
}

pub fn OpenAIResolvedPlan.sanitize_headers(headers map[string]string) map[string]string {
	mut out := map[string]string{}
	for name, value in headers {
		lower := name.trim_space().to_lower()
		if lower == ''
			|| lower in ['connection', 'content-length', 'transfer-encoding', 'host', 'server', 'upgrade', 'proxy-connection', 'keep-alive', 'te', 'trailer'] {
			continue
		}
		if lower.contains('\r') || lower.contains('\n') || value.contains('\r')
			|| value.contains('\n') {
			continue
		}
		out[name] = value
	}
	return out
}

// ── Plan Construction ──

// builtin_plan_from_route builds a resolved plan for the standard /chat/completions endpoint.
pub fn OpenAIResolvedPlan.builtin_from_route(route OpenAIResolvedRoute, body string) OpenAIResolvedPlan {
	return OpenAIResolvedPlan.builtin_from_route_for_endpoint(route, body, '/chat/completions',
		'openai.chat.completion')
}

// builtin_plan_from_route_for_endpoint builds a resolved plan for a given upstream endpoint.
pub fn OpenAIResolvedPlan.builtin_from_route_for_endpoint(route OpenAIResolvedRoute, body string, upstream_path string, output_protocol string) OpenAIResolvedPlan {
	return OpenAIResolvedPlan.builtin_from_route_for_endpoint_method(route, body, upstream_path,
		output_protocol, 'POST')
}

// builtin_plan_from_route_for_endpoint_method builds a resolved plan with a specific HTTP method.
pub fn OpenAIResolvedPlan.builtin_from_route_for_endpoint_method(route OpenAIResolvedRoute, body string, upstream_path string, output_protocol string, method string) OpenAIResolvedPlan {
	return OpenAIResolvedPlan{
		backend_name:    route.backend_name
		backend:         route.backend
		method:          method.to_upper()
		path:            upstream_path
		body:            OpenAIResolvedPlan.replace_model(body, route.upstream_model)
		model:           route.model
		stream_mode:     'passthrough'
		response_codec:  'sse'
		output_protocol: output_protocol
		mapper:          'builtin'
		headers:         map[string]string{}
	}
}

// ── OpenAIUpstreamPlan Static Methods ──

// from_plugin_json parses an upstream plan from JSON with fallback defaults.
pub fn OpenAIUpstreamPlan.from_plugin_json(raw string, default_path string, default_output_protocol string) !OpenAIUpstreamPlan {
	parsed := json2.decode[json2.Any](raw)!
	mut root := parsed.as_map()
	if plan_any := root['plan'] {
		root = plan_any.as_map()
	}
	body := if body_any := root['body'] { body_any.str() } else { '' }
	return OpenAIUpstreamPlan{
		backend:         json_string_field(root, 'backend', '')
		method:          json_string_field(root, 'method', 'POST')
		path:            json_string_field(root, 'path', default_path)
		body:            body
		upstream_model:  json_string_field(root, 'upstream_model', '')
		stream_mode:     json_string_field(root, 'stream_mode', 'passthrough')
		response_codec:  json_string_field(root, 'response_codec', '')
		output_protocol: json_string_field(root, 'output_protocol', default_output_protocol)
		mapper:          json_string_field(root, 'mapper', '')
		headers:         json_string_map_field(root, 'headers')
	}
}

// ── OpenAIPluginModelsResult Static Methods ──

// from_json extracts model names from a plugin JSON response.
pub fn OpenAIPluginModelsResult.models_from_json(raw string) ![]string {
	parsed := json2.decode[json2.Any](raw)!
	root := parsed.as_map()
	mut models := []string{}
	if models_any := root['models'] {
		for item in models_any.as_array() {
			model := item.str().trim_space()
			if model != '' && model !in models {
				models << model
			}
		}
	}
	if data_any := root['data'] {
		for item in data_any.as_array() {
			row := item.as_map()
			model := (row['id'] or { json2.Any('') }).str().trim_space()
			if model != '' && model !in models {
				models << model
			}
		}
	}
	return models
}

// ── OpenAIPluginPlanResult Static Methods ──

// not_handled checks whether a plugin response indicates the plugin did not handle the request.
pub fn OpenAIPluginPlanResult.not_handled(raw string) bool {
	parsed := json2.decode[json2.Any](raw) or { return false }
	root := parsed.as_map()
	for key in ['not_handled', 'notHandled'] {
		value := root[key] or { continue }
		if value.bool() {
			return true
		}
	}
	return false
}
