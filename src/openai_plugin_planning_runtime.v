module main

import api.openai
import json

fn (mut app App) openai_call_plugin(op string, payload string, req_id string, trace_id string, metadata map[string]string) !PluginCallResponse {
	plugin_name := app.protocols.openai.plugin.trim_space()
	if plugin_name == '' {
		return error('openai_plugin_not_configured')
	}
	return app.call_plugin(PluginCallRequest{
		plugin:     plugin_name
		capability: 'openai'
		op:         op
		request_id: req_id
		trace_id:   trace_id
		payload:    payload
		metadata:   metadata
	})
}

fn (mut app App) openai_plugin_models(method string, path string, req_id string, trace_id string) !openai.OpenAIPluginModelsResult {
	resp := app.openai_call_plugin('models', json.encode(openai.OpenAIPluginModelsPayload{
		method:     method.to_upper()
		path:       path
		base_path:  app.protocols.openai.base_path
		request_id: req_id
		trace_id:   trace_id
	}), req_id, trace_id, map[string]string{})!
	if openai.OpenAIPluginPlanResult.not_handled(resp.result) {
		return openai.OpenAIPluginModelsResult{}
	}
	return openai.OpenAIPluginModelsResult{
		handled: true
		models:  openai.OpenAIPluginModelsResult.models_from_json(resp.result)!
	}
}

fn (mut app App) openai_resolved_plan_from_plugin_result_with_defaults(model string, body string, raw string, default_path string, default_output_protocol string) !openai.OpenAIResolvedPlan {
	plan := openai.OpenAIUpstreamPlan.from_plugin_json(raw, default_path, default_output_protocol)!
	backend_name := plan.backend.trim_space()
	if backend_name == '' {
		return openai.OpenAIResolvedPlan.plan_error('openai_plugin_plan_missing_backend',
			'plugin plan must include backend')
	}
	backend := app.protocols.openai.backends[backend_name] or {
		return openai.OpenAIResolvedPlan.plan_error('openai_plugin_plan_unknown_backend',
			'unknown backend ${backend_name}')
	}
	plan_method := openai.OpenAIResolvedPlan.validate_method(plan.method)!
	plan_path := openai.OpenAIResolvedPlan.validate_path(plan.path)!
	stream_mode := openai.OpenAIResolvedPlan.validate_stream_mode(plan.stream_mode)!
	response_codec := openai.OpenAIResolvedPlan.validate_response_codec(plan.response_codec,
		stream_mode)!
	output_protocol := openai.OpenAIResolvedPlan.validate_output_protocol(plan.output_protocol,
		stream_mode)!
	mapper := openai.OpenAIResolvedPlan.validate_mapper(plan.mapper)!
	plan_headers := openai.OpenAIResolvedPlan.sanitize_headers(plan.headers)
	plan_body := if plan.body.trim_space() != '' {
		plan.body
	} else {
		openai.OpenAIResolvedPlan.replace_model(body, plan.upstream_model)
	}
	return openai.OpenAIResolvedPlan{
		backend_name:    backend_name
		backend:         backend
		method:          plan_method
		path:            plan_path
		body:            plan_body
		model:           model
		stream_mode:     stream_mode
		response_codec:  response_codec
		output_protocol: output_protocol
		mapper:          mapper
		headers:         plan_headers
	}
}

fn (mut app App) openai_resolved_plan_from_plugin_result(model string, body string, raw string) !openai.OpenAIResolvedPlan {
	return app.openai_resolved_plan_from_plugin_result_with_defaults(model, body, raw,
		'/chat/completions', 'openai.chat.completion')
}

fn (mut app App) openai_plugin_plan(model string, body string, method string, path string, req_id string, trace_id string) !openai.OpenAIPluginPlanResult {
	resp := app.openai_call_plugin('chat.route', json.encode(openai.OpenAIPluginChatPayload{
		method:     method.to_upper()
		path:       path
		model:      model
		stream:     openai.OpenAIResolvedPlan.is_stream_request(body)
		body:       body
		base_path:  app.protocols.openai.base_path
		request_id: req_id
		trace_id:   trace_id
	}), req_id, trace_id, {
		'model': model
	})!
	if openai.OpenAIPluginPlanResult.not_handled(resp.result) {
		return openai.OpenAIPluginPlanResult{}
	}
	return openai.OpenAIPluginPlanResult{
		handled: true
		plan:    app.openai_resolved_plan_from_plugin_result(model, body, resp.result)!
	}
}

fn (mut app App) openai_plugin_responses_plan(model string, body string, method string, path string, req_id string, trace_id string) !openai.OpenAIPluginPlanResult {
	resp := app.openai_call_plugin('responses.route', json.encode(openai.OpenAIPluginResponsesPayload{
		method:     method.to_upper()
		path:       path
		model:      model
		stream:     openai.OpenAIResolvedPlan.is_stream_request(body)
		body:       body
		base_path:  app.protocols.openai.base_path
		request_id: req_id
		trace_id:   trace_id
	}), req_id, trace_id, {
		'model': model
	})!
	if openai.OpenAIPluginPlanResult.not_handled(resp.result) {
		return openai.OpenAIPluginPlanResult{}
	}
	return openai.OpenAIPluginPlanResult{
		handled: true
		plan:    app.openai_resolved_plan_from_plugin_result_with_defaults(model, body,
			resp.result, '/responses', 'openai.response')!
	}
}

fn (mut app App) openai_plugin_fallback_plan(model string, body string, method string, path string, failed_plan openai.OpenAIResolvedPlan, status_code int, error_code string, error_message string, req_id string, trace_id string) !openai.OpenAIPluginPlanResult {
	if app.protocols.openai.plugin.trim_space() == '' {
		return openai.OpenAIPluginPlanResult{}
	}
	resp := app.openai_call_plugin('chat.fallback', json.encode(openai.OpenAIPluginFallbackPayload{
		method:         method.to_upper()
		path:           path
		model:          model
		stream:         openai.OpenAIResolvedPlan.is_stream_request(body)
		body:           body
		base_path:      app.protocols.openai.base_path
		failed_backend: failed_plan.backend_name
		status_code:    status_code
		error_code:     error_code
		error_message:  error_message
		request_id:     req_id
		trace_id:       trace_id
	}), req_id, trace_id, {
		'model':          model
		'failed_backend': failed_plan.backend_name
	})!
	if openai.OpenAIPluginPlanResult.not_handled(resp.result) {
		return openai.OpenAIPluginPlanResult{}
	}
	return openai.OpenAIPluginPlanResult{
		handled: true
		plan:    app.openai_resolved_plan_from_plugin_result(model, body, resp.result)!
	}
}
