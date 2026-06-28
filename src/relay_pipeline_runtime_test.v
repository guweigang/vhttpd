module main

import dispatch
import relay
import runtime_plan
import worker

fn test_dispatch_relay_ingress_frame_runs_terminal_response_pipeline() {
	mut app := App{
		plan: runtime_plan.RuntimePlan{
			relays:    {
				'edge': runtime_plan.RelayPlan{
					id:      'edge'
					mode:    'agent'
					carrier: 'websocket'
				}
			}
			pipelines: [
				runtime_plan.PipelinePlan{
					id:      'edge/local'
					ingress: runtime_plan.ResourceRef{
						domain: .relay
						id:     'edge'
					}
					egress:  runtime_plan.ResourceRef{
						domain: .terminal
						id:     'response'
					}
				},
			]
		}
	}
	app.pipelines = PipelineRuntime.new(app.plan, 'default', []RuntimeRouteRule{}, '', '',
		map[string]string{}, map[string]&worker.WorkerState{})

	outcomes := app.dispatch_relay_ingress_frame('edge', 'agent:edge', relay.WireFrame{
		version:    relay.wire_version
		kind:       .data
		id:         'frm-1'
		trace_id:   'trace-1'
		channel_id: 'chan-1'
		body:       'payload'
	}, 123)

	assert outcomes.len == 1
	assert outcomes[0].pipeline_id == 'edge/local'
	assert outcomes[0].exchange_id == 'frm-1'
	assert outcomes[0].trace_id == 'trace-1'
	assert outcomes[0].channel_id == 'chan-1'
	assert outcomes[0].action == 'response'
	assert outcomes[0].status == 200
	assert outcomes[0].body == 'payload'
}

fn test_public_http_relay_delivery_reaches_agent_pipeline_and_returns_response() {
	mut public_services := dispatch.RuntimeServices(dispatch.NoOpRuntimeServices{
		trace: 'trace-public'
	})
	public_exchange := dispatch.Exchange{
		identity: dispatch.ExchangeIdentity{
			id:         'frm-public'
			request_id: 'req-public'
			trace_id:   'trace-public'
		}
		kind:     .request
		ingress:  'listener:web'
		pipeline: 'public/relay'
		headers:  map[string]string{}
		metadata: map[string]string{}
		payload:  dispatch.RequestPayload{
			method: 'GET'
			path:   '/relay'
			body:   'public payload'
		}
	}
	mut public_adapter := dispatch.EgressAdapter(dispatch.relay_delivery_adapter('relay-edge',
		'relay:edge', 'wait', 1000, {
		'frame_kind': 'open'
		'route':      'relay/local-response'
	}))
	public_delivery := public_adapter.deliver(mut public_services, public_exchange) or {
		panic(err)
	}
	mut public_relay := relay.empty_runtime()
	public_relay.register_carrier('edge', 'carrier-edge') or { panic(err) }
	outbound := public_relay.prepare_outbound_delivery(public_delivery)
	tracking := public_relay.track_outbound_delivery(outbound, 64)

	mut agent_app := App{
		plan: runtime_plan.RuntimePlan{
			adapters:  {
				'local-response': runtime_plan.AdapterPlan{
					id:      'local-response'
					kind:    'fixed-response'
					options: runtime_plan.PlanOptions{
						strings: {
							'status': '207'
							'body':   'relay agent ok'
						}
					}
				}
			}
			pipelines: [
				runtime_plan.PipelinePlan{
					id:      'relay/local-response'
					ingress: runtime_plan.ResourceRef{
						domain: .relay
						id:     'edge'
					}
					egress:  runtime_plan.ResourceRef{
						domain: .adapter
						id:     'local-response'
					}
				},
			]
		}
	}
	mut agent_exchange := dispatch.relay_ingress_exchange(relay.relay_ingress_request_from_frame('edge',
		'agent:edge', outbound.frame, 'relay/local-response', 123))
	agent_outcome := agent_app.dispatch_relay_pipeline_exchange(mut agent_exchange)
	response_frame := relay_pipeline_response_frame(agent_outcome)
	public_relay.handle_frame(response_frame, 'agent:edge', 64)

	http_outcome := relay_delivery_send_http_outcome(mut public_relay, outbound, relay.CarrierSendResult{
		ok:       true
		trace_id: outbound.trace_id
		frame_id: outbound.frame_id
	})

	assert outbound.frame.trace_id == 'trace-public'
	assert outbound.frame.request_id == 'req-public'
	assert outbound.frame.channel_id == 'req-public'
	assert outbound.frame.route == 'relay/local-response'
	assert outbound.completion.mode == 'wait'
	assert tracking.action == .opened
	assert tracking.channel_id == 'req-public'
	assert agent_outcome.trace_id == 'trace-public'
	assert agent_outcome.channel_id == 'req-public'
	assert response_frame.trace_id == 'trace-public'
	assert response_frame.metadata['response_to'] == 'frm-public'
	assert http_outcome.kind == .response
	assert http_outcome.status == 207
	assert http_outcome.body == 'relay agent ok'
	assert http_outcome.metadata['trace_id'] == 'trace-public'
	assert http_outcome.metadata['relay_event'] == 'response_completion.completed'
	assert http_outcome.metadata['target_id'] == 'frm-public'
	assert public_relay.snapshot().channel_count == 0
}

fn test_dispatch_and_send_relay_ingress_frame_reports_send_result() {
	mut app := App{
		plan: runtime_plan.RuntimePlan{
			relays:    {
				'edge': runtime_plan.RelayPlan{
					id:      'edge'
					mode:    'agent'
					carrier: 'websocket'
				}
			}
			pipelines: [
				runtime_plan.PipelinePlan{
					id:      'edge/local'
					ingress: runtime_plan.ResourceRef{
						domain: .relay
						id:     'edge'
					}
					egress:  runtime_plan.ResourceRef{
						domain: .terminal
						id:     'response'
					}
				},
			]
		}
	}
	app.pipelines = PipelineRuntime.new(app.plan, 'default', []RuntimeRouteRule{}, '', '',
		map[string]string{}, map[string]&worker.WorkerState{})

	outcomes := app.dispatch_and_send_relay_ingress_frame('edge', 'agent:edge', relay.WireFrame{
		version:    relay.wire_version
		kind:       .data
		id:         'frm-1'
		trace_id:   'trace-1'
		channel_id: 'chan-1'
		body:       'payload'
	}, 123)

	assert outcomes.len == 1
	assert outcomes[0].action == 'response'
	assert outcomes[0].carrier_id == 'agent:edge'
	assert outcomes[0].response_frame_id == 'relay-response:frm-1'
	assert outcomes[0].carrier_send_ok
	assert outcomes[0].carrier_send_error == ''
}

fn test_dispatch_relay_ingress_frame_reports_missing_pipeline() {
	mut app := App{
		plan: runtime_plan.RuntimePlan{}
	}
	app.pipelines = PipelineRuntime.new(app.plan, 'default', []RuntimeRouteRule{}, '', '',
		map[string]string{}, map[string]&worker.WorkerState{})

	outcomes := app.dispatch_relay_ingress_frame('missing', 'agent:edge', relay.WireFrame{
		id:       'frm-1'
		trace_id: 'trace-1'
	}, 0)

	assert outcomes.len == 1
	assert outcomes[0].action == 'rejected'
	assert outcomes[0].status == 404
	assert outcomes[0].error_class == 'relay_pipeline_not_found'
}

fn test_dispatch_relay_pipeline_exchange_reports_unsupported_egress() {
	mut app := App{
		plan: runtime_plan.RuntimePlan{
			adapters:  {
				'local': runtime_plan.AdapterPlan{
					id:   'local'
					kind: 'http-handler'
				}
			}
			pipelines: [
				runtime_plan.PipelinePlan{
					id:      'edge/local'
					ingress: runtime_plan.ResourceRef{
						domain: .relay
						id:     'edge'
					}
					egress:  runtime_plan.ResourceRef{
						domain: .adapter
						id:     'local'
					}
				},
			]
		}
	}
	mut exchange := dispatch.relay_ingress_exchange(dispatch.RelayIngressRequest{
		relay_id:   'edge'
		frame_id:   'frm-1'
		trace_id:   'trace-1'
		request_id: 'req-1'
		pipeline:   'edge/local'
		session_id: 'sess-1'
		body:       'payload'
	})

	outcome := app.dispatch_relay_pipeline_exchange(mut exchange)

	assert outcome.action == 'failed'
	assert outcome.status == 501
	assert outcome.error == 'relay_pipeline_egress_unsupported:adapter:local'
	assert outcome.error_class == 'relay_pipeline_egress_unsupported'
}

fn test_dispatch_relay_pipeline_exchange_delivers_terminal_adapter() {
	mut app := App{
		plan: runtime_plan.RuntimePlan{
			adapters:  {
				'fixed': runtime_plan.AdapterPlan{
					id:      'fixed'
					kind:    'fixed-response'
					options: runtime_plan.PlanOptions{
						strings: {
							'status': '202'
							'body':   'relay ok'
						}
					}
				}
			}
			pipelines: [
				runtime_plan.PipelinePlan{
					id:      'edge/local'
					ingress: runtime_plan.ResourceRef{
						domain: .relay
						id:     'edge'
					}
					egress:  runtime_plan.ResourceRef{
						domain: .adapter
						id:     'fixed'
					}
				},
			]
		}
	}
	mut exchange := dispatch.relay_ingress_exchange(dispatch.RelayIngressRequest{
		relay_id:   'edge'
		frame_id:   'frm-1'
		trace_id:   'trace-1'
		request_id: 'req-1'
		pipeline:   'edge/local'
		channel_id: 'chan-1'
		session_id: 'sess-1'
		body:       'payload'
	})

	outcome := app.dispatch_relay_pipeline_exchange(mut exchange)

	assert outcome.action == 'response'
	assert outcome.status == 202
	assert outcome.body == 'relay ok'
	assert outcome.channel_id == 'chan-1'
}

fn test_relay_pipeline_outcome_with_send_result_preserves_dispatch_fields() {
	outcome := relay_pipeline_outcome_with_send_result(RelayPipelineDispatchOutcome{
		pipeline_id: 'edge/local'
		exchange_id: 'frm-1'
		trace_id:    'trace-1'
		channel_id:  'chan-1'
		action:      'response'
		status:      200
		body:        'ok'
	}, 'agent:edge', 'relay-response:frm-1', relay.CarrierSendResult{
		ok:       true
		trace_id: 'trace-1'
		frame_id: 'relay-response:frm-1'
		queued:   true
	})

	assert outcome.pipeline_id == 'edge/local'
	assert outcome.carrier_id == 'agent:edge'
	assert outcome.response_frame_id == 'relay-response:frm-1'
	assert outcome.carrier_send_ok
	assert outcome.carrier_send_queued
	assert outcome.carrier_send_error == ''
}

fn test_relay_pipeline_response_frame_projects_success_and_failure() {
	success := relay_pipeline_response_frame(RelayPipelineDispatchOutcome{
		pipeline_id: 'edge/local'
		exchange_id: 'frm-1'
		trace_id:    'trace-1'
		channel_id:  'chan-1'
		action:      'response'
		status:      200
		body:        'ok'
		headers:     {
			'content-type': 'text/plain'
		}
	})
	failure := relay_pipeline_response_frame(RelayPipelineDispatchOutcome{
		pipeline_id: 'edge/local'
		exchange_id: 'frm-2'
		trace_id:    'trace-2'
		channel_id:  'chan-2'
		action:      'failed'
		status:      500
		error:       'boom'
		error_class: 'relay_error'
	})

	assert success.kind == .data
	assert success.id == 'relay-response:frm-1'
	assert success.exchange_kind == 'response'
	assert success.channel_id == 'chan-1'
	assert success.body == 'ok'
	assert success.metadata['status'] == '200'
	assert success.metadata['response_to'] == 'frm-1'
	assert success.headers['content-type'] == 'text/plain'

	assert failure.kind == .error
	assert failure.id == 'relay-response:frm-2'
	assert failure.exchange_kind == 'error'
	assert failure.channel_id == 'chan-2'
	assert failure.body == 'boom'
	assert failure.metadata['response_to'] == 'frm-2'
	assert failure.metadata['error_class'] == 'relay_error'
}

fn test_relay_frame_should_dispatch_pipeline_skips_response_frames() {
	assert relay_frame_should_dispatch_pipeline(relay.WireFrame{
		kind:       .open
		id:         'frm-open'
		trace_id:   'trace-1'
		channel_id: 'chan-1'
	})
	assert relay_frame_should_dispatch_pipeline(relay.WireFrame{
		kind:          .data
		id:            'frm-request'
		trace_id:      'trace-1'
		channel_id:    'chan-1'
		exchange_kind: 'request'
	})
	assert !relay_frame_should_dispatch_pipeline(relay.WireFrame{
		kind:          .data
		id:            'relay-response:frm-1'
		trace_id:      'trace-1'
		channel_id:    'chan-1'
		exchange_kind: 'response'
	})
	assert !relay_frame_should_dispatch_pipeline(relay.WireFrame{
		kind:          .error
		id:            'relay-response:frm-2'
		trace_id:      'trace-1'
		channel_id:    'chan-1'
		exchange_kind: 'error'
	})
}

fn test_relay_pipeline_delivery_outcome_projection_handles_response_and_failure() {
	exchange := dispatch.relay_ingress_exchange(dispatch.RelayIngressRequest{
		relay_id:   'edge'
		frame_id:   'frm-1'
		trace_id:   'trace-1'
		pipeline:   'edge/local'
		channel_id: 'chan-1'
		session_id: 'sess-1'
		body:       'request-body'
	})
	response := relay_pipeline_outcome_from_delivery(exchange, dispatch.response_outcome(201, {
		'content-type': 'application/json'
	}, '{"ok":true}'))
	failure := relay_pipeline_outcome_from_delivery(exchange, dispatch.delivery_failure_outcome(418,
		'teapot', 'short_and_stout'))

	assert response.action == 'response'
	assert response.status == 201
	assert response.body == '{"ok":true}'
	assert response.headers['content-type'] == 'application/json'
	assert response.channel_id == 'chan-1'

	assert failure.action == 'failed'
	assert failure.status == 418
	assert failure.body == 'teapot'
	assert failure.error_class == 'short_and_stout'
}
