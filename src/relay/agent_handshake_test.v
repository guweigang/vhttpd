module relay

import runtime_plan

fn test_agent_handshake_ack_marks_agent_registered() {
	mut rt := new_runtime(agent_handshake_plan()) or { panic(err) }
	rt.mark_agent_connecting('edge', 100) or { panic(err) }
	ack := registration_ack_frame(RegistrationResult{
		accepted: true
		node_id:  'agent_1'
		relay_id: 'edge'
		trace_id: 'trace_1'
	})

	outcome := rt.handle_agent_handshake_frame('edge', ack, 120)
	fields := agent_handshake_event_fields(outcome)

	assert outcome.action == .registered
	assert outcome.agent.state == .registered
	assert outcome.agent.registered_at_ms == 120
	assert rt.agents['edge'].state == .registered
	assert fields['relay_event'] == 'agent_handshake.registered'
	assert fields['trace_id'] == 'trace_1'
	assert fields['relay_id'] == 'edge'
}

fn test_agent_handshake_error_enters_backoff() {
	mut rt := new_runtime(agent_handshake_plan()) or { panic(err) }
	rt.mark_agent_connecting('edge', 100) or { panic(err) }
	err_frame := registration_ack_frame(RegistrationResult{
		accepted: false
		node_id:  'agent_1'
		relay_id: 'edge'
		trace_id: 'trace_1'
		error:    'unauthorized'
	})

	outcome := rt.handle_agent_handshake_frame('edge', err_frame, 120)

	assert outcome.action == .failed
	assert outcome.error == 'unauthorized'
	assert outcome.agent.state == .backoff
	assert outcome.agent.next_attempt_at_ms == 370
	assert rt.agents['edge'].last_error == 'unauthorized'
}

fn test_agent_handshake_rejects_relay_id_mismatch() {
	mut rt := new_runtime(agent_handshake_plan()) or { panic(err) }
	rt.mark_agent_connecting('edge', 100) or { panic(err) }
	ack := registration_ack_frame(RegistrationResult{
		accepted: true
		node_id:  'agent_1'
		relay_id: 'other'
		trace_id: 'trace_1'
	})

	outcome := rt.handle_agent_handshake_frame('edge', ack, 120)

	assert outcome.action == .failed
	assert outcome.error == 'relay_agent_relay_mismatch:other:edge'
	assert rt.agents['edge'].state == .backoff
}

fn agent_handshake_plan() runtime_plan.RuntimePlan {
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
					ints:    {
						'reconnect_delay_ms': 250
					}
				}
			}
		}
	}
}
