module main

import os
import net.websocket
import relay
import runtime_plan
import ws

@[heap]
struct RelayAgentSocketProbe {
mut:
	reason string
}

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

fn test_relay_agent_socket_callbacks_report_disconnect() {
	mut probe := &RelayAgentSocketProbe{}
	ctx := ws_relay_agent_runtime_test_context(mut probe)
	mut state := &RelayAgentSocketState{
		ctx:        ctx
		descriptor: relay.RelayDescriptor{
			id: 'edge'
		}
	}
	mut client := websocket.Client{}

	relay_agent_error_cb(mut client, 'boom', state) or { panic(err) }
	relay_agent_close_cb(mut client, 1000, 'done', state) or { panic(err) }

	assert probe.reason == 'close:1000:done'
}

fn test_start_relay_agents_once_ignores_hub_only_config() {
	mut app := App{}
	app.control_plane.event_log = os.join_path(os.temp_dir(),
		'vhttpd_relay_agent_start_once_events.ndjson')
	app.relay = relay.new_runtime(runtime_plan.RuntimePlan{
		relays: {
			'h': runtime_plan.RelayPlan{
				id:      'h'
				mode:    'hub'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'relay'
				}
				options: runtime_plan.PlanOptions{
					strings: {
						'path': '/vhttpd/relay'
					}
				}
			}
		}
	}) or { panic(err) }

	assert app.start_relay_agents_once('trace') == 0
}

fn ws_relay_agent_runtime_test_context(mut probe RelayAgentSocketProbe) ws.RelayAgentRuntimeContext {
	return ws.RelayAgentRuntimeContext{
		prepare_attempt_fn: fn (_ relay.RelayDescriptor, _ string, _ i64) ws.RelayAgentConnectAttempt {
			return ws.RelayAgentConnectAttempt{}
		}
		handle_payload_fn:  fn (_ string, _ string, _ string, _ i64, _ int) ws.RelayAgentPayloadOutcome {
			return ws.RelayAgentPayloadOutcome{}
		}
		disconnected_fn:    fn [mut probe] (_ relay.RelayDescriptor, reason string, _ i64) {
			probe.reason = reason
		}
	}
}
