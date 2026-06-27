module ws

import relay
import runtime_plan

fn test_build_relay_agent_hello_payload_encodes_registration_frame() {
	descriptor := relay.descriptor_from_plan(runtime_plan.RelayPlan{
		id:      'edge'
		mode:    'agent'
		options: runtime_plan.PlanOptions{
			strings: {
				'url':     'wss://relay.example.com/vhttpd/relay'
				'node_id': 'agent_1'
				'token':   'secret'
			}
		}
	}) or { panic(err) }

	raw := build_relay_agent_hello_payload(descriptor, 'trace_1') or { panic(err) }
	frame := relay.decode_frame(raw) or { panic(err) }
	fields := relay_agent_hello_event_fields(descriptor, 'trace_1')

	assert frame.kind == .hello
	assert frame.trace_id == 'trace_1'
	assert frame.metadata['relay_id'] == 'edge'
	assert frame.metadata['node_id'] == 'agent_1'
	assert frame.headers['authorization'] == 'Bearer secret'
	assert fields['relay_event'] == 'agent.hello'
	assert fields['trace_id'] == 'trace_1'
	assert fields['url'] == 'wss://relay.example.com/vhttpd/relay'
}

fn test_build_relay_agent_hello_payload_rejects_hub_descriptor() {
	descriptor := relay.descriptor_from_plan(runtime_plan.RelayPlan{
		id:      'edge'
		mode:    'hub'
		ingress: runtime_plan.ResourceRef{
			domain: .listener
			id:     'relay'
		}
		options: runtime_plan.PlanOptions{
			strings: {
				'node_id': 'hub_1'
			}
		}
	}) or { panic(err) }

	build_relay_agent_hello_payload(descriptor, 'trace_1') or {
		assert err.msg() == 'relay_agent_hello_requires_agent_mode:edge'
		return
	}
	assert false
}

fn test_prepare_relay_agent_connect_attempt_marks_connecting_and_builds_hello() {
	mut rt := relay.new_runtime(relay_agent_payload_plan()) or { panic(err) }
	descriptor := rt.agent_descriptors()[0]

	attempt := prepare_relay_agent_connect_attempt(mut rt, descriptor, 'trace_1', 100)
	frame := relay.decode_frame(attempt.hello_payload) or { panic(err) }

	assert attempt.ok
	assert attempt.relay_id == 'edge'
	assert attempt.url == 'wss://relay.example.com/vhttpd/relay'
	assert attempt.reconnect_delay_ms == 1000
	assert attempt.agent.state == .connecting
	assert rt.agents['edge'].state == .connecting
	assert frame.kind == .hello
	assert frame.metadata['relay_id'] == 'edge'
	assert attempt.fields['relay_event'] == 'agent.connecting'
	assert attempt.fields['trace_id'] == 'trace_1'
}

fn test_prepare_relay_agent_connect_attempt_reports_invalid_descriptor() {
	mut rt := relay.empty_runtime()
	descriptor := relay.RelayDescriptor{
		id:   'hub'
		mode: .hub
		url:  'wss://relay.example.com/vhttpd/relay'
	}

	attempt := prepare_relay_agent_connect_attempt(mut rt, descriptor, 'trace_1', 100)

	assert !attempt.ok
	assert attempt.error == 'relay_runtime_unknown_relay:hub'
	assert attempt.fields['relay_event'] == 'agent.connect_failed'
	assert attempt.fields['error'] == 'relay_runtime_unknown_relay:hub'
}

fn test_receive_relay_agent_payload_routes_ack_to_handshake() {
	mut rt := relay.new_runtime(relay_agent_payload_plan()) or { panic(err) }
	rt.mark_agent_connecting('edge', 100) or { panic(err) }
	raw := relay.encode_frame(relay.registration_ack_frame(relay.RegistrationResult{
		accepted: true
		node_id:  'agent_1'
		relay_id: 'edge'
		trace_id: 'trace_1'
	})) or { panic(err) }

	outcome := receive_relay_agent_websocket_payload(mut rt, 'edge', 'text', raw, 120, 2)
	fields := relay_agent_payload_event_fields(outcome)

	assert outcome.action == .handshake
	assert outcome.handshake.action == .registered
	assert rt.agents['edge'].state == .registered
	assert fields['relay_event'] == 'agent_payload.handshake'
	assert fields['trace_id'] == 'trace_1'
}

fn test_receive_relay_agent_payload_routes_registered_frames_to_inbound() {
	mut rt := relay.new_runtime(relay_agent_payload_plan()) or { panic(err) }
	rt.mark_agent_connecting('edge', 100) or { panic(err) }
	rt.mark_agent_registered('edge', 120) or { panic(err) }
	raw := relay.encode_frame(relay.WireFrame{
		version:    relay.wire_version
		kind:       .open
		id:         'frm_open'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
	}) or { panic(err) }

	outcome := receive_relay_agent_websocket_payload(mut rt, 'edge', 'text', raw, 120, 2)

	assert outcome.action == .inbound
	assert outcome.inbound.action == .forwarded
	assert rt.channels.channels['chan_1'].node_id == 'hub:edge'
}

fn test_receive_relay_agent_payload_rejects_invalid_payload() {
	mut rt := relay.new_runtime(relay_agent_payload_plan()) or { panic(err) }

	outcome := receive_relay_agent_websocket_payload(mut rt, 'edge', 'binary', 'abc', 120, 2)

	assert outcome.action == .rejected
	assert outcome.error == 'relay_agent_unsupported_opcode:binary'
}

fn relay_agent_payload_plan() runtime_plan.RuntimePlan {
	return runtime_plan.RuntimePlan{
		relays: {
			'edge': runtime_plan.RelayPlan{
				id:      'edge'
				mode:    'agent'
				options: runtime_plan.PlanOptions{
					strings: {
						'url':     'wss://relay.example.com/vhttpd/relay'
						'node_id': 'agent_1'
					}
				}
			}
		}
	}
}
