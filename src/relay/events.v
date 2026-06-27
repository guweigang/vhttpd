module relay

pub fn event_fields(kind string, trace_id string, fields map[string]string) map[string]string {
	mut out := map[string]string{}
	out['relay_event'] = kind
	if trace_id != '' {
		out['trace_id'] = trace_id
	}
	for key, value in fields {
		if value != '' {
			out[key] = value
		}
	}
	return out
}

pub fn forwarding_event_fields(outcome ForwardingOutcome) map[string]string {
	return event_fields('forward.${outcome.action}', outcome.trace_id, {
		'channel_id':     outcome.channel_id
		'correlation_id': outcome.correlation_id
		'frame_id':       outcome.frame_id
		'error':          outcome.error
	})
}

pub fn session_route_event_fields(outcome SessionRouteOutcome) map[string]string {
	return event_fields('session_route.${outcome.action}', outcome.trace_id, {
		'session_id':   outcome.session_id
		'link_id':      outcome.link_id
		'source_id':    outcome.source_id
		'target_count': outcome.target_ids.len.str()
		'buffered_len': outcome.buffered_len.str()
		'frame_id':     outcome.frame_id
		'error':        outcome.error
	})
}

pub fn registration_event_fields(result RegistrationResult) map[string]string {
	return event_fields(if result.accepted { 'registration.accepted' } else { 'registration.rejected' },
		result.trace_id, {
		'node_id':        result.node_id
		'relay_id':       result.relay_id
		'error':          result.error
		'retry_after_ms': if result.retry_after_ms > 0 { result.retry_after_ms.str() } else { '' }
	})
}

pub fn agent_state_event_fields(agent AgentState) map[string]string {
	return event_fields('agent.${agent.state}', '', {
		'node_id':            agent.node_id
		'relay_id':           agent.relay_id
		'attempt':            agent.attempt.str()
		'next_attempt_at_ms': if agent.next_attempt_at_ms > 0 { agent.next_attempt_at_ms.str() } else { '' }
		'last_error':         agent.last_error
	})
}
