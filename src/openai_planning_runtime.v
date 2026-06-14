module main

import api.openai

fn (mut app App) openai_resolve_plan(model string, body string, method string, path string, req_id string, trace_id string) !openai.OpenAIResolvedPlan {
	if app.protocols.openai.plugin.trim_space() != '' {
		result := app.openai_plugin_plan(model, body, method, path, req_id, trace_id)!
		if result.handled {
			return result.plan
		}
	}
	route := app.openai_resolve_route(model)!
	return openai.OpenAIResolvedPlan.builtin_from_route(route, body)
}

fn (mut app App) openai_resolve_responses_plan(model string, body string, method string, path string, req_id string, trace_id string) !openai.OpenAIResolvedPlan {
	if app.protocols.openai.plugin.trim_space() != '' {
		result := app.openai_plugin_responses_plan(model, body, method, path, req_id, trace_id)!
		if result.handled {
			return result.plan
		}
	}
	route := app.openai_resolve_route(model)!
	return openai.OpenAIResolvedPlan.builtin_from_route_for_endpoint(route, body, '/responses',
		'openai.response')
}

fn (mut app App) openai_resolve_responses_passthrough_plan(relative_target string, body string, method string) !openai.OpenAIResolvedPlan {
	model := openai.OpenAIResolvedPlan.request_model(body)
	if model.trim_space() != '' {
		route := app.openai_resolve_route(model)!
		return openai.OpenAIResolvedPlan.builtin_from_route_for_endpoint_method(route, body,
			relative_target, 'openai.response', method)
	}
	backend_name := app.protocols.openai.default_backend.trim_space()
	if backend_name == '' {
		return error('openai_responses_passthrough_missing_default_backend')
	}
	backend := app.protocols.openai.backends[backend_name] or {
		return error('unknown backend ${backend_name}')
	}
	return openai.OpenAIResolvedPlan{
		backend_name:    backend_name
		backend:         backend
		method:          method.to_upper()
		path:            relative_target
		body:            body
		model:           model
		stream_mode:     'passthrough'
		response_codec:  'sse'
		output_protocol: 'openai.response'
		mapper:          'builtin'
		headers:         map[string]string{}
	}
}
