module relay

pub enum AgentConnectionState {
	disconnected
	connecting
	registered
	backoff
	closed
}

pub struct AgentReconnectPolicy {
pub:
	initial_delay_ms int = 1000
	max_delay_ms     int = 30000
}

pub struct AgentState {
pub:
	node_id            string
	relay_id           string
	state              AgentConnectionState = .disconnected
	attempt            int
	next_attempt_at_ms i64
	registered_at_ms   i64
	last_error          string
}

pub fn new_agent_state(descriptor RelayDescriptor) AgentState {
	return AgentState{
		node_id:  descriptor.node_id
		relay_id: descriptor.id
	}
}

pub fn (state AgentState) begin_connect(now_ms i64) AgentState {
	if state.state == .closed {
		return state
	}
	return AgentState{
		...state
		state:              .connecting
		next_attempt_at_ms: now_ms
		last_error:          ''
	}
}

pub fn (state AgentState) mark_registered(now_ms i64) AgentState {
	if state.state == .closed {
		return state
	}
	return AgentState{
		...state
		state:            .registered
		attempt:          0
		registered_at_ms: now_ms
		last_error:        ''
	}
}

pub fn (state AgentState) mark_failed(now_ms i64, err string, policy AgentReconnectPolicy) AgentState {
	if state.state == .closed {
		return state
	}
	next_attempt := state.attempt + 1
	delay_ms := reconnect_delay_ms(next_attempt, policy)
	return AgentState{
		...state
		state:              .backoff
		attempt:            next_attempt
		next_attempt_at_ms: now_ms + i64(delay_ms)
		last_error:         err
	}
}

pub fn (state AgentState) ready_to_reconnect(now_ms i64) bool {
	return state.state == .backoff && now_ms >= state.next_attempt_at_ms
}

pub fn (state AgentState) close(err string) AgentState {
	return AgentState{
		...state
		state:      .closed
		last_error: err
	}
}

pub fn reconnect_policy_from_descriptor(descriptor RelayDescriptor) AgentReconnectPolicy {
	return AgentReconnectPolicy{
		initial_delay_ms: if descriptor.reconnect_delay_ms > 0 { descriptor.reconnect_delay_ms } else { 1000 }
		max_delay_ms:     if descriptor.reconnect_delay_ms > 0 {
			descriptor.reconnect_delay_ms * 30
		} else {
			30000
		}
	}
}

pub fn reconnect_delay_ms(attempt int, policy AgentReconnectPolicy) int {
	initial := if policy.initial_delay_ms > 0 { policy.initial_delay_ms } else { 1000 }
	max := if policy.max_delay_ms > 0 { policy.max_delay_ms } else { 30000 }
	mut delay := initial
	for _ in 1 .. attempt {
		delay *= 2
		if delay >= max {
			return max
		}
	}
	if delay > max {
		return max
	}
	return delay
}
