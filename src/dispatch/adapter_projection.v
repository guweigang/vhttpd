module dispatch

import runtime_plan

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
