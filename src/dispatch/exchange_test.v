module dispatch

struct TestServices {
	trace string
}

fn (services TestServices) trace_id() string {
	return services.trace
}

fn (services TestServices) emit(event string, fields map[string]string) {
	_ = services
	_ = event
	_ = fields
}

struct HeaderTransformer {
	name string
}

fn (transformer HeaderTransformer) id() string {
	return transformer.name
}

fn (transformer HeaderTransformer) capabilities() Capabilities {
	_ = transformer
	return Capabilities{
		request_response: true
	}
}

fn (mut transformer HeaderTransformer) warmup(mut services RuntimeServices) ! {
	_ = transformer
	services.emit('transform.warmup', {
		'trace_id': services.trace_id()
	})
}

fn (mut transformer HeaderTransformer) transform(mut services RuntimeServices, mut exchange Exchange) !TransformAction {
	exchange.headers['x-transformer'] = transformer.id()
	exchange.metadata['trace_id'] = services.trace_id()
	return continue_pipeline_action()
}

fn (mut transformer HeaderTransformer) close() {
	_ = transformer
}

struct TextAdapter {
	name string
}

fn (adapter TextAdapter) id() string {
	return adapter.name
}

fn (adapter TextAdapter) capabilities() Capabilities {
	_ = adapter
	return Capabilities{
		request_response: true
	}
}

fn (mut adapter TextAdapter) warmup(mut services RuntimeServices) ! {
	_ = adapter
	services.emit('adapter.warmup', {
		'trace_id': services.trace_id()
	})
}

fn (mut adapter TextAdapter) deliver(mut services RuntimeServices, exchange Exchange) !DeliveryOutcome {
	_ = adapter
	return response_outcome(200, {
		'x-trace-id': services.trace_id()
		'x-pipeline': exchange.pipeline
	}, 'ok')
}

fn (mut adapter TextAdapter) close() {
	_ = adapter
}

struct TestPipelineDispatcher {
	name string
}

fn (dispatcher TestPipelineDispatcher) id() string {
	return dispatcher.name
}

fn (mut dispatcher TestPipelineDispatcher) dispatch(mut services RuntimeServices, mut exchange Exchange) !DeliveryOutcome {
	exchange.metadata['dispatcher'] = dispatcher.id()
	return accepted_event_outcome({
		'trace_id': services.trace_id()
	})
}

fn test_exchange_payload_and_transformer_contract() {
	mut exchange := Exchange{
		identity: ExchangeIdentity{
			id:         'ex-1'
			request_id: 'req-1'
			trace_id:   'trace-1'
		}
		kind:     .request
		ingress:  'listener:web'
		pipeline: 'site'
		headers:  {
			'accept': 'text/html'
		}
		metadata: {
			'host': 'example.test'
		}
		payload:  RequestPayload{
			method: 'GET'
			path:   '/'
			query:  {
				'a': '1'
			}
		}
	}

	assert exchange.identity.trace_id == 'trace-1'
	assert exchange.kind == .request
	match exchange.payload {
		RequestPayload {
			assert exchange.payload.method == 'GET'
			assert exchange.payload.path == '/'
		}
		else {
			assert false
		}
	}

	mut services := RuntimeServices(TestServices{
		trace: 'trace-1'
	})
	mut transformer := HeaderTransformer{
		name: 'test.header'
	}
	transformer.warmup(mut services) or { panic(err) }
	action := transformer.transform(mut services, mut exchange) or { panic(err) }
	assert action.kind == .continue_pipeline
	assert exchange.headers['x-transformer'] == 'test.header'
	assert exchange.metadata['trace_id'] == 'trace-1'
	assert transformer.capabilities().request_response
}

fn test_adapter_and_pipeline_contracts() {
	mut services := RuntimeServices(TestServices{
		trace: 'trace-2'
	})
	exchange := Exchange{
		identity: ExchangeIdentity{
			id:         'ex-2'
			request_id: 'req-2'
			trace_id:   'trace-2'
		}
		kind:     .request
		ingress:  'listener:web'
		pipeline: 'site'
		headers:  map[string]string{}
		metadata: map[string]string{}
	}

	ingress := IngressDescriptor{
		id:           'listener:web'
		capabilities: Capabilities{
			request_response: true
		}
	}
	assert ingress.capabilities.request_response

	descriptor := PipelineDescriptor{
		id:         'site'
		ingress:    ingress.id
		transforms: ['test.header']
		policies:   ['cache/public']
		egress:     'adapter:text'
		required:   Capabilities{
			request_response: true
		}
	}
	assert descriptor.transforms.len == 1
	assert descriptor.required.request_response

	mut adapter := EgressAdapter(TextAdapter{
		name: 'adapter:text'
	})
	adapter.warmup(mut services) or { panic(err) }
	outcome := adapter.deliver(mut services, exchange) or { panic(err) }
	assert outcome.kind == .response
	assert outcome.status == 200
	assert outcome.headers['x-trace-id'] == 'trace-2'
	assert outcome.headers['x-pipeline'] == 'site'
}

fn test_pipeline_dispatcher_contract() {
	mut services := RuntimeServices(TestServices{
		trace: 'trace-3'
	})
	mut exchange := Exchange{
		identity: ExchangeIdentity{
			id:         'ex-3'
			request_id: 'req-3'
			trace_id:   'trace-3'
		}
		kind:     .event
		ingress:  'adapter:upload_event'
		pipeline: 'upload.completed'
		headers:  map[string]string{}
		metadata: map[string]string{}
		payload:  EventPayload{
			topic: 'upload'
			name:  'completed'
		}
	}
	mut dispatcher := PipelineDispatcher(TestPipelineDispatcher{
		name: 'upload.completed'
	})
	outcome := dispatcher.dispatch(mut services, mut exchange) or { panic(err) }
	assert outcome.kind == .accepted_event
	assert outcome.status == 202
	assert outcome.metadata['trace_id'] == 'trace-3'
	assert exchange.metadata['dispatcher'] == 'upload.completed'
}

fn test_transform_action_helpers() {
	respond := respond_action(204)
	assert respond.kind == .respond
	assert respond.status == 204

	reject := reject_action(403, 'forbidden', 'security_policy')
	assert reject.kind == .reject
	assert reject.status == 403
	assert reject.error_class == 'security_policy'
}
