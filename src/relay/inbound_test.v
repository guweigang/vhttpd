module relay

import runtime_plan

fn test_inbound_hello_registers_carrier() {
	mut rt := new_runtime(runtime_plan.RuntimePlan{
		relays: {
			'edge': runtime_plan.RelayPlan{
				id:      'edge'
				mode:    'agent'
				carrier: 'websocket'
				options: runtime_plan.PlanOptions{
					strings: {
						'url':     'wss://relay.example.com'
						'node_id': 'node_1'
						'token':   'secret'
					}
				}
			}
		}
	}) or { panic(err) }
	frame := registration_hello_frame(RegistrationRequest{
		node_id:      'node_1'
		relay_id:     'edge'
		mode:         .agent
		carrier:      'websocket'
		token:        'secret'
		trace_id:     'trace_1'
		max_channels: 4
	}) or { panic(err) }

	outcome := rt.handle_inbound_frame('carrier_edge', frame, 4)
	fields := inbound_event_fields(outcome)

	assert outcome.action == .registered
	assert outcome.relay_id == 'edge'
	assert outcome.registration.accepted
	assert rt.carriers.carrier_id('edge') == 'carrier_edge'
	assert fields['relay_event'] == 'inbound.registered'
	assert fields['trace_id'] == 'trace_1'
}

fn test_inbound_hello_rejects_wrong_token_without_registering_carrier() {
	mut rt := new_runtime(runtime_plan.RuntimePlan{
		relays: {
			'edge': runtime_plan.RelayPlan{
				id:      'edge'
				mode:    'agent'
				options: runtime_plan.PlanOptions{
					strings: {
						'url':   'wss://relay.example.com'
						'token': 'secret'
					}
				}
			}
		}
	}) or { panic(err) }
	frame := registration_hello_frame(RegistrationRequest{
		node_id:      'node_1'
		relay_id:     'edge'
		mode:         .agent
		carrier:      'websocket'
		token:        'wrong'
		trace_id:     'trace_1'
		max_channels: 4
	}) or { panic(err) }

	outcome := rt.handle_inbound_frame('carrier_edge', frame, 4)

	assert outcome.action == .rejected
	assert outcome.error == 'unauthorized'
	assert !rt.carriers.registered('edge')
}

fn test_inbound_open_frame_uses_forwarding_runtime() {
	mut rt := empty_runtime()
	frame := WireFrame{
		version:    wire_version
		kind:       .open
		id:         'frm_open'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
		route:      'site/main'
		metadata:   {
			'relay_id': 'edge'
			'node_id':  'node_1'
		}
	}

	outcome := rt.handle_inbound_frame('carrier_edge', frame, 2)

	assert outcome.action == .forwarded
	assert outcome.forwarding.action == .opened
	assert rt.channels.channels['chan_1'].node_id == 'node_1'
}

fn test_inbound_response_frame_is_returned_without_relay_pipeline_dispatch() {
	mut rt := empty_runtime()
	rt.handle_inbound_frame('carrier_edge', WireFrame{
		version:    wire_version
		kind:       .open
		id:         'frm_open'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
	}, 2)

	outcome := rt.handle_inbound_frame('carrier_edge', WireFrame{
		version:       wire_version
		kind:          .data
		id:            'relay-response:frm_1'
		trace_id:      'trace_1'
		channel_id:    'chan_1'
		exchange_kind: 'response'
		body:          'ok'
	}, 2)
	frames := rt.channels.drain('chan_1') or { panic(err) }
	fields := inbound_event_fields(outcome)

	assert outcome.action == .returned
	assert outcome.forwarding.action == .queued
	assert frames.len == 1
	assert frames[0].id == 'relay-response:frm_1'
	assert frames[0].body == 'ok'
	assert fields['relay_event'] == 'inbound.returned'
}

fn test_inbound_ping_is_ignored() {
	mut rt := empty_runtime()
	outcome := rt.handle_inbound_frame('carrier_edge', WireFrame{
		version:  wire_version
		kind:     .ping
		id:       'ping_1'
		trace_id: 'trace_1'
	}, 2)

	assert outcome.action == .ignored
	assert outcome.frame_id == 'ping_1'
}
