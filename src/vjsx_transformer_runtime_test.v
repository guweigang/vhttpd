module main

import dispatch

fn test_vjsx_transformer_dispatch_request_uses_event_payload_name_and_handler() {
	entry := TransformerRuntimeEntry{
		id:      'upload-completed'
		kind:    'vjsx'
		handler: 'wordpress.upload.completed'
	}
	exchange := dispatch.Exchange{
		identity: dispatch.ExchangeIdentity{
			id:         'ex-1'
			request_id: 'req-1'
			trace_id:   'trace-1'
		}
		kind:     .event
		ingress:  'adapter:uploads'
		pipeline: 'upload.completed'
		headers:  {
			'x-test': 'yes'
		}
		metadata: {
			'route': '/vhttpd/uploads'
		}
		payload:  dispatch.EventPayload{
			topic: 'upload'
			name:  'upload.completed'
			data:  '{"upload_id":"upl_1"}'
		}
	}
	req := vjsx_transformer_dispatch_request(entry, exchange)
	assert req.event == 'upload.completed'
	assert req.handler == 'wordpress.upload.completed'
	assert req.executor == ''
	assert req.trace_id == 'trace-1'
	assert req.request_id == 'req-1'
	assert req.payload.contains('"transform_id":"upload-completed"')
	assert req.payload.contains('"event_data":"{\\"upload_id\\":\\"upl_1\\"}"')
	assert req.payload.contains('"route":"/vhttpd/uploads"')
}

fn test_vjsx_transformer_dispatch_request_uses_engine_id_executor() {
	entry := TransformerRuntimeEntry{
		id:      'upload-completed'
		kind:    'vjsx'
		handler: 'wordpress.upload.completed'
		engine:  'engine:upload-a/vjsx'
	}
	exchange := dispatch.Exchange{
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
	}
	req := vjsx_transformer_dispatch_request(entry, exchange)
	assert req.executor == 'upload-a/vjsx'
}

fn test_vjsx_transformer_event_name_falls_back_to_pipeline() {
	exchange := dispatch.Exchange{
		identity: dispatch.ExchangeIdentity{
			id:         'ex-1'
			request_id: 'req-1'
			trace_id:   'trace-1'
		}
		kind:     .request
		ingress:  'listener:web'
		pipeline: 'site.pipeline'
		headers:  map[string]string{}
		metadata: map[string]string{}
	}
	assert vjsx_transformer_event_name(exchange) == 'site.pipeline'
}

fn test_app_transform_runner_reports_unregistered_transform() {
	mut app := App{}
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
	}
	app.run_transform_refs(['transform:missing'], mut services, mut exchange) or {
		assert err.msg() == 'transformer not registered: missing'
		return
	}
	assert false
}
