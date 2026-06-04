module openai

import config

import x.json2

// route_models extracts the list of model names from a route config.
pub fn route_models(route config.OpenAIRouteConfig, route_name string) []string {
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

// builtin_plan_from_route builds a resolved plan for the standard /chat/completions endpoint.
pub fn builtin_plan_from_route(route OpenAIResolvedRoute, body string) OpenAIResolvedPlan {
	return builtin_plan_from_route_for_endpoint(route, body, '/chat/completions',
		'openai.chat.completion')
}

// builtin_plan_from_route_for_endpoint builds a resolved plan for a given upstream endpoint.
pub fn builtin_plan_from_route_for_endpoint(route OpenAIResolvedRoute, body string, upstream_path string, output_protocol string) OpenAIResolvedPlan {
	return builtin_plan_from_route_for_endpoint_method(route, body, upstream_path,
		output_protocol, 'POST')
}

// builtin_plan_from_route_for_endpoint_method builds a resolved plan with a specific HTTP method.
pub fn builtin_plan_from_route_for_endpoint_method(route OpenAIResolvedRoute, body string, upstream_path string, output_protocol string, method string) OpenAIResolvedPlan {
	return OpenAIResolvedPlan{
		backend_name:    route.backend_name
		backend:         route.backend
		method:          method.to_upper()
		path:            upstream_path
		body:            replace_model_in_body(body, route.upstream_model)
		model:           route.model
		stream_mode:     'passthrough'
		response_codec:  'sse'
		output_protocol: output_protocol
		mapper:          'builtin'
		headers:         map[string]string{}
	}
}

// upstream_plan_from_plugin_json_with_defaults parses an upstream plan from JSON with fallback defaults.
pub fn upstream_plan_from_plugin_json_with_defaults(raw string, default_path string, default_output_protocol string) !OpenAIUpstreamPlan {
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

// models_from_plugin_json extracts model names from a plugin JSON response.
pub fn models_from_plugin_json(raw string) ![]string {
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
