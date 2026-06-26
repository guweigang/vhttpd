module main

import admin
import dispatch
import json
import runtime_plan

fn test_transformer_runtime_registers_native_transform_from_plan() {
	plan := runtime_plan.RuntimePlan{
		transforms: {
			'rewrite': runtime_plan.TransformPlan{
				id:      'rewrite'
				kind:    'native'
				handler: 'http.rewrite'
			}
		}
	}
	hub := TransformerRuntimeHub.from_plan(plan)
	entry := hub.entry('rewrite') or { panic('missing transform entry') }
	assert hub.has('rewrite')
	assert hub.available('rewrite')
	assert entry.id == 'rewrite'
	assert entry.kind == 'native'
	assert entry.handler == 'http.rewrite'
	assert entry.capabilities.request_response
	assert entry.capabilities.events
}

fn test_transformer_runtime_marks_vjsx_registered_and_available_for_app_wrapper() {
	plan := runtime_plan.RuntimePlan{
		transforms: {
			'upload-completed': runtime_plan.TransformPlan{
				id:      'upload-completed'
				kind:    'vjsx'
				handler: 'wordpress.upload.completed'
			}
		}
	}
	hub := TransformerRuntimeHub.from_plan(plan)
	entry := hub.entry('upload-completed') or { panic('missing transform entry') }
	assert hub.has('upload-completed')
	assert hub.available('upload-completed')
	assert entry.kind == 'vjsx'
	assert entry.handler == 'wordpress.upload.completed'
	assert entry.capabilities.events
}

fn test_transformer_runtime_snapshot_reports_transformers_and_capabilities() {
	plan := runtime_plan.RuntimePlan{
		transforms: {
			'upload-completed': runtime_plan.TransformPlan{
				id:      'upload-completed'
				kind:    'vjsx'
				handler: 'wordpress.upload.completed'
				engine:  runtime_plan.ResourceRef{
					domain: .engine
					id:     'wordpress/vjsx'
				}
			}
			'feishu-summary':   runtime_plan.TransformPlan{
				id:      'feishu-summary'
				kind:    'native'
				handler: 'feishu.event.summary'
			}
		}
	}
	hub := TransformerRuntimeHub.from_plan(plan)
	snapshot := hub.snapshot()
	assert snapshot.total == 2
	assert snapshot.available == 2
	assert snapshot.native_count == 1
	assert snapshot.vjsx_count == 1
	assert snapshot.entries.len == 2
	assert snapshot.entries[0].id == 'feishu-summary'
	assert snapshot.entries[0].kind == 'native'
	assert snapshot.entries[0].handler == 'feishu.event.summary'
	assert snapshot.entries[0].request_response
	assert snapshot.entries[0].events
	assert snapshot.entries[1].id == 'upload-completed'
	assert snapshot.entries[1].kind == 'vjsx'
	assert snapshot.entries[1].engine == 'engine:wordpress/vjsx'
	assert snapshot.entries[1].request_response
	assert snapshot.entries[1].events
}

fn test_internal_admin_runtime_transformers_returns_snapshot() {
	plan := runtime_plan.RuntimePlan{
		transforms: {
			'upload-completed': runtime_plan.TransformPlan{
				id:      'upload-completed'
				kind:    'vjsx'
				handler: 'wordpress.upload.completed'
			}
		}
	}
	mut app := App{
		transformers: TransformerRuntimeHub.from_plan(plan)
	}
	resp := app.internal_admin_dispatch(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'GET'
		path:   '/admin/runtime/transformers'
	})
	assert resp.status == 200
	snapshot := json.decode(TransformerRuntimeSnapshot, resp.body) or { panic(err) }
	assert snapshot.total == 1
	assert snapshot.available == 1
	assert snapshot.vjsx_count == 1
	assert snapshot.entries[0].id == 'upload-completed'
	assert snapshot.entries[0].handler == 'wordpress.upload.completed'
}

fn test_native_transformer_executes_as_continue_pipeline_action() {
	plan := runtime_plan.RuntimePlan{
		transforms: {
			'noop': runtime_plan.TransformPlan{
				id:      'noop'
				kind:    'native'
				handler: 'test.noop'
			}
		}
	}
	mut hub := TransformerRuntimeHub.from_plan(plan)
	mut services := dispatch.RuntimeServices(dispatch.NoOpRuntimeServices{
		trace: 'trace-1'
	})
	mut exchange := dispatch.Exchange{
		identity: dispatch.ExchangeIdentity{
			id:         'ex-1'
			request_id: 'req-1'
			trace_id:   'trace-1'
		}
		kind:     .event
		ingress:  'adapter:uploads'
		pipeline: 'upload.completed'
		headers:  map[string]string{}
		metadata: map[string]string{}
		payload:  dispatch.EventPayload{
			topic: 'uploads'
			name:  'completed'
		}
	}
	action := hub.transform('noop', mut services, mut exchange) or { panic(err) }
	assert action.kind == .continue_pipeline
}

fn test_transformer_runtime_runs_native_transform_ref_chain() {
	plan := runtime_plan.RuntimePlan{
		transforms: {
			'first':  runtime_plan.TransformPlan{
				id:      'first'
				kind:    'native'
				handler: 'test.first'
			}
			'second': runtime_plan.TransformPlan{
				id:      'second'
				kind:    'native'
				handler: 'test.second'
			}
		}
	}
	mut hub := TransformerRuntimeHub.from_plan(plan)
	mut services := dispatch.RuntimeServices(dispatch.NoOpRuntimeServices{
		trace: 'trace-1'
	})
	mut exchange := transformer_test_exchange()
	result := hub.run_transform_refs(['transform:first', 'transform:second'], mut services, mut
		exchange) or { panic(err) }
	assert !result.halted
	assert result.action.kind == .continue_pipeline
}

fn test_transformer_runtime_reports_unavailable_transform_backend() {
	plan := runtime_plan.RuntimePlan{
		transforms: {
			'vjsx-handler': runtime_plan.TransformPlan{
				id:      'vjsx-handler'
				kind:    'vjsx'
				handler: 'uploads.completed'
			}
		}
	}
	mut hub := TransformerRuntimeHub.from_plan(plan)
	mut services := dispatch.RuntimeServices(dispatch.NoOpRuntimeServices{
		trace: 'trace-1'
	})
	mut exchange := transformer_test_exchange()
	hub.run_transform_refs(['transform:vjsx-handler'], mut services, mut exchange) or {
		assert err.msg() == 'transformer unavailable: vjsx-handler'
		return
	}
	assert false
}

fn transformer_test_exchange() dispatch.Exchange {
	return dispatch.Exchange{
		identity: dispatch.ExchangeIdentity{
			id:         'ex-1'
			request_id: 'req-1'
			trace_id:   'trace-1'
		}
		kind:     .event
		ingress:  'adapter:uploads'
		pipeline: 'upload.completed'
		headers:  map[string]string{}
		metadata: map[string]string{}
		payload:  dispatch.EventPayload{
			topic: 'uploads'
			name:  'completed'
		}
	}
}
