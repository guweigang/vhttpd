module relay

pub struct SessionRegistry {
pub mut:
	sessions map[string]RelaySession
}

pub struct RelaySession {
pub:
	id string
pub mut:
	endpoints         map[string]RelayEndpoint
	endpoints_by_link map[string][]string
	pending_by_link   map[string][]WireFrame
}

pub struct RelayEndpoint {
pub:
	id         string
	channel_id string
	session_id string
	link_id    string
	role       string
	trace_id   string
}

pub fn new_session_registry() SessionRegistry {
	return SessionRegistry{
		sessions: map[string]RelaySession{}
	}
}

pub fn (mut registry SessionRegistry) open_endpoint(endpoint RelayEndpoint) ! {
	validate_endpoint(endpoint)!
	mut session := registry.sessions[endpoint.session_id] or {
		RelaySession{
			id:                endpoint.session_id
			endpoints:         map[string]RelayEndpoint{}
			endpoints_by_link: map[string][]string{}
			pending_by_link:   map[string][]WireFrame{}
		}
	}
	// A replacement endpoint owns only its current link. Retire the previous
	// reverse index before publishing the new registration; pending frames stay
	// owned by their original link and other endpoints remain registered.
	if previous := session.endpoints[endpoint.id] {
		if previous.link_id != endpoint.link_id { session.remove_endpoint_index(previous) }
	}
	session.endpoints[endpoint.id] = endpoint
	mut endpoint_ids := session.endpoints_by_link[endpoint.link_id] or { []string{} }
	if endpoint.id !in endpoint_ids {
		endpoint_ids << endpoint.id
	}
	session.endpoints_by_link[endpoint.link_id] = endpoint_ids
	registry.sessions[endpoint.session_id] = session
}

pub fn (mut registry SessionRegistry) close_endpoint(session_id string, endpoint_id string) bool {
	mut session := registry.sessions[session_id] or { return false }
	endpoint := session.endpoints[endpoint_id] or { return false }
	session.endpoints.delete(endpoint_id)
	session.remove_endpoint_index(endpoint)
	if session.endpoints.len == 0 && session.pending_by_link.len == 0 {
		registry.sessions.delete(session_id)
		return true
	}
	registry.sessions[session_id] = session
	return true
}

fn (mut session RelaySession) remove_endpoint_index(endpoint RelayEndpoint) {
	endpoint_ids := (session.endpoints_by_link[endpoint.link_id] or { []string{} }).filter(it != endpoint.id)
	if endpoint_ids.len == 0 {
		session.endpoints_by_link.delete(endpoint.link_id)
	} else {
		session.endpoints_by_link[endpoint.link_id] = endpoint_ids
	}
}

pub fn (registry SessionRegistry) targets(session_id string, link_id string, role string, except_endpoint_id string) []RelayEndpoint {
	session := registry.sessions[session_id] or { return []RelayEndpoint{} }
	endpoint_ids := session.endpoints_by_link[link_id] or { return []RelayEndpoint{} }
	mut targets := []RelayEndpoint{}
	for endpoint_id in endpoint_ids {
		if endpoint_id == except_endpoint_id {
			continue
		}
		endpoint := session.endpoints[endpoint_id] or { continue }
		if role != '' && endpoint.role != role {
			continue
		}
		targets << endpoint
	}
	return targets
}

pub fn (mut registry SessionRegistry) buffer_pending(session_id string, link_id string, frame WireFrame, limit int) ! {
	if session_id.trim_space() == '' {
		return error('relay_session_missing_id')
	}
	if link_id.trim_space() == '' {
		return error('relay_session_missing_link_id')
	}
	mut session := registry.sessions[session_id] or {
		RelaySession{
			id:                session_id
			endpoints:         map[string]RelayEndpoint{}
			endpoints_by_link: map[string][]string{}
			pending_by_link:   map[string][]WireFrame{}
		}
	}
	mut pending := session.pending_by_link[link_id] or { []WireFrame{} }
	max := if limit > 0 { limit } else { 64 }
	if pending.len >= max {
		return error('relay_session_pending_full:${session_id}:${link_id}')
	}
	pending << frame
	session.pending_by_link[link_id] = pending
	registry.sessions[session_id] = session
}

pub fn (mut registry SessionRegistry) drain_pending(session_id string, link_id string) []WireFrame {
	mut session := registry.sessions[session_id] or { return []WireFrame{} }
	frames := session.pending_by_link[link_id] or { return []WireFrame{} }
	session.pending_by_link.delete(link_id)
	if session.endpoints.len == 0 && session.pending_by_link.len == 0 {
		registry.sessions.delete(session_id)
	} else {
		registry.sessions[session_id] = session
	}
	return frames.clone()
}

fn validate_endpoint(endpoint RelayEndpoint) ! {
	if endpoint.id.trim_space() == '' {
		return error('relay_session_missing_endpoint_id')
	}
	if endpoint.channel_id.trim_space() == '' {
		return error('relay_session_missing_channel_id:${endpoint.id}')
	}
	if endpoint.session_id.trim_space() == '' {
		return error('relay_session_missing_id')
	}
	if endpoint.link_id.trim_space() == '' {
		return error('relay_session_missing_link_id')
	}
	if endpoint.trace_id.trim_space() == '' {
		return error('relay_session_missing_trace_id:${endpoint.id}')
	}
}
