module main

import dispatch
import os
import runtime_plan
import worker

fn transformer_conformance_exchange() dispatch.Exchange {
	return dispatch.Exchange{
		identity: dispatch.ExchangeIdentity{
			id:         'ex-conformance'
			request_id: 'req-conformance'
			trace_id:   'trace-conformance'
		}
		kind:     .event
		ingress:  'adapter:upload'
		pipeline: 'upload.completed'
		headers:  {
			'x-conformance': 'yes'
		}
		metadata: {
			'route': '/vhttpd/uploads'
		}
		payload:  dispatch.EventPayload{
			topic: 'upload'
			name:  'upload.completed'
			data:  '{"upload_id":"upl_conformance"}'
		}
	}
}

fn transformer_conformance_services() dispatch.RuntimeServices {
	return dispatch.RuntimeServices(dispatch.NoOpRuntimeServices{
		trace: 'trace-conformance'
	})
}

fn test_transformer_conformance_native_backend_continues_event_exchange() {
	plan := runtime_plan.RuntimePlan{
		transforms: {
			'conformance': runtime_plan.TransformPlan{
				id:      'conformance'
				kind:    'native'
				handler: 'test.conformance'
			}
		}
	}
	mut hub := TransformerRuntimeHub.from_plan(plan)
	mut services := transformer_conformance_services()
	mut exchange := transformer_conformance_exchange()
	result := hub.run_transform_refs(['transform:conformance'], mut services, mut exchange) or {
		panic(err)
	}
	assert !result.halted
	assert result.action.kind == .continue_pipeline
}

fn test_transformer_conformance_native_feishu_event_summary_maps_message_metadata() {
	plan := runtime_plan.RuntimePlan{
		transforms: {
			'feishu-summary': runtime_plan.TransformPlan{
				id:      'feishu-summary'
				kind:    'native'
				handler: 'feishu.event.summary'
			}
		}
	}
	mut hub := TransformerRuntimeHub.from_plan(plan)
	mut services := transformer_conformance_services()
	mut exchange := dispatch.Exchange{
		identity: dispatch.ExchangeIdentity{
			id:         'ex-feishu'
			request_id: 'req-feishu'
			trace_id:   'trace-feishu'
		}
		kind:     .event
		ingress:  'listener:feishu'
		pipeline: 'feishu.callback'
		headers:  map[string]string{}
		metadata: map[string]string{}
		payload:  dispatch.EventPayload{
			topic: 'feishu'
			name:  'im.message.receive_v1'
			data:  '{"header":{"event_id":"evt_1","event_type":"im.message.receive_v1"},"event":{"sender":{"sender_id":{"open_id":"ou_sender"},"tenant_key":"tenant_a"},"message":{"message_id":"om_x","message_type":"text","chat_id":"oc_y","chat_type":"group","root_id":"om_root","parent_id":"om_parent","create_time":"1710000000"}}}'
		}
	}
	result := hub.run_transform_refs(['transform:feishu-summary'], mut services, mut exchange) or {
		panic(err)
	}
	assert !result.halted
	assert result.action.kind == .continue_pipeline
	assert exchange.metadata['feishu.event_kind'] == 'message'
	assert exchange.metadata['feishu.event_type'] == 'im.message.receive_v1'
	assert exchange.metadata['feishu.event_id'] == 'evt_1'
	assert exchange.metadata['feishu.message_id'] == 'om_x'
	assert exchange.metadata['feishu.chat_id'] == 'oc_y'
	assert exchange.metadata['feishu.target_type'] == 'chat_id'
	assert exchange.metadata['feishu.target'] == 'oc_y'
	assert exchange.metadata['feishu.sender_id'] == 'ou_sender'
}

fn test_transformer_conformance_native_feishu_event_summary_maps_action_metadata() {
	plan := runtime_plan.RuntimePlan{
		transforms: {
			'feishu-summary': runtime_plan.TransformPlan{
				id:      'feishu-summary'
				kind:    'native'
				handler: 'feishu.event.summary'
			}
		}
	}
	mut hub := TransformerRuntimeHub.from_plan(plan)
	mut services := transformer_conformance_services()
	mut exchange := dispatch.Exchange{
		identity: dispatch.ExchangeIdentity{
			id:         'ex-feishu-action'
			request_id: 'req-feishu-action'
			trace_id:   'trace-feishu-action'
		}
		kind:     .event
		ingress:  'listener:feishu'
		pipeline: 'feishu.callback'
		headers:  map[string]string{}
		metadata: map[string]string{}
		payload:  dispatch.EventPayload{
			topic: 'feishu'
			name:  'card.action.trigger'
			data:  '{"schema":"2.0","header":{"event_id":"evt_action_1","event_type":"card.action.trigger"},"event":{"open_message_id":"om_open_1","action":{"tag":"button","value":{"action":"approve","ticket_id":"t_1"}}},"token":"verification_token","tenant_key":"tenant_action"}'
		}
	}
	result := hub.run_transform_refs(['transform:feishu-summary'], mut services, mut exchange) or {
		panic(err)
	}
	assert !result.halted
	assert result.action.kind == .continue_pipeline
	assert exchange.metadata['feishu.event_kind'] == 'action'
	assert exchange.metadata['feishu.event_type'] == 'card.action.trigger'
	assert exchange.metadata['feishu.open_message_id'] == 'om_open_1'
	assert exchange.metadata['feishu.target_type'] == 'open_message_id'
	assert exchange.metadata['feishu.target'] == 'om_open_1'
	assert exchange.metadata['feishu.action_tag'] == 'button'
	assert exchange.metadata['feishu.action_value'].contains('approve')
}

fn test_transformer_conformance_vjsx_backend_continues_event_exchange_through_lane() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_transformer_conformance_vjsx_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'transformer.js')
	os.write_file(app_file,
		'globalThis.__vhttpd_handle = (ctx) => ctx.json({ ok: true, path: ctx.path, traceId: ctx.runtime.traceId }, 202);') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut vjsx := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		runtime_profile: 'script'
	})
	defer {
		vjsx.close()
	}
	plan := runtime_plan.RuntimePlan{
		transforms: {
			'conformance': runtime_plan.TransformPlan{
				id:      'conformance'
				kind:    'vjsx'
				handler: 'test.conformance'
			}
		}
	}
	mut app := App{
		transformers: TransformerRuntimeHub.from_plan(plan)
		engines:      EngineRuntime{
			additional: {
				'vjsx': &worker.WorkerState{
					worker_backend_mode: .disabled
					logic_executor:      vjsx
					lifecycle:           'embedded_host'
				}
			}
		}
	}
	mut services := transformer_conformance_services()
	mut exchange := transformer_conformance_exchange()
	result := app.run_transform_refs(['transform:conformance'], mut services, mut exchange) or {
		panic(err)
	}
	assert !result.halted
	assert result.action.kind == .continue_pipeline
	assert vjsx.lane_snapshot()[0].served_requests == 1
}
