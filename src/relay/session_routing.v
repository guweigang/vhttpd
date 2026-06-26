module relay

pub enum SessionRouteAction {
	deliver
	buffered
	rejected
}

pub struct SessionRouteOutcome {
pub:
	action       SessionRouteAction
	session_id   string
	link_id      string
	source_id    string
	target_ids   []string
	buffered_len int
	trace_id     string
	frame_id     string
	error        string
}

pub fn route_session_frame(mut registry SessionRegistry, session_id string, link_id string, source_endpoint_id string, target_role string, frame WireFrame, pending_limit int) SessionRouteOutcome {
	if session_id.trim_space() == '' {
		return session_route_rejected(session_id, link_id, source_endpoint_id, frame,
			'relay_session_missing_id')
	}
	if link_id.trim_space() == '' {
		return session_route_rejected(session_id, link_id, source_endpoint_id, frame,
			'relay_session_missing_link_id')
	}
	targets := registry.targets(session_id, link_id, target_role, source_endpoint_id)
	if targets.len == 0 {
		registry.buffer_pending(session_id, link_id, frame, pending_limit) or {
			return session_route_rejected(session_id, link_id, source_endpoint_id, frame, err.msg())
		}
		return SessionRouteOutcome{
			action:       .buffered
			session_id:   session_id
			link_id:      link_id
			source_id:    source_endpoint_id
			buffered_len: session_pending_len(registry, session_id, link_id)
			trace_id:     frame.trace_id
			frame_id:     frame.id
		}
	}
	return SessionRouteOutcome{
		action:     .deliver
		session_id: session_id
		link_id:    link_id
		source_id:  source_endpoint_id
		target_ids: targets.map(it.id)
		trace_id:   frame.trace_id
		frame_id:   frame.id
	}
}

pub fn open_session_endpoint_and_drain(mut registry SessionRegistry, endpoint RelayEndpoint) ![]WireFrame {
	registry.open_endpoint(endpoint)!
	return registry.drain_pending(endpoint.session_id, endpoint.link_id)
}

fn session_pending_len(registry SessionRegistry, session_id string, link_id string) int {
	session := registry.sessions[session_id] or { return 0 }
	pending := session.pending_by_link[link_id] or { return 0 }
	return pending.len
}

fn session_route_rejected(session_id string, link_id string, source_endpoint_id string, frame WireFrame, err string) SessionRouteOutcome {
	return SessionRouteOutcome{
		action:     .rejected
		session_id: session_id
		link_id:    link_id
		source_id:  source_endpoint_id
		trace_id:   frame.trace_id
		frame_id:   frame.id
		error:      err
	}
}
