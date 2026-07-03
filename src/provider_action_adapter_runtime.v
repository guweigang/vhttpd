module main

import runtime_plan

fn provider_action_payload(adapter_plan runtime_plan.AdapterPlan, fallback string) string {
	configured := adapter_plan.options.strings['payload']
	if configured.trim_space() != '' {
		return configured
	}
	return fallback
}

fn provider_action_response_status(adapter_plan runtime_plan.AdapterPlan) int {
	status := adapter_plan.options.ints['status']
	if status > 0 {
		return status
	}
	return 200
}

fn provider_action_response_content_type(adapter_plan runtime_plan.AdapterPlan) string {
	content_type := adapter_plan.options.strings['content_type']
	if content_type.trim_space() != '' {
		return content_type
	}
	return 'application/json'
}

fn (mut app App) dispatch_provider_action_adapter(adapter_plan runtime_plan.AdapterPlan, adapter_id string, payload string, request_id string, trace_id string, metadata map[string]string) ProviderRuntimeActionResponse {
	mut next_metadata := metadata.clone()
	if adapter_id != '' {
		next_metadata['adapter_id'] = adapter_id
	}
	provider_name := adapter_plan.options.strings['provider']
	action := adapter_plan.options.strings['action']
	return app.providers.dispatch_provider_runtime_action_with_override(ProviderRuntimeActionRequest{
		provider:   provider_name
		action:     action
		payload:    payload
		request_id: request_id
		trace_id:   trace_id
		metadata:   next_metadata
	}, ProviderRuntimeOverride{
		driver:     adapter_plan.options.strings['runtime_driver']
		plugin:     adapter_plan.options.strings['runtime_plugin']
		capability: adapter_plan.options.strings['capability']
	}, mut app)
}
