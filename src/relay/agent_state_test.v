module relay

import runtime_plan

fn test_agent_state_connect_register_and_reset_attempts() {
	descriptor := descriptor_from_plan(runtime_plan.RelayPlan{
		id:   'local'
		mode: 'agent'
		options: runtime_plan.PlanOptions{
			strings: {
				'url':     'wss://relay.example.com'
				'node_id': 'local-dev'
			}
		}
	}) or { panic(err) }

	initial := new_agent_state(descriptor)
	connecting := initial.begin_connect(100)
	registered := connecting.mark_registered(150)

	assert initial.state == .disconnected
	assert connecting.state == .connecting
	assert connecting.next_attempt_at_ms == 100
	assert registered.state == .registered
	assert registered.attempt == 0
	assert registered.registered_at_ms == 150
	assert registered.last_error == ''
}

fn test_agent_state_failed_connection_enters_backoff() {
	descriptor := descriptor_from_plan(runtime_plan.RelayPlan{
		id:   'local'
		mode: 'agent'
		options: runtime_plan.PlanOptions{
			strings: {
				'url': 'wss://relay.example.com'
			}
			ints:    {
				'reconnect_delay_ms': 250
			}
		}
	}) or { panic(err) }
	policy := reconnect_policy_from_descriptor(descriptor)

	failed_once := new_agent_state(descriptor).begin_connect(100).mark_failed(110, 'dial_failed',
		policy)
	failed_twice := failed_once.begin_connect(360).mark_failed(370, 'dial_failed', policy)

	assert failed_once.state == .backoff
	assert failed_once.attempt == 1
	assert failed_once.next_attempt_at_ms == 360
	assert !failed_once.ready_to_reconnect(359)
	assert failed_once.ready_to_reconnect(360)
	assert failed_twice.attempt == 2
	assert failed_twice.next_attempt_at_ms == 870
}

fn test_reconnect_delay_is_capped() {
	policy := AgentReconnectPolicy{
		initial_delay_ms: 100
		max_delay_ms:     250
	}

	assert reconnect_delay_ms(1, policy) == 100
	assert reconnect_delay_ms(2, policy) == 200
	assert reconnect_delay_ms(3, policy) == 250
	assert reconnect_delay_ms(9, policy) == 250
}

fn test_closed_agent_state_is_terminal() {
	descriptor := descriptor_from_plan(runtime_plan.RelayPlan{
		id:   'local'
		mode: 'agent'
		options: runtime_plan.PlanOptions{
			strings: {
				'url': 'wss://relay.example.com'
			}
		}
	}) or { panic(err) }

	closed := new_agent_state(descriptor).close('shutdown')

	assert closed.state == .closed
	assert closed.begin_connect(100).state == .closed
	assert closed.mark_registered(100).state == .closed
	assert closed.mark_failed(100, 'again', AgentReconnectPolicy{}).state == .closed
	assert closed.last_error == 'shutdown'
}
