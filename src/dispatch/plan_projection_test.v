module dispatch

import runtime_plan

fn test_pipeline_descriptor_from_runtime_plan_preserves_refs() {
	pipeline := runtime_plan.PipelinePlan{
		id:         'site'
		group:      'wordpress'
		ingress:    runtime_plan.ResourceRef{
			domain: .listener
			id:     'web'
		}
		match:      runtime_plan.MatchPlan{
			methods: ['GET']
			hosts:   ['example.test']
			paths:   ['/']
		}
		transforms: [
			runtime_plan.ResourceRef{
				domain: .transform
				id:     'rewrite'
			},
		]
		policies:   [
			runtime_plan.ResourceRef{
				domain: .policy
				id:     'cache/public'
			},
		]
		egress:     runtime_plan.ResourceRef{
			domain: .adapter
			id:     'php'
		}
	}

	descriptor := pipeline_descriptor_from_plan(pipeline)
	assert descriptor.id == 'site'
	assert descriptor.group == 'wordpress'
	assert descriptor.ingress == 'listener:web'
	assert descriptor.transforms == ['transform:rewrite']
	assert descriptor.policies == ['policy:cache/public']
	assert descriptor.egress == 'adapter:php'

	matcher := http_match_from_plan(pipeline)
	assert matcher.methods == ['GET']
	assert matcher.hosts == ['example.test']
	assert matcher.paths == ['/']
}

fn test_listener_pipeline_descriptors_keep_listener_order() {
	plan := runtime_plan.RuntimePlan{
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'web/assets'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'assets'
				}
			},
			runtime_plan.PipelinePlan{
				id:      'admin/app'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'admin'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'admin'
				}
			},
			runtime_plan.PipelinePlan{
				id:      'web/app'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'php'
				}
			},
		]
	}

	descriptors := listener_pipeline_descriptors(plan, 'web')
	assert descriptors.map(it.id) == ['web/assets', 'web/app']
	assert descriptors.map(it.egress) == ['adapter:assets', 'adapter:php']
}

fn test_pipeline_descriptor_with_adapters_carries_egress_capabilities() {
	pipeline := runtime_plan.PipelinePlan{
		id:     'web/uploads'
		egress: runtime_plan.ResourceRef{
			domain: .adapter
			id:     'uploads'
		}
	}
	descriptor := pipeline_descriptor_from_plan_with_adapters(pipeline, {
		'uploads': AdapterDescriptor{
			id:           'uploads'
			kind:         'upload'
			capabilities: Capabilities{
				request_response: true
				events:           true
			}
		}
	})
	assert descriptor.required.request_response
	assert descriptor.required.events
}

fn test_transform_descriptor_from_plan_carries_handler_and_capabilities() {
	transform := transform_descriptor_from_plan(runtime_plan.TransformPlan{
		id:      'upload_completed'
		kind:    'vjsx'
		handler: 'uploads.completed'
	})
	assert transform.id == 'upload_completed'
	assert transform.kind == 'vjsx'
	assert transform.handler == 'uploads.completed'
	assert transform.capabilities.request_response
	assert transform.capabilities.events
}

fn test_pipeline_descriptor_with_runtime_descriptors_uses_egress_capabilities_only() {
	pipeline := runtime_plan.PipelinePlan{
		id:         'event/upload'
		transforms: [
			runtime_plan.ResourceRef{
				domain: .transform
				id:     'upload_completed'
			},
		]
		egress:     runtime_plan.ResourceRef{
			domain: .terminal
			id:     'ack'
		}
	}
	descriptor := pipeline_descriptor_from_plan_with_runtime_descriptors(pipeline,
		map[string]AdapterDescriptor{}, {
		'upload_completed': TransformDescriptor{
			id:           'upload_completed'
			kind:         'vjsx'
			capabilities: Capabilities{
				request_response: true
				events:           true
			}
		}
	})
	assert !descriptor.required.request_response
	assert descriptor.required.events
}

fn test_terminal_descriptor_projects_ack_and_response_capabilities() {
	ack := terminal_descriptor('ack') or { panic('missing ack') }
	assert ack.capabilities.events
	assert !ack.capabilities.request_response

	response := terminal_descriptor('response') or { panic('missing response') }
	assert response.capabilities.request_response
	assert !response.capabilities.events
	assert terminal_descriptor('missing') == none
}

fn test_pipeline_transform_capability_errors_report_unsupported_ingress_exchange() {
	pipeline := runtime_plan.PipelinePlan{
		id:         'ws-transform'
		transforms: [
			runtime_plan.ResourceRef{
				domain: .transform
				id:     'http_only'
			},
		]
	}
	ingress := IngressDescriptor{
		id:           'listener:ws'
		capabilities: Capabilities{
			sessions:    true
			full_duplex: true
		}
	}
	assert pipeline_transform_capability_errors(pipeline, ingress, {
		'http_only': TransformDescriptor{
			id:           'http_only'
			capabilities: Capabilities{
				request_response: true
			}
		}
	}) == [
		'pipeline_transform_capability_mismatch:ws-transform:listener:ws:transform:http_only:full_duplex',
		'pipeline_transform_capability_mismatch:ws-transform:listener:ws:transform:http_only:sessions',
	]
}

fn test_ingress_descriptor_from_listener_plan_defaults_empty_protocol_to_http() {
	ingress := ingress_descriptor_from_listener_plan(runtime_plan.ListenerPlan{
		id: 'web'
	})
	assert ingress.id == 'listener:web'
	assert ingress.capabilities.request_response
	assert ingress.capabilities.events
	assert ingress.capabilities.stream_output
}

fn test_ingress_descriptors_from_plan_include_event_ingress_adapters() {
	plan := runtime_plan.RuntimePlan{
		listeners: {
			'web': runtime_plan.ListenerPlan{
				id: 'web'
			}
		}
		adapters:  {
			'upload_event': runtime_plan.AdapterPlan{
				id:   'upload_event'
				kind: 'event-ingress'
			}
		}
	}
	descriptors := ingress_descriptors_from_plan(plan)
	assert descriptors['listener:web'].capabilities.request_response
	assert descriptors['adapter:upload_event'].capabilities.events
}

fn test_match_basic_http_pipeline_uses_plan_order() {
	plan := runtime_plan.RuntimePlan{
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'assets'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				match:   runtime_plan.MatchPlan{
					methods: ['GET']
					paths:   ['/wp-content/*']
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'assets'
				}
			},
			runtime_plan.PipelinePlan{
				id:      'fallback'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				match:   runtime_plan.MatchPlan{
					methods: ['GET']
					paths:   ['*']
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'php'
				}
			},
		]
	}
	exchange := http_request_exchange(HttpIngressRequest{
		method:     'GET'
		path:       '/wp-content/app.css'
		request_id: 'req-1'
		trace_id:   'trace-1'
	})

	matched := match_basic_http_pipeline(plan, 'web', exchange) or { panic('no match') }
	assert matched.id == 'assets'
	assert matched.egress == 'adapter:assets'
}

fn test_match_basic_http_pipeline_with_adapters_carries_required_capabilities() {
	plan := runtime_plan.RuntimePlan{
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'uploads'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				match:   runtime_plan.MatchPlan{
					methods: ['POST']
					paths:   ['/vhttpd/uploads']
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'upload'
				}
			},
		]
	}
	exchange := http_request_exchange(HttpIngressRequest{
		method:     'POST'
		path:       '/vhttpd/uploads'
		request_id: 'req-upload'
		trace_id:   'trace-upload'
	})
	matched := match_basic_http_pipeline_with_adapters(plan, 'web', exchange, {
		'upload': AdapterDescriptor{
			id:           'upload'
			kind:         'upload'
			capabilities: Capabilities{
				request_response: true
				events:           true
			}
		}
	}) or { panic('no match') }
	assert matched.id == 'uploads'
	assert matched.required.events
}

fn test_pipeline_capability_errors_from_plan_allows_http_upload_pipeline() {
	plan := runtime_plan.RuntimePlan{
		listeners: {
			'web': runtime_plan.ListenerPlan{
				id:       'web'
				protocol: 'http'
			}
		}
		adapters:  {
			'upload': runtime_plan.AdapterPlan{
				id:   'upload'
				kind: 'upload'
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'uploads'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'upload'
				}
			},
		]
	}
	assert pipeline_capability_errors_from_plan(plan).len == 0
}

fn test_pipeline_capability_errors_from_plan_reports_incompatible_websocket_egress() {
	plan := runtime_plan.RuntimePlan{
		listeners: {
			'web': runtime_plan.ListenerPlan{
				id:       'web'
				protocol: 'http'
			}
		}
		adapters:  {
			'ws': runtime_plan.AdapterPlan{
				id:   'ws'
				kind: 'websocket'
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'ws-on-http'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'ws'
				}
			},
		]
	}
	assert pipeline_capability_errors_from_plan(plan) == [
		'pipeline_capability_mismatch:ws-on-http:listener:web:full_duplex',
		'pipeline_capability_mismatch:ws-on-http:listener:web:sessions',
		'pipeline_capability_mismatch:ws-on-http:listener:web:multiplexing',
	]
}

fn test_pipeline_capability_errors_from_plan_visits_event_ingress_pipeline() {
	plan := runtime_plan.RuntimePlan{
		adapters:  {
			'upload_event': runtime_plan.AdapterPlan{
				id:   'upload_event'
				kind: 'event-ingress'
			}
			'ws':           runtime_plan.AdapterPlan{
				id:   'ws'
				kind: 'websocket'
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'event-to-ws'
				ingress: runtime_plan.ResourceRef{
					domain: .adapter
					id:     'upload_event'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'ws'
				}
			},
		]
	}
	assert pipeline_capability_errors_from_plan(plan) == [
		'pipeline_capability_mismatch:event-to-ws:adapter:upload_event:full_duplex',
		'pipeline_capability_mismatch:event-to-ws:adapter:upload_event:sessions',
		'pipeline_capability_mismatch:event-to-ws:adapter:upload_event:multiplexing',
	]
}

fn test_pipeline_capability_errors_from_plan_allows_event_ingress_transform_ack_pipeline() {
	plan := runtime_plan.RuntimePlan{
		adapters:   {
			'upload_event': runtime_plan.AdapterPlan{
				id:   'upload_event'
				kind: 'event-ingress'
			}
		}
		transforms: {
			'upload_completed': runtime_plan.TransformPlan{
				id:      'upload_completed'
				kind:    'vjsx'
				handler: 'uploads.completed'
			}
		}
		pipelines:  [
			runtime_plan.PipelinePlan{
				id:         'event-upload'
				ingress:    runtime_plan.ResourceRef{
					domain: .adapter
					id:     'upload_event'
				}
				transforms: [
					runtime_plan.ResourceRef{
						domain: .transform
						id:     'upload_completed'
					},
				]
				egress:     runtime_plan.ResourceRef{
					domain: .terminal
					id:     'ack'
				}
			},
		]
	}
	assert pipeline_capability_errors_from_plan(plan).len == 0
}

fn test_match_basic_http_pipeline_skips_regex_pipeline() {
	plan := runtime_plan.RuntimePlan{
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'regex'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				match:   runtime_plan.MatchPlan{
					path_regexp: '^/items/[0-9]+$'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'regex'
				}
			},
			runtime_plan.PipelinePlan{
				id:      'fallback'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				match:   runtime_plan.MatchPlan{
					paths: ['*']
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'fallback'
				}
			},
		]
	}
	exchange := http_request_exchange(HttpIngressRequest{
		method:     'GET'
		path:       '/items/123'
		request_id: 'req-2'
		trace_id:   'trace-2'
	})

	matched := match_basic_http_pipeline(plan, 'web', exchange) or { panic('no match') }
	assert matched.id == 'fallback'
}
