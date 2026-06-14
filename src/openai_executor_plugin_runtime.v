module main

import api.openai
import json

fn (mut app App) openai_call_executor_op(plan openai.OpenAIResolvedPlan, op string, method string, path string, req_id string, trace_id string) !PluginCallResponse {
	executor_name := plan.backend.executor.trim_space()
	if executor_name == '' {
		return error('openai_executor_missing_name:${plan.backend_name}')
	}
	return app.call_plugin(PluginCallRequest{
		plugin:     executor_name
		capability: 'openai'
		op:         op
		request_id: req_id
		trace_id:   trace_id
		payload:    json.encode(openai.OpenAIExecutorPayload{
			method:          method.to_upper()
			path:            path
			model:           plan.model
			stream:          openai.OpenAIResolvedPlan.is_stream_request(plan.body)
			body:            plan.body
			backend:         plan.backend_name
			request_id:      req_id
			trace_id:        trace_id
			response_codec:  plan.response_codec
			output_protocol: plan.output_protocol
		})
		metadata:   {
			'model':   plan.model
			'backend': plan.backend_name
		}
	})
}

fn (mut app App) openai_call_executor(plan openai.OpenAIResolvedPlan, method string, path string, req_id string, trace_id string) !PluginCallResponse {
	return app.openai_call_executor_op(plan, 'chat.execute', method, path, req_id, trace_id)
}

fn (mut app App) openai_call_executor_stream_op(plan openai.OpenAIResolvedPlan, op string, method string, path string, req_id string, trace_id string, on_frame PluginStreamFrameFn) !PluginStreamCallResponse {
	executor_name := plan.backend.executor.trim_space()
	if executor_name == '' {
		return error('openai_executor_missing_name:${plan.backend_name}')
	}
	return app.call_plugin_stream(PluginCallRequest{
		plugin:     executor_name
		capability: 'openai'
		op:         op
		request_id: req_id
		trace_id:   trace_id
		payload:    json.encode(openai.OpenAIExecutorPayload{
			method:          method.to_upper()
			path:            path
			model:           plan.model
			stream:          openai.OpenAIResolvedPlan.is_stream_request(plan.body)
			body:            plan.body
			backend:         plan.backend_name
			request_id:      req_id
			trace_id:        trace_id
			response_codec:  plan.response_codec
			output_protocol: plan.output_protocol
		})
		metadata:   {
			'model':   plan.model
			'backend': plan.backend_name
		}
	}, on_frame)
}

fn (mut app App) openai_call_executor_stream(plan openai.OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, on_frame PluginStreamFrameFn) !PluginStreamCallResponse {
	return app.openai_call_executor_stream_op(plan, 'chat.execute', method, path, req_id, trace_id,
		on_frame)
}
