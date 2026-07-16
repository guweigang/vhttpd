module relay

pub enum AgentHandshakeAction {
	registered
	failed
}

pub struct AgentHandshakeOutcome {
pub:
	action   AgentHandshakeAction
	relay_id string
	trace_id string
	frame_id string
	agent    AgentState
	error    string
}

pub fn (mut rt Runtime) handle_agent_handshake_frame(relay_id string, frame WireFrame, now_ms i64) AgentHandshakeOutcome {
	if frame.kind == .hello_ack {
		return rt.accept_agent_handshake(relay_id, frame, now_ms)
	}
	if frame.kind == .error {
		err := frame.metadata['error'] or {
			if frame.body != '' { frame.body } else { 'relay_agent_registration_rejected' }
		}
		return rt.fail_agent_handshake(relay_id, frame, now_ms, err)
	}
	return rt.fail_agent_handshake(relay_id, frame, now_ms,
		'relay_agent_unexpected_handshake_frame:${frame.kind}')
}

fn (mut rt Runtime) accept_agent_handshake(relay_id string, frame WireFrame, now_ms i64) AgentHandshakeOutcome {
	frame_relay_id := frame.metadata['relay_id'] or { relay_id }
	if frame_relay_id != relay_id {
		return rt.fail_agent_handshake(relay_id, frame, now_ms,
			'relay_agent_relay_mismatch:${frame_relay_id}:${relay_id}')
	}
	agent := rt.mark_agent_registered(relay_id, now_ms) or {
		return AgentHandshakeOutcome{
			action:   .failed
			relay_id: relay_id
			trace_id: frame.trace_id
			frame_id: frame.id
			error:    err.msg()
		}
	}
	return AgentHandshakeOutcome{
		action:   .registered
		relay_id: relay_id
		trace_id: frame.trace_id
		frame_id: frame.id
		agent:    agent
	}
}

fn (mut rt Runtime) fail_agent_handshake(relay_id string, frame WireFrame, now_ms i64, err string) AgentHandshakeOutcome {
	agent := rt.mark_agent_failed(relay_id, now_ms, err) or {
		return AgentHandshakeOutcome{
			action:   .failed
			relay_id: relay_id
			trace_id: frame.trace_id
			frame_id: frame.id
			error:    err.msg()
		}
	}
	return AgentHandshakeOutcome{
		action:   .failed
		relay_id: relay_id
		trace_id: frame.trace_id
		frame_id: frame.id
		agent:    agent
		error:    err
	}
}

pub fn agent_handshake_event_fields(outcome AgentHandshakeOutcome) map[string]string {
	return event_fields('agent_handshake.${outcome.action}', outcome.trace_id, {
		'relay_id': outcome.relay_id
		'frame_id': outcome.frame_id
		'error':    outcome.error
	})
}
