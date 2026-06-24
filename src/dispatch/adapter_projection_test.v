module dispatch

import runtime_plan

struct ProjectionTestServices {
	trace string
}

fn (services ProjectionTestServices) trace_id() string {
	return services.trace
}

fn (services ProjectionTestServices) emit(event string, fields map[string]string) {
	_ = services
	_ = event
	_ = fields
}

fn test_terminal_adapter_from_fixed_response_plan() {
	plan_adapter := runtime_plan.AdapterPlan{
		id:      'healthz'
		kind:    'fixed-response'
		options: runtime_plan.PlanOptions{
			strings: {
				'status': '204'
				'body':   ''
			}
		}
	}
	mut adapter := terminal_adapter_from_plan(plan_adapter) or { panic('missing adapter') }
	mut services := RuntimeServices(ProjectionTestServices{
		trace: 'trace-healthz'
	})
	exchange := http_request_exchange(HttpIngressRequest{
		method:     'GET'
		path:       '/healthz'
		request_id: 'req-healthz'
		trace_id:   'trace-healthz'
	})

	outcome := adapter.deliver(mut services, exchange) or { panic(err) }
	assert adapter.id() == 'healthz'
	assert outcome.kind == .response
	assert outcome.status == 204
}

fn test_terminal_adapter_from_fixed_response_location_defaults_to_redirect() {
	plan_adapter := runtime_plan.AdapterPlan{
		id:      'redirect'
		kind:    'fixed-response'
		options: runtime_plan.PlanOptions{
			strings: {
				'location': '/login'
			}
		}
	}
	mut adapter := terminal_adapter_from_plan(plan_adapter) or { panic('missing adapter') }
	mut services := RuntimeServices(ProjectionTestServices{
		trace: 'trace-redirect'
	})
	exchange := http_request_exchange(HttpIngressRequest{
		method:     'GET'
		path:       '/admin'
		request_id: 'req-redirect'
		trace_id:   'trace-redirect'
	})

	outcome := adapter.deliver(mut services, exchange) or { panic(err) }
	assert outcome.status == 302
	assert outcome.headers['location'] == '/login'
}

fn test_terminal_adapter_from_reject_plan() {
	plan_adapter := runtime_plan.AdapterPlan{
		id:      'blocked'
		kind:    'reject'
		options: runtime_plan.PlanOptions{
			ints:    {
				'status': 451
			}
			strings: {
				'error':       'blocked'
				'error_class': 'policy_blocked'
			}
		}
	}
	mut adapter := terminal_adapter_from_plan(plan_adapter) or { panic('missing adapter') }
	mut services := RuntimeServices(ProjectionTestServices{
		trace: 'trace-blocked'
	})
	exchange := http_request_exchange(HttpIngressRequest{
		method:     'GET'
		path:       '/blocked'
		request_id: 'req-blocked'
		trace_id:   'trace-blocked'
	})

	outcome := adapter.deliver(mut services, exchange) or { panic(err) }
	assert outcome.kind == .failure
	assert outcome.status == 451
	assert outcome.error_class == 'policy_blocked'
}

fn test_terminal_adapter_from_plan_ignores_non_terminal_adapters() {
	plan_adapter := runtime_plan.AdapterPlan{
		id:   'php'
		kind: 'http-handler'
	}
	assert terminal_adapter_from_plan(plan_adapter) == none
}

fn test_adapter_descriptor_marks_terminal_and_runtime_adapters() {
	fixed := adapter_descriptor_from_plan(runtime_plan.AdapterPlan{
		id:   'health'
		kind: 'fixed-response'
	})
	assert fixed.id == 'health'
	assert fixed.terminal
	assert fixed.capabilities.request_response

	http_handler := adapter_descriptor_from_plan(runtime_plan.AdapterPlan{
		id:   'php'
		kind: 'http-handler'
	})
	assert http_handler.kind == 'http-handler'
	assert !http_handler.terminal
	assert http_handler.capabilities.request_response
}

fn test_adapter_descriptor_preserves_upload_event_capability() {
	upload := adapter_descriptor_from_plan(runtime_plan.AdapterPlan{
		id:   'uploads'
		kind: 'upload'
	})
	assert !upload.terminal
	assert upload.capabilities.request_response
	assert upload.capabilities.events
}

fn test_adapter_descriptors_from_plan_indexes_by_adapter_id() {
	plan := runtime_plan.RuntimePlan{
		adapters: {
			'site/static': runtime_plan.AdapterPlan{
				id:   'site/static'
				kind: 'static'
			}
			'site/upload': runtime_plan.AdapterPlan{
				id:   'site/upload'
				kind: 'upload'
			}
		}
	}
	descriptors := adapter_descriptors_from_plan(plan)
	assert descriptors.len == 2
	assert descriptors['site/static'].capabilities.request_response
	assert descriptors['site/upload'].capabilities.events
}
