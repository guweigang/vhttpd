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

fn test_transform_action_helpers() {
	respond := respond_action(204)
	assert respond.kind == .respond
	assert respond.status == 204

	reject := reject_action(403, 'forbidden', 'security_policy')
	assert reject.kind == .reject
	assert reject.status == 403
	assert reject.error_class == 'security_policy'
}
