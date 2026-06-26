module relay

import runtime_plan

fn test_registration_hello_from_descriptor_preserves_node_and_trace() {
	descriptor := descriptor_from_plan(runtime_plan.RelayPlan{
		id:      'local'
		mode:    'agent'
		carrier: 'websocket'
		options: runtime_plan.PlanOptions{
			strings: {
				'url':     'wss://relay.example.com'
				'node_id': 'local-dev'
				'token':   'secret'
			}
			ints:    {
				'max_channels': 4
			}
		}
	}) or { panic(err) }
	req := registration_request_from_descriptor(descriptor, 'trace-register')

	frame := registration_hello_frame(req) or { panic(err) }

	assert frame.kind == .hello
	assert frame.id == 'relay-hello:local-dev'
	assert frame.trace_id == 'trace-register'
	assert frame.metadata['node_id'] == 'local-dev'
	assert frame.metadata['relay_id'] == 'local'
	assert frame.metadata['mode'] == 'agent'
	assert frame.metadata['carrier'] == 'websocket'
	assert frame.metadata['max_channels'] == '4'
	assert frame.headers['authorization'] == 'Bearer secret'
}

fn test_accept_registration_with_matching_token_returns_ack_result() {
	frame := registration_hello_frame(RegistrationRequest{
		node_id:      'local-dev'
		relay_id:     'local'
		mode:         .agent
		carrier:      'websocket'
		token:        'secret'
		trace_id:     'trace-register'
		max_channels: 4
	}) or { panic(err) }

	result := accept_registration(frame, 'secret') or { panic(err) }
	ack := registration_ack_frame(result)

	assert result.accepted
	assert result.node_id == 'local-dev'
	assert result.relay_id == 'local'
	assert result.trace_id == 'trace-register'
	assert ack.kind == .hello_ack
	assert ack.metadata['node_id'] == 'local-dev'
}

fn test_accept_registration_rejects_wrong_token_deterministically() {
	frame := registration_hello_frame(RegistrationRequest{
		node_id:      'local-dev'
		relay_id:     'local'
		mode:         .agent
		carrier:      'websocket'
		token:        'wrong'
		trace_id:     'trace-register'
		max_channels: 4
	}) or { panic(err) }

	result := accept_registration(frame, 'secret') or { panic(err) }
	ack := registration_ack_frame(result)

	assert !result.accepted
	assert result.error == 'unauthorized'
	assert ack.kind == .error
	assert ack.metadata['error'] == 'unauthorized'
}

fn test_accept_registration_rejects_unsupported_carrier_without_provider_logic() {
	frame := WireFrame{
		version:  wire_version
		kind:     .hello
		id:       'relay-hello:local-dev'
		trace_id: 'trace-register'
		metadata: {
			'node_id':  'local-dev'
			'relay_id': 'local'
			'carrier':  'tcp'
		}
	}

	result := accept_registration(frame, '') or { panic(err) }

	assert !result.accepted
	assert result.error == 'unsupported_carrier:tcp'
}

fn test_registration_request_requires_trace_id() {
	registration_hello_frame(RegistrationRequest{
		node_id:      'local-dev'
		relay_id:     'local'
		mode:         .agent
		carrier:      'websocket'
		max_channels: 4
	}) or {
		assert err.msg() == 'relay_registration_missing_trace_id'
		return
	}
	assert false
}
