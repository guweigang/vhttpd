module main

import config
import dispatch
import executor
import os
import plugin
import relay
import runtime_plan
import upstream.transport
import worker

struct RelayMcpTestExecutor {}

fn (e RelayMcpTestExecutor) model() executor.LogicExecutorModel {
	_ = e
	return .worker
}

fn (e RelayMcpTestExecutor) kind() string {
	_ = e
	return 'relay-mcp-test'
}

fn (e RelayMcpTestExecutor) provider() string {
	_ = e
	return 'relay-mcp-test'
}

fn (e RelayMcpTestExecutor) admin_details() executor.LogicExecutorAdminDetails {
	_ = e
	return executor.LogicExecutorAdminDetails{
		kind:     'relay-mcp-test'
		provider: 'relay-mcp-test'
		model:    executor.LogicExecutorModel.worker.str()
	}
}

fn (e RelayMcpTestExecutor) warmup(mut app executor.AppFacade) ! {
	_ = e
	_ = app
}

fn (e RelayMcpTestExecutor) close() {
	_ = e
}

fn (e RelayMcpTestExecutor) dispatch_http(mut app executor.AppFacade, req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
	_ = e
	_ = app
	_ = req
	return error('not_used')
}

fn (e RelayMcpTestExecutor) open_websocket_session(mut app executor.AppFacade, req executor.WebSocketSessionOpenRequest) !executor.WebSocketSessionOpenOutcome {
	_ = e
	_ = app
	_ = req
	return error('not_used')
}

fn (e RelayMcpTestExecutor) dispatch_stream(mut app executor.AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('not_used')
}

fn (e RelayMcpTestExecutor) dispatch_mcp(mut app executor.AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	_ = e
	_ = app
	return transport.WorkerMcpDispatchResponse{
		mode:             'mcp'
		event:            'message'
		id:               req.id
		handled:          true
		status:           200
		headers:          {
			'content-type': 'application/json'
		}
		body:             '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"${req.protocol_version}","capabilities":{},"serverInfo":{"name":"relay-test","version":"1.0.0"}}}'
		protocol_version: req.protocol_version
	}
}

fn (e RelayMcpTestExecutor) dispatch_websocket_upstream(mut app executor.AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('not_used')
}

fn (e RelayMcpTestExecutor) dispatch_websocket_event(mut app executor.AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = e
	_ = app
	_ = frame
	return error('not_used')
}

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

fn test_runtime_routes_from_plan_exposes_relay_delivery_http_pipeline() {
	plan := runtime_plan.RuntimePlan{
		adapters:  {
			'relay-edge': runtime_plan.AdapterPlan{
				id:      'relay-edge'
				kind:    'relay-delivery'
				options: runtime_plan.PlanOptions{
					strings: {
						'target':          'relay:edge'
						'completion_mode': 'wait'
					}
					ints:    {
						'completion_timeout_ms': 1000
					}
				}
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'public/relay'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				match:   runtime_plan.MatchPlan{
					paths: ['/relay']
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'relay-edge'
				}
			},
		]
	}

	routes := runtime_routes_from_plan(plan, 'web')
	assert routes.len == 1
	assert routes[0].pipeline_id == 'public/relay'
	assert routes[0].egress_ref == 'adapter:relay-edge'
	assert routes[0].executor == 'relay-delivery'
	assert routes[0].match_path == ['/relay']
}

fn test_pipeline_runtime_matches_relay_delivery_http_route() {
	plan := runtime_plan.RuntimePlan{
		adapters:  {
			'relay-edge': runtime_plan.AdapterPlan{
				id:      'relay-edge'
				kind:    'relay-delivery'
				options: runtime_plan.PlanOptions{
					strings: {
						'target':          'relay:edge'
						'completion_mode': 'wait'
					}
				}
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'public/relay'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				match:   runtime_plan.MatchPlan{
					paths: ['/relay']
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'relay-edge'
				}
			},
		]
	}
	routes := runtime_routes_from_plan(plan, 'web')
	runtime := PipelineRuntime.new(plan, 'web', routes, '', '', map[string]string{},
		map[string]&worker.WorkerState{})
	matched := runtime.match_http_request(HttpPipelineMatchRequest{
		method:            'GET'
		normalized_target: '/relay'
		query:             map[string]string{}
		headers:           map[string]string{}
		body:              ''
		remote_addr:       '127.0.0.1'
		req_id:            'req-relay'
		trace_id:          'trace-relay'
		start_ms:          123
	}) or { panic('relay route did not match') }
	plan_for_request := runtime.http_dispatch_plan(matched, '/relay')
	assert matched.pipeline_id == 'public/relay'
	assert plan_for_request.executor == 'relay-delivery'
	assert plan_for_request.pipeline_id == 'public/relay'
}

fn test_relay_delivery_pipeline_can_override_protocol_mcp_route() {
	plan := runtime_plan.RuntimePlan{
		adapters:  {
			'relay-edge': runtime_plan.AdapterPlan{
				id:      'relay-edge'
				kind:    'relay-delivery'
				options: runtime_plan.PlanOptions{
					strings: {
						'target':          'relay:edge'
						'completion_mode': 'wait'
					}
				}
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'public/mcp-relay'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				match:   runtime_plan.MatchPlan{
					methods: ['GET', 'POST', 'DELETE']
					paths:   ['/mcp']
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'relay-edge'
				}
			},
		]
	}
	routes := runtime_routes_from_plan(plan, 'web')
	runtime := PipelineRuntime.new(plan, 'web', routes, '', '', map[string]string{},
		map[string]&worker.WorkerState{})

	assert runtime.has_protocol_http_override(ProtocolHttpRequest{
		method:            'POST'
		target:            '/mcp'
		normalized_target: '/mcp'
		query:             map[string]string{}
		headers:           map[string]string{}
		body:              '{"jsonrpc":"2.0"}'
		request_id:        'req-mcp-relay'
		trace_id:          'trace-mcp-relay'
		start_ms:          123
	})
}

fn test_dispatch_relay_pipeline_exchange_delivers_mcp_adapter() {
	mut app := App{
		plan:    runtime_plan.RuntimePlan{
			adapters: {
				'mcp': runtime_plan.AdapterPlan{
					id:      'mcp'
					kind:    'mcp'
					options: runtime_plan.PlanOptions{
						ints: {
							'max_sessions': 7
						}
					}
				}
			}
		}
		engines: EngineRuntime{
			primary: worker.WorkerState{
				logic_executor: RelayMcpTestExecutor{}
			}
		}
	}
	mut exchange := dispatch.relay_ingress_exchange(dispatch.RelayIngressRequest{
		relay_id:    'edge'
		carrier_id:  'agent:edge'
		frame_id:    'frm-mcp'
		channel_id:  'chan-mcp'
		session_id:  'chan-mcp'
		trace_id:    'trace-mcp'
		request_id:  'req-mcp'
		exchange_id: 'frm-mcp'
		ingress:     'relay:edge'
		pipeline:    'relay/local-mcp'
		kind:        .request
		body:        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"relay-test","version":"1"}}}'
		headers:     {
			'content-type':         'application/json'
			'mcp-protocol-version': '2025-06-18'
		}
		metadata:    {
			'http_method': 'POST'
			'path':        '/mcp'
		}
	})

	mut services := noop_dispatch_services('trace-mcp')
	outcome := app.dispatch_relay_pipeline_adapter_egress('mcp', mut services, exchange)

	assert outcome.action == 'response'
	assert outcome.status == 200
	assert outcome.headers['mcp-protocol-version'] == '2025-06-18'
	assert outcome.headers['mcp-session-id'] != ''
	assert outcome.body.contains('"serverInfo"')
}

fn test_dispatch_relay_pipeline_exchange_rejects_mcp_upstream_without_url() {
	mut app := App{
		plan: runtime_plan.RuntimePlan{
			adapters: {
				'local-mcp': runtime_plan.AdapterPlan{
					id:   'local-mcp'
					kind: 'mcp-upstream'
				}
			}
		}
	}
	mut exchange := dispatch.relay_ingress_exchange(dispatch.RelayIngressRequest{
		relay_id:    'edge'
		carrier_id:  'agent:edge'
		frame_id:    'frm-mcp-upstream'
		channel_id:  'chan-mcp-upstream'
		trace_id:    'trace-mcp-upstream'
		request_id:  'req-mcp-upstream'
		exchange_id: 'frm-mcp-upstream'
		ingress:     'relay:edge'
		pipeline:    'relay/local-mcp'
		kind:        .request
		body:        '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
		headers:     {
			'content-type': 'application/json'
		}
		metadata:    {
			'http_method': 'POST'
			'path':        '/mcp'
		}
	})

	mut services := noop_dispatch_services('trace-mcp-upstream')
	outcome := app.dispatch_relay_pipeline_adapter_egress('local-mcp', mut services, exchange)

	assert outcome.action == 'failed'
	assert outcome.status == 500
	assert outcome.error_class == 'mcp_upstream_missing_url'
}

fn test_mcp_upstream_http_method_normalizes_methods() {
	assert mcp_upstream_http_method('POST').str() == 'POST'
	assert mcp_upstream_http_method('delete').str() == 'DELETE'
	assert mcp_upstream_http_method('OPTIONS').str() == 'OPTIONS'
	assert mcp_upstream_http_method('').str() == 'GET'
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

fn test_dispatch_relay_pipeline_exchange_delivers_provider_action_adapter() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_relay_provider_action_vjsx_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	plugin_file := os.join_path(temp_dir, 'relay-provider-action.mts')
	os.write_file(plugin_file, "
export function plugin(req) {
  const payload = JSON.parse(req.payload);
  return {
    ok: true,
    message_id: 'relay-' + payload.receive_id,
    metadata_pipeline: req.metadata.pipeline_id,
    metadata_channel: req.metadata.channel_id,
  };
}
") or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	plugins := {
		'relay-provider-action': config.PluginConfig{
			kind:            'vjsx'
			app_entry:       plugin_file
			runtime_profile: 'node'
			thread_count:    1
		}
	}
	mut app := App{
		plan:      runtime_plan.RuntimePlan{
			adapters:  {
				'provider-send': runtime_plan.AdapterPlan{
					id:      'provider-send'
					kind:    'provider-action'
					options: runtime_plan.PlanOptions{
						strings: {
							'provider': 'feishu'
							'action':   'send_message'
						}
					}
				}
			}
			pipelines: [
				runtime_plan.PipelinePlan{
					id:      'edge/provider-send'
					ingress: runtime_plan.ResourceRef{
						domain: .relay
						id:     'edge'
					}
					egress:  runtime_plan.ResourceRef{
						domain: .adapter
						id:     'provider-send'
					}
				},
			]
		}
		providers: ProviderRuntimeHub{
			runtime_drivers: {
				'feishu': 'vjsx'
			}
			runtime_plugins: {
				'feishu': 'relay-provider-action'
			}
		}
	}
	app.protocols.plugins = plugin.PluginState{
		configs: plugins
		vjsx:    build_vjsx_plugin_runtimes(plugins)
	}
	defer {
		app.close_all_plugins()
	}
	mut exchange := dispatch.relay_ingress_exchange(dispatch.RelayIngressRequest{
		relay_id:   'edge'
		frame_id:   'frm-provider'
		trace_id:   'trace-provider'
		request_id: 'req-provider'
		pipeline:   'edge/provider-send'
		channel_id: 'chan-provider'
		session_id: 'sess-provider'
		body:       '{"receive_id":"oc_relay"}'
	})

	outcome := app.dispatch_relay_pipeline_exchange(mut exchange)

	assert outcome.action == 'response'
	assert outcome.status == 200
	assert outcome.channel_id == 'chan-provider'
	assert outcome.body.contains('"message_id":"relay-oc_relay"')
	assert outcome.body.contains('"metadata_pipeline":"edge/provider-send"')
	assert outcome.body.contains('"metadata_channel":"chan-provider"')
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
