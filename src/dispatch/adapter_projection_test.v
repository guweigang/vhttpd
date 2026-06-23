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
