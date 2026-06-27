module main

import os
import relay
import runtime_plan

fn test_relay_agent_runtime_context_emits_attempt_and_payload_events() {
	event_log := os.join_path(os.temp_dir(), 'vhttpd_relay_agent_runtime_events.ndjson')
	os.rm(event_log) or {}
	mut app := App{}
	app.control_plane.event_log = event_log
	app.relay = relay.new_runtime(runtime_plan.RuntimePlan{
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
	}) or { panic(err) }
	descriptor := app.relay.agent_descriptors()[0]
	ctx := app.build_relay_agent_runtime_context()

	attempt := ctx.prepare_attempt(descriptor, 'trace_1', 100)
	ack := relay.encode_frame(relay.registration_ack_frame(relay.RegistrationResult{
		accepted: true
		node_id:  'agent_1'
		relay_id: 'edge'
		trace_id: 'trace_1'
	})) or { panic(err) }
	payload := ctx.handle_payload('edge', 'text', ack, 120, 2)

	assert attempt.ok
	assert payload.action == .handshake
	assert app.relay.agents['edge'].state == .registered
	log_text := os.read_file(event_log) or { panic(err) }
	assert log_text.contains('"type":"relay.agent.connecting"')
	assert log_text.contains('"type":"relay.agent.payload"')
	assert log_text.contains('"type":"relay.agent.handshake"')
}
