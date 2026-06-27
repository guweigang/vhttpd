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
