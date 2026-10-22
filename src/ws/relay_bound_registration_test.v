module ws

import relay

fn bound_registration_payload(id string) string {
	frame := relay.registration_hello_frame(relay.RegistrationRequest{ node_id: 'node', relay_id: id, mode: .agent, carrier: 'websocket', trace_id: 'trace', max_channels: 2 }) or { panic(err) }
	return relay.encode_frame(frame) or { panic(err) }
}

fn test_mismatched_hub_registration_preserves_both_existing_carriers() {
	mut rt := relay.empty_runtime()
	rt.register_carrier('edge', 'edge-original') or { panic(err) }
	rt.register_carrier('other', 'other-original') or { panic(err) }
	outcome := receive_relay_websocket_payload_for(mut rt, 'bad-connection', 'text', bound_registration_payload('other'), 2, 'edge')
	assert outcome.action == .rejected
	assert outcome.error == 'relay_websocket_relay_mismatch:other:edge'
	assert outcome.carrier_binding == none
	assert rt.carriers.carrier_id('edge') == 'edge-original'
	assert rt.carriers.carrier_id('other') == 'other-original'
}

fn test_matched_hub_registration_returns_its_exact_binding() {
	mut rt := relay.empty_runtime()
	outcome := receive_relay_websocket_payload_for(mut rt, 'connection', 'text', bound_registration_payload('edge'), 2, 'edge')
	assert outcome.action == .registered
	binding := outcome.carrier_binding or { panic('missing binding') }
	assert binding.carrier_id == 'connection'
	assert rt.detach_binding(binding, 'trace').removed
	assert !rt.carriers.registered('edge')
}
