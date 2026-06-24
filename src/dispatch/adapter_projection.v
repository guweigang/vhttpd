module dispatch

import runtime_plan

pub fn adapter_descriptor_from_plan(adapter runtime_plan.AdapterPlan) AdapterDescriptor {
	return AdapterDescriptor{
		id:           adapter.id
		kind:         adapter.kind
		capabilities: adapter_capabilities(adapter.kind)
		terminal:     adapter.kind in ['fixed-response', 'reject']
	}
}

pub fn adapter_descriptors_from_plan(plan runtime_plan.RuntimePlan) map[string]AdapterDescriptor {
	mut descriptors := map[string]AdapterDescriptor{}
	for id, adapter in plan.adapters {
		descriptors[id] = adapter_descriptor_from_plan(adapter)
	}
	return descriptors
}

fn adapter_capabilities(kind string) Capabilities {
	match kind {
		'upload' {
			return Capabilities{
				request_response: true
				events:           true
			}
		}
		'websocket' {
			return Capabilities{
				sessions:     true
				full_duplex:  true
				multiplexing: true
			}
		}
		'mcp' {
			return Capabilities{
				request_response: true
				stream_output:    true
				sessions:         true
			}
		}
		else {
			return Capabilities{
				request_response: true
			}
		}
	}
}

pub fn terminal_adapter_from_plan(adapter runtime_plan.AdapterPlan) ?EgressAdapter {
	match adapter.kind {
		'fixed-response' {
			status := fixed_response_status(adapter.options)
			mut headers := map[string]string{}
			if location := adapter.options.strings['location'] {
				if location.trim_space() != '' {
					headers['location'] = location
				}
			}
			return EgressAdapter(fixed_response_adapter(adapter.id, status, headers,
				adapter.options.strings['body']))
		}
		'reject' {
			status := adapter.options.ints['status']
			return EgressAdapter(reject_adapter(adapter.id, status,
				adapter.options.strings['error'], adapter.options.strings['error_class']))
		}
		else {
			return none
		}
	}
}

fn fixed_response_status(options runtime_plan.PlanOptions) int {
	if raw := options.strings['status'] {
		status := raw.int()
		if status > 0 {
			return status
		}
	}
	if location := options.strings['location'] {
		if location.trim_space() != '' {
			return 302
		}
	}
	return 200
}
