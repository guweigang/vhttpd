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

fn test_delivery_outcome_metadata_helper_clones_inputs() {
	mut metadata := {
		'response_mode': 'mcp'
	}
	outcome := outcome_with_metadata(response_outcome(200, map[string]string{}, 'ok'), metadata)
	metadata['response_mode'] = 'changed'
	assert outcome.kind == .response
	assert outcome.metadata['response_mode'] == 'mcp'
}

fn test_fixed_response_adapter_delivers_response_outcome() {
	mut services := RuntimeServices(TestServices{
		trace: 'trace-fixed'
	})
	exchange := http_request_exchange(HttpIngressRequest{
		method:     'GET'
		path:       '/healthz'
		request_id: 'req-fixed'
		trace_id:   'trace-fixed'
	})
	mut adapter := EgressAdapter(fixed_response_adapter('adapter:healthz', 204, {
		'cache-control': 'no-store'
	}, ''))

	outcome := adapter.deliver(mut services, exchange) or { panic(err) }
	assert adapter.id() == 'adapter:healthz'
	assert adapter.capabilities().request_response
	assert outcome.kind == .response
	assert outcome.status == 204
	assert outcome.headers['cache-control'] == 'no-store'
	assert outcome.body == ''
}

fn test_fixed_response_adapter_defaults_status() {
	adapter := fixed_response_adapter('adapter:ok', 0, map[string]string{}, 'ok')
	assert adapter.status == 200
}

fn test_reject_adapter_delivers_failure_outcome() {
	mut services := RuntimeServices(TestServices{
		trace: 'trace-reject'
	})
	exchange := http_request_exchange(HttpIngressRequest{
		method:     'POST'
		path:       '/admin'
		request_id: 'req-reject'
		trace_id:   'trace-reject'
	})
	mut adapter := EgressAdapter(reject_adapter('adapter:reject', 401, 'unauthorized',
		'auth_required'))

	outcome := adapter.deliver(mut services, exchange) or { panic(err) }
	assert adapter.id() == 'adapter:reject'
	assert outcome.kind == .failure
	assert outcome.status == 401
	assert outcome.error == 'unauthorized'
	assert outcome.error_class == 'auth_required'
}

fn test_reject_adapter_defaults_status_and_error_class() {
	adapter := reject_adapter('adapter:reject', 0, 'blocked', '')
	assert adapter.status == 403
	assert adapter.error_class == 'rejected'
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

fn test_http_request_exchange_normalizes_values() {
	exchange := http_request_exchange(HttpIngressRequest{
		method:         'post'
		path:           '/wp-admin/admin-ajax.php'
		query:          {
			'action': 'wc_fragments'
		}
		headers:        {
			'Host':         'example.test'
			'Content-Type': 'application/json'
		}
		body:           '{}'
		remote_addr:    '127.0.0.1:50000'
		request_id:     'req-4'
		trace_id:       'trace-4'
		ingress:        'listener:web'
		pipeline:       'site'
		created_at_ms:  100
		deadline_at_ms: 200
	})

	assert exchange.identity.id == 'req-4'
	assert exchange.identity.request_id == 'req-4'
	assert exchange.identity.trace_id == 'trace-4'
	assert exchange.kind == .request
	assert exchange.ingress == 'listener:web'
	assert exchange.pipeline == 'site'
	assert exchange.created_at_ms == 100
	assert exchange.deadline_at_ms == 200
	assert exchange.headers['host'] == 'example.test'
	assert exchange.headers['content-type'] == 'application/json'
	assert exchange.metadata['protocol'] == 'http'
	assert exchange.metadata['remote_addr'] == '127.0.0.1:50000'
	match exchange.payload {
		RequestPayload {
			assert exchange.payload.method == 'POST'
			assert exchange.payload.path == '/wp-admin/admin-ajax.php'
			assert exchange.payload.query['action'] == 'wc_fragments'
			assert exchange.payload.body == '{}'
			assert exchange.payload.remote_addr == '127.0.0.1:50000'
		}
		else {
			assert false
		}
	}
}

fn test_http_request_exchange_allows_explicit_exchange_id() {
	exchange := http_request_exchange(HttpIngressRequest{
		method:      'GET'
		path:        '/'
		request_id:  'req-5'
		trace_id:    'trace-5'
		exchange_id: 'ex-5'
	})
	assert exchange.identity.id == 'ex-5'
	assert exchange.identity.request_id == 'req-5'
}

fn test_http_exchange_matcher_matches_request_values() {
	exchange := http_request_exchange(HttpIngressRequest{
		method:     'get'
		path:       '/wp-content/app.css'
		query:      {
			'ver': '1'
		}
		headers:    {
			'Host':      'Example.test'
			'X-API-Key': 'secret'
		}
		request_id: 'req-6'
		trace_id:   'trace-6'
	})

	assert http_exchange_matches(exchange, HttpMatch{
		methods: ['GET']
		hosts:   ['example.test']
		paths:   ['/wp-content/*']
		query:   {
			'ver': '*'
		}
		headers: {
			'x-api-key': '*'
		}
	})
	assert !http_exchange_matches(exchange, HttpMatch{
		methods: ['POST']
		paths:   ['/wp-content/*']
	})
	assert !http_exchange_matches(exchange, HttpMatch{
		methods: ['GET']
		paths:   ['/wp-admin/*']
	})
	assert !http_exchange_matches(exchange, HttpMatch{
		methods: ['GET']
		paths:   ['/wp-content/*']
		query:   {
			'missing': '*'
		}
	})
}

fn test_http_exchange_matcher_rejects_non_request_exchange() {
	exchange := Exchange{
		identity: ExchangeIdentity{
			id:       'evt-1'
			trace_id: 'trace-7'
		}
		kind:     .event
		metadata: map[string]string{}
		headers:  map[string]string{}
		payload:  EventPayload{
			topic: 'upload'
			name:  'completed'
		}
	}
	assert !http_exchange_matches(exchange, HttpMatch{
		paths: ['*']
	})
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

fn test_file_delivery_outcome() {
	outcome := file_outcome('/tmp/app.css', {
		'cache-control': 'public, max-age=60'
	})
	assert outcome.kind == .file
	assert outcome.status == 200
	assert outcome.path == '/tmp/app.css'
	assert outcome.headers['cache-control'] == 'public, max-age=60'
}

fn test_relay_ingress_exchange_projects_session_payload_and_metadata() {
	exchange := relay_ingress_exchange(RelayIngressRequest{
		relay_id:      'edge'
		carrier_id:    'agent:edge'
		frame_id:      'frm-1'
		channel_id:    'chan-1'
		session_id:    'sess-1'
		link_id:       'http'
		trace_id:      'trace-relay'
		request_id:    'req-relay'
		pipeline:      'edge/local'
		body:          'hello'
		metadata:      {
			'content_type': 'text/plain'
		}
		created_at_ms: 123
	})
	payload := exchange.payload as SessionPayload

	assert exchange.identity.id == 'frm-1'
	assert exchange.identity.request_id == 'req-relay'
	assert exchange.identity.trace_id == 'trace-relay'
	assert exchange.kind == .session_message
	assert exchange.ingress == 'relay:edge'
	assert exchange.pipeline == 'edge/local'
	assert exchange.created_at_ms == 123
	assert exchange.metadata['protocol'] == 'relay'
	assert exchange.metadata['carrier_id'] == 'agent:edge'
	assert exchange.metadata['frame_id'] == 'frm-1'
	assert exchange.metadata['content_type'] == 'text/plain'
	assert payload.session_id == 'sess-1'
	assert payload.message == 'hello'
}
