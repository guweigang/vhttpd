module main

import dispatch
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

fn test_transformer_runtime_keeps_vjsx_registered_but_unavailable_until_backend_exists() {
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
	assert !hub.available('upload-completed')
	assert entry.kind == 'vjsx'
	assert entry.handler == 'wordpress.upload.completed'
	assert entry.capabilities.events
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
