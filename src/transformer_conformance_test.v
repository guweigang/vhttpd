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
